#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# toggle-proxy.sh
# Deshabilita/rehabilita el proxy CDN de Cloudflare automaticamente segun
# los bloqueos de LaLiga detectados por hayahora.futbol
#
# Disenado para ser crash-safe e idempotente:
# - State file se escribe incrementalmente (tras cada PATCH)
# - Lock file previene ejecuciones concurrentes
# - Re-ejecucion tras crash retoma donde se quedo
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Funciones de deteccion (is_cloudflare_ip, match_blocked_ip, find_blocks...)
# shellcheck source=lib/ip-match.sh
source "${SCRIPT_DIR}/lib/ip-match.sh"

# --- Cargar configuracion ---------------------------------------------------

ENV_FILE="${SCRIPT_DIR}/.env"
if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$ENV_FILE"
    set +a
fi

# --- Valores por defecto ----------------------------------------------------

LOG_FILE="${LOG_FILE:-${SCRIPT_DIR}/logs/toggle-proxy.log}"
STATE_FILE="${STATE_FILE:-${SCRIPT_DIR}/state/proxy_disabled.json}"
DRY_RUN="${DRY_RUN:-false}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
HAYAHORA_API="${HAYAHORA_API:-https://hayahora.futbol/estado/data.json}"
# Presupuesto de caracteres para las partes variables de un mensaje de
# Telegram (limite 4096 tras parsear el HTML). Con dos partes, cada una
# recibe la mitad; el resto del texto es fijo y corto.
TELEGRAM_TEXT_BUDGET=3500
CF_API_BASE="https://api.cloudflare.com/client/v4"

# Dominios protegidos: NUNCA se les quita el proxy/CDN
# media.upload-post.com esta hardcodeado como proteccion extra
PROTECTED_DOMAINS="${PROTECTED_DOMAINS:-}"
PROTECTED_DOMAINS_BUILTIN="media.upload-post.com"

mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$STATE_FILE")"

# --- Funciones auxiliares ----------------------------------------------------

# Un fallo al escribir el log (disco lleno, permisos) nunca aborta la
# ejecucion: el state y las notificaciones importan mas que el log
log() {
    local level="$1" timestamp line
    shift
    timestamp="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" || timestamp="?"
    line="[$timestamp] [$level] $*"
    { printf '%s\n' "$line"; } 2>/dev/null || true
    { printf '%s\n' "$line" >> "$LOG_FILE"; } 2>/dev/null || true
}

# Enviar un mensaje a Telegram. Devuelve 0 si se entrego, 1 si conviene
# reintentar (red, 429, 5xx, respuesta ilegible; deja retry_after en
# TG_RETRY_AFTER) y 2 si Telegram lo rechaza para siempre (p.ej. 400).
TG_RETRY_AFTER=0
send_telegram() {
    local message="$1" payload response tg_ok tg_code tg_desc retry
    TG_RETRY_AFTER=0
    # Cuerpo JSON (no -d campo=valor): un "&" en el texto no puede partir
    # el mensaje en campos de formulario extra
    payload="$(telegram_payload "$TELEGRAM_CHAT_ID" "$message")" || {
        log "WARN" "No se pudo construir la notificacion de Telegram"
        return 2
    }
    response="$(curl -s --max-time 10 \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -H 'Content-Type: application/json' \
        --data-binary "$payload" 2>/dev/null)" || {
        log "WARN" "No se pudo enviar notificacion de Telegram (error de red). Se reintentara."
        return 1
    }
    tg_ok="$(printf '%s' "$response" | jq -r '.ok' 2>/dev/null || true)"
    [[ "$tg_ok" == "true" ]] && return 0
    tg_code="$(printf '%s' "$response" | jq -r '.error_code // empty' 2>/dev/null || true)"
    tg_desc="$(printf '%s' "$response" | jq -r '.description // empty' 2>/dev/null || true)"
    retry="$(printf '%s' "$response" | jq -r '.parameters.retry_after // empty' 2>/dev/null || true)"
    if [[ "$tg_code" =~ ^4[0-9][0-9]$ && "$tg_code" != 429 ]]; then
        log "ERROR" "Telegram rechazo la notificacion: ${tg_desc:-HTTP $tg_code}. Se descarta."
        return 2
    fi
    TG_RETRY_AFTER="$(parse_uint "$retry" 0 86400 || echo 0)"
    log "ERROR" "Telegram rechazo la notificacion: ${tg_desc:-respuesta no valida: ${response:0:200}}. Se reintentara."
    return 1
}

# --- Bandeja de salida: mensajes pendientes de reenviar ----------------------
# [{hash, text, created_at, attempts, next_at}], deduplicada por hash del
# texto y limitada a OUTBOX_MAX (se descartan los mas antiguos).
OUTBOX_FILE="${STATE_FILE%.json}_outbox.json"
OUTBOX_MAX=20
# Tras un 429 en esta ejecucion no se insiste: lo nuevo va a la bandeja
TG_BLOCKED_UNTIL=0

read_outbox() {
    if [[ -s "$OUTBOX_FILE" ]]; then
        jq -c 'if type == "array" then . else [] end' "$OUTBOX_FILE" 2>/dev/null || echo '[]'
    else
        echo '[]'
    fi
}

outbox_add() { # <texto> <next_at>
    local hash new dropped
    hash="$(printf '%s' "$1" | cksum | tr ' ' '-')"
    new="$(read_outbox | jq -c --arg h "$hash" --arg t "$1" --argjson now "$(date +%s)" \
        --argjson next "$2" --argjson max "$OUTBOX_MAX" '
        if any(.[]; .hash == $h) then .
        else . + [{hash: $h, text: $t, created_at: $now, attempts: 1, next_at: $next}] end
        | .[(if length > $max then length - $max else 0 end):]')" || return 1
    dropped=$(( $(read_outbox | jq 'length') + 1 - $(printf '%s' "$new" | jq 'length') ))
    if [[ "$dropped" -gt 0 ]] && ! read_outbox | jq -e --arg h "$hash" 'any(.[]; .hash == $h)' >/dev/null; then
        log "WARN" "Bandeja de Telegram llena ($OUTBOX_MAX): se descarta el mensaje pendiente mas antiguo."
    fi
    atomic_write "$OUTBOX_FILE" "$new"
}

notify_telegram() {
    local message="$1" now rc=0
    [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]] || return 0
    now="$(date +%s)"
    if [[ "$now" -lt "$TG_BLOCKED_UNTIL" ]]; then
        outbox_add "$message" "$TG_BLOCKED_UNTIL" || log "ERROR" "No se pudo guardar la notificacion en la bandeja"
        return 0
    fi
    send_telegram "$message" || rc=$?
    if [[ "$rc" -eq 1 ]]; then
        TG_BLOCKED_UNTIL=$(( now + TG_RETRY_AFTER ))
        [[ "$TG_RETRY_AFTER" -gt 0 ]] || TG_BLOCKED_UNTIL=$(( now + 1 ))
        outbox_add "$message" "$(( now + TG_RETRY_AFTER ))" || log "ERROR" "No se pudo guardar la notificacion en la bandeja"
    fi
    return 0
}

# Reenviar la bandeja al empezar (en orden). Se para en el primer fallo
# reintentable para respetar retry_after; los rechazos definitivos se tiran.
flush_outbox() {
    [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" && -s "$OUTBOX_FILE" ]] || return 0
    local outbox n i entry text next_at now rc keep="[]" stop=false
    outbox="$(read_outbox)"
    n="$(printf '%s' "$outbox" | jq 'length')"
    [[ "$n" -gt 0 ]] || { rm -f "$OUTBOX_FILE"; return 0; }
    log "INFO" "Reenviando $n notificacion(es) pendiente(s) de Telegram"
    for (( i = 0; i < n; i++ )); do
        entry="$(printf '%s' "$outbox" | jq -c ".[$i]")"
        now="$(date +%s)"
        next_at="$(printf '%s' "$entry" | jq -r '.next_at // 0')"
        next_at="$(parse_uint "$next_at" 0 9999999999 || echo 0)"
        if [[ "$stop" == "true" || "$now" -lt "$next_at" ]]; then
            keep="$(printf '%s' "$keep" | jq -c --argjson e "$entry" '. + [$e]')"
            continue
        fi
        text="$(printf '%s' "$entry" | jq -r '.text // empty')"
        rc=0
        [[ -n "$text" ]] && { send_telegram "$text" || rc=$?; }
        if [[ "$rc" -eq 1 ]]; then
            stop=true
            TG_BLOCKED_UNTIL=$(( now + (TG_RETRY_AFTER > 0 ? TG_RETRY_AFTER : 1) ))
            keep="$(printf '%s' "$keep" | jq -c --argjson e "$entry" --argjson next "$(( now + TG_RETRY_AFTER ))" \
                '. + [$e | .attempts = ((.attempts // 0) + 1) | .next_at = $next]')"
        fi
    done
    if [[ "$(printf '%s' "$keep" | jq 'length')" -eq 0 ]]; then
        rm -f "$OUTBOX_FILE"
    else
        atomic_write "$OUTBOX_FILE" "$keep" || log "ERROR" "No se pudo actualizar la bandeja de Telegram"
    fi
}

# Comprobar si un registro DNS pertenece a un dominio protegido
# Devuelve 0 (true) si el nombre coincide con un dominio protegido o es subdominio de el
is_protected_domain() {
    local record_name
    record_name="$(canon_name "$1")"
    local all_protected="${PROTECTED_DOMAINS_BUILTIN}"
    if [[ -n "$PROTECTED_DOMAINS" ]]; then
        all_protected="${all_protected},${PROTECTED_DOMAINS}"
    fi

    IFS=',' read -ra prot_list <<< "$all_protected"
    for prot in "${prot_list[@]}"; do
        prot="$(canon_name "$prot")"
        [[ -z "$prot" ]] && continue
        if [[ "$record_name" == "$prot" || "$record_name" == *".${prot}" ]]; then
            return 0
        fi
    done
    return 1
}


# Escritura atomica: temporal unico en el mismo directorio y mv (rename
# atomico). Dos procesos nunca comparten el mismo .tmp.
atomic_write() {
    local file="$1" content="$2" tmp
    tmp="$(mktemp "${file}.XXXXXX" 2>/dev/null)" || return 1
    if printf '%s\n' "$content" > "$tmp" && mv -f "$tmp" "$file"; then
        return 0
    fi
    rm -f "$tmp"
    return 1
}

# Leer state file de forma segura (devuelve [] si no existe o esta corrupto)
read_state() {
    if [[ -f "$STATE_FILE" ]] && [[ -s "$STATE_FILE" ]]; then
        jq '.' "$STATE_FILE" 2>/dev/null || echo '[]'
    else
        echo '[]'
    fi
}

# --- State con intencion escrita antes del PATCH ------------------------------
# Cada entrada lleva status: "pending" (se va a quitar el proxy; aun sin
# confirmar) o "disabled" (confirmado). Las entradas antiguas sin status
# cuentan como "disabled".

# state_update <filtro_jq> [args jq...]: aplica el filtro al state y lo guarda
state_update() {
    local filter="$1" new
    shift
    new="$(read_state | jq -c "$@" "$filter")" && atomic_write "$STATE_FILE" "$new"
}

state_add_pending() { # <zone_id> <dominio> <id> <nombre> <tipo> <contenido> <epoch>
    state_update 'map(select(.record_id != $id)) + [{zone_id: $zid, domain: $domain, record_id: $id,
        name: $name, type: $type, content: $content, disabled_at: $ts, status: "pending"}]' \
        --arg zid "$1" --arg domain "$2" --arg id "$3" --arg name "$4" --arg type "$5" \
        --arg content "$6" --argjson ts "$7"
}

state_confirm() { # <id>
    state_update 'map(if .record_id == $id then .status = "disabled" else . end)' --arg id "$1"
}

state_remove() { # <id>
    state_update 'map(select(.record_id != $id))' --arg id "$1"
}

# --- Lock (prevenir ejecucion concurrente) ------------------------------------
# mkdir es atomico: solo un proceso crea el directorio. Dentro va el PID.
# Un lock se considera huerfano solo si su PID ya no existe o si tiene mas
# de 30 minutos (PID reutilizado por otro proceso). Va junto al state.
LOCK_DIR="$(dirname "$STATE_FILE")/toggle-proxy.lock.d"
LOCK_STALE_MINUTES=30

take_lock() {
    mkdir "$LOCK_DIR" 2>/dev/null || return 1
    echo $$ > "${LOCK_DIR}/pid"
}

cleanup() {
    if [[ "$(cat "${LOCK_DIR}/pid" 2>/dev/null)" == "$$" ]]; then
        rm -rf "$LOCK_DIR"
    fi
}

if ! take_lock; then
    lock_pid="$(cat "${LOCK_DIR}/pid" 2>/dev/null || echo "")"
    stale_reason=""
    if [[ "$lock_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
        stale_reason="PID $lock_pid ya no existe"
    elif [[ -n "$(find "$LOCK_DIR" -maxdepth 0 -mmin +"$LOCK_STALE_MINUTES" 2>/dev/null)" ]]; then
        stale_reason="tiene mas de $LOCK_STALE_MINUTES minutos"
    fi
    if [[ -z "$stale_reason" ]]; then
        log "WARN" "Otra instancia en ejecucion (PID ${lock_pid:-?}). Saliendo."
        exit 0
    fi
    log "WARN" "Lock huerfano encontrado ($stale_reason). Limpiando."
    # Romperlo con un rename: si dos procesos lo intentan, solo uno lo mueve
    stale_dir="${LOCK_DIR}.stale.$$"
    if mv "$LOCK_DIR" "$stale_dir" 2>/dev/null; then
        rm -rf "$stale_dir"
    fi
    if ! take_lock; then
        log "WARN" "Otra instancia tomo el lock a la vez. Saliendo."
        exit 0
    fi
fi
trap cleanup EXIT
# TERM/INT (docker stop via entrypoint.sh): bash atiende la senal al acabar
# el comando en curso (un curl, max 30 s) y sale; el trap EXIT libera el lock.
# Un PATCH sin confirmar queda "pending" y se reconcilia en la siguiente.
trap 'log "WARN" "Senal recibida: saliendo."; exit 143' TERM INT

# --- Verificar dependencias -------------------------------------------------

for cmd in curl jq dig; do
    if ! command -v "$cmd" &>/dev/null; then
        log "ERROR" "Comando requerido '$cmd' no encontrado. Instalalo y reintenta."
        exit 1
    fi
done

# En modo DRY_RUN solo se necesita DOMAINS
if [[ "$DRY_RUN" == "true" ]]; then
    log "INFO" "*** MODO DRY_RUN: solo deteccion, no se tocara Cloudflare ***"
    if [[ -z "${DOMAINS:-}" ]]; then
        log "ERROR" "Variable requerida DOMAINS no esta definida en .env"
        exit 1
    fi
else
    for var in CLOUDFLARE_API_TOKEN DOMAINS; do
        if [[ -z "${!var:-}" ]]; then
            log "ERROR" "Variable requerida $var no esta definida en .env"
            exit 1
        fi
    done
fi

# --- Helper API Cloudflare --------------------------------------------------

# Llamada a la API de Cloudflare. No escribe en stdout: deja el cuerpo en
# CF_BODY y el codigo HTTP en CF_HTTP ("000" si no hubo respuesta completa,
# p.ej. timeout: el cambio pudo aplicarse o no). Devuelve 0 solo con 2xx y
# success=true.
cf_api() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"
    CF_BODY=""
    CF_HTTP="000"

    local args=(
        -s -w "\n%{http_code}"
        -X "$method"
        -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}"
        -H "Content-Type: application/json"
        "${CF_API_BASE}${endpoint}"
    )

    if [[ -n "$data" ]]; then
        args+=(-d "$data")
    fi

    local response
    if ! response="$(curl --max-time 30 "${args[@]}" 2>/dev/null)"; then
        log "ERROR" "Cloudflare API $method $endpoint -> sin respuesta (error de red o timeout)"
        return 1
    fi

    CF_HTTP="$(printf '%s\n' "$response" | tail -1)"
    CF_BODY="$(printf '%s\n' "$response" | sed '$d')"
    [[ "$CF_HTTP" =~ ^[0-9]{3}$ ]] || CF_HTTP="000"

    if [[ $((10#$CF_HTTP)) -lt 200 || $((10#$CF_HTTP)) -ge 300 ]]; then
        # Incluir los errores de Cloudflare (p.ej. code 1043 en registros read-only)
        local cf_errors
        cf_errors="$(printf '%s' "$CF_BODY" | jq -c '.errors // empty' 2>/dev/null || true)"
        log "ERROR" "Cloudflare API $method $endpoint -> HTTP $CF_HTTP${cf_errors:+ $cf_errors}"
        return 1
    fi

    local success
    success="$(printf '%s' "$CF_BODY" | jq -r '.success' 2>/dev/null || echo "false")"
    if [[ "$success" != "true" ]]; then
        log "ERROR" "Cloudflare API error: $(printf '%s' "$CF_BODY" | jq -c '.errors' 2>/dev/null || true)"
        return 1
    fi
}

# Todos los registros DNS de una zona, recorriendo las paginas que indica
# result_info.total_pages (100 por pagina, maximo CF_MAX_PAGES). Deja el
# array en ZONE_RECORDS. Si falla una pagina falla todo: no se actua sobre
# una lista a medias. Cache por zona dentro de un mismo dominio.
CF_MAX_PAGES=50
ZONE_RECORDS="[]"
ZONE_RECORDS_ZONE=""
cf_list_records() {
    local zone_id="$1" page=1 total_pages=1 all="[]" endpoint
    [[ "$ZONE_RECORDS_ZONE" == "$zone_id" ]] && return 0
    while :; do
        endpoint="/zones/${zone_id}/dns_records?per_page=100"
        [[ "$page" -gt 1 ]] && endpoint="${endpoint}&page=${page}"
        cf_api GET "$endpoint" || return 1
        all="$(printf '%s' "$CF_BODY" | jq -c --argjson all "$all" '$all + (.result // [])')" || return 1
        if [[ "$page" -eq 1 ]]; then
            total_pages="$(printf '%s' "$CF_BODY" | jq -r '.result_info.total_pages // 1' 2>/dev/null || echo 1)"
            total_pages="$(parse_uint "$total_pages" 1 999999 || echo 1)"
            if [[ "$total_pages" -gt "$CF_MAX_PAGES" ]]; then
                log "WARN" "  La zona tiene $total_pages paginas de registros; solo se leen $CF_MAX_PAGES."
                total_pages="$CF_MAX_PAGES"
            fi
        fi
        [[ "$page" -ge "$total_pages" ]] && break
        page=$((page + 1))
    done
    ZONE_RECORDS="$all"
    ZONE_RECORDS_ZONE="$zone_id"
}

# Tras un cf_api fallido: 0 si Cloudflare rechazo la peticion (HTTP 4xx), asi
# que no cambio nada. Sin respuesta o con 5xx el resultado es incierto.
cf_rejected() {
    [[ "$CF_HTTP" =~ ^4[0-9][0-9]$ ]]
}

# Tras un GET fallido: 0 si el registro ya no existe (404 o code 81044)
cf_record_missing() {
    [[ "$CF_HTTP" == 404 ]] \
        || printf '%s' "$CF_BODY" | jq -e 'any(.errors[]?; .code == 81044)' >/dev/null 2>&1
}


# =============================================================================
# Helpers de dominios, state e IPs guardadas
# =============================================================================

# Resolvers y subredes de ISPs espanoles (ECS) para descubrir las IPs anycast
# de Cloudflare que ven los usuarios en Espana. Cloudflare devuelve IPs
# compartidas distintas segun resolver y ubicacion: desde un servidor fuera de
# Espana un "dig" a secas no ve las mismas que reciben Movistar, DIGI, etc.
DNS_RESOLVERS="1.1.1.1 8.8.8.8 9.9.9.9"
ECS_RESOLVER="8.8.8.8"
# Movistar, Vodafone, Orange, DIGI, MasMovil
ES_ECS_SUBNETS="80.58.0.0/16 62.37.0.0/16 90.160.0.0/16 79.116.0.0/16 37.29.0.0/16"

CF_IPS_FILE="${STATE_FILE%.json}_ips.json"
# Momento en que cada dominio deshabilitado quedo libre: {"dominio": epoch}
CLEAR_FILE="${STATE_FILE%.json}_clear.json"

# Filtro jq: registros del state que pertenecen a un dominio de DOMAINS.
# Las entradas nuevas llevan "domain"; las antiguas se asignan por nombre.
# Los nombres se comparan en forma canonica (minusculas, sin punto final).
STATE_MINE_JQ="${CANON_JQ}"'def mine($zid; $d):
    .zone_id == $zid
    and ((.domain // null) as $sd
         | if $sd != null then ($sd | canon) == $d
           else ((.name // "") | canon) as $n | ($n == $d or ($n | endswith("." + $d)))
           end);'

dig_short() {
    dig +short +time=2 +tries=1 "$@" 2>/dev/null || true
}

# Conjunto de IPs candidatas (solo Cloudflare, sin duplicados) de un dominio:
# union de dig del sistema, resolvers publicos y Google con ECS de ISPs
# espanoles, para A y AAAA.
resolve_candidates() {
    local domain="$1" type r sub ip
    {
        for type in A AAAA; do
            dig_short "$domain" "$type"
            for r in $DNS_RESOLVERS; do
                dig_short "@${r}" "$domain" "$type"
            done
            for sub in $ES_ECS_SUBNETS; do
                dig_short "@${ECS_RESOLVER}" "+subnet=${sub}" "$domain" "$type"
            done
        done
    } | while IFS= read -r ip; do
        if [[ -n "$ip" ]] && is_cloudflare_ip "$ip"; then
            echo "$ip"
        fi
    done | sort -u
}

# Candidatas cuando el apex no da ninguna IP de Cloudflare (apex en gris o sin
# A/AAAA): se resuelven los nombres con proxy de la zona dentro del dominio.
# Coste acotado: como mucho MAX_CANDIDATE_HOSTS nombres (sin comodines) y 7
# consultas por nombre (dig del sistema A y AAAA + Google con ECS de cada ISP
# en A), es decir <= 70 consultas por dominio y solo en este caso.
MAX_CANDIDATE_HOSTS=10
resolve_child_candidates() {
    local zone_id="$1" domain="$2" host sub
    [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]] || return 0
    cf_list_records "$zone_id" || return 0
    # Sin "head": con pipefail un SIGPIPE de jq abortaria la ejecucion
    printf '%s' "$ZONE_RECORDS" | jq -r --arg domain "$domain" --argjson max "$MAX_CANDIDATE_HOSTS" "${CANON_JQ}"'
        [.[]
         | select(.type == "A" or .type == "AAAA" or .type == "CNAME")
         | select(.proxied == true)
         | .name | canon
         | select(. == $domain or endswith("." + $domain))
         | select(startswith("*") | not)
        ] | unique | .[:$max][]' 2>/dev/null \
    | while IFS= read -r host; do
        {
            dig_short "$host" A
            dig_short "$host" AAAA
            for sub in $ES_ECS_SUBNETS; do
                dig_short "@${ECS_RESOLVER}" "+subnet=${sub}" "$host" A
            done
        } | while IFS= read -r ip; do
            if [[ -n "$ip" ]] && is_cloudflare_ip "$ip"; then echo "$ip"; fi
        done
    done | sort -u
}

# Avisos de mitigacion parcial de un dominio (lee la lista de la zona):
#   - CNAME con proxy cuyo destino esta fuera del dominio: si el destino
#     tiene proxy en Cloudflare, el trafico sigue pasando por Cloudflare
#   - registro read-only con proxy: ese nombre sigue pasando por Cloudflare
# Imprime "nombre<TAB>aviso" por linea.
partial_mitigation_warnings() {
    local domain="$1" records_json="$2"
    printf '%s' "$records_json" | jq -r --arg domain "$domain" "${CANON_JQ}"'
        def inscope: . == $domain or endswith("." + $domain);
        .[]
        | select(.type == "A" or .type == "AAAA" or .type == "CNAME")
        | select(.proxied == true)
        | .name |= canon
        | select(.name | inscope)
        | if (.meta.read_only // false) == true then
            "\(.name)\t\(.type) \(.name) es de solo lectura y sigue con proxy: ese nombre sigue pasando por Cloudflare"
          elif .type == "CNAME" and ((.content // "") | canon | inscope | not) then
            "\(.name)\tCNAME \(.name) -> \(.content | canon) apunta fuera de \($domain): si el destino tiene proxy, el trafico sigue pasando por Cloudflare"
          else empty end' 2>/dev/null || true
}

# Numero de registros en el state file que pertenecen al dominio
domain_state_count() {
    read_state | jq --arg zid "$1" --arg d "$2" "$STATE_MINE_JQ"' [.[] | select(mine($zid; $d))] | length'
}

# Leer el archivo de IPs guardadas ({} si no existe o esta corrupto).
# Formato actual: {"dominio": ["ip", ...]}. Formato antiguo: ["ip", ...].
read_ips_file() {
    if [[ -f "$CF_IPS_FILE" ]] && [[ -s "$CF_IPS_FILE" ]]; then
        jq -c "${CANON_JQ}"' if type == "object" then with_entries(.key |= canon) else . end' \
            "$CF_IPS_FILE" 2>/dev/null || echo '{}'
    else
        echo '{}'
    fi
}

# IPs de Cloudflare guardadas para un dominio (una por linea, vacio si no hay)
saved_ips_for() {
    read_ips_file | jq -r --arg d "$1" '
        if type == "array" then .[]
        elif type == "object" then (.[$d] // [])[]
        else empty end'
}

# Guardar las IPs candidatas de un dominio (antes de quitarle el proxy)
save_ips_for() {
    local domain="$1" ips_json="$2" all_json new
    all_json="$(printf '%s\n' "${DOMAIN_NAMES[@]}" | jq -R . | jq -s .)"
    new="$(read_ips_file | jq -c --arg d "$domain" --argjson ips "$ips_json" --argjson all "$all_json" '
        (if type == "object" then .
         elif type == "array" then (. as $old | reduce $all[] as $x ({}; .[$x] = $old))
         else {} end)
        | .[$d] = $ips')" && atomic_write "$CF_IPS_FILE" "$new"
}

# Olvidar las IPs guardadas de un dominio (tras rehabilitarlo)
forget_ips_for() {
    local new
    [[ -f "$CF_IPS_FILE" ]] || return 0
    new="$(read_ips_file | jq -c --arg d "$1" 'if type == "object" then del(.[$d]) else . end')" \
        && atomic_write "$CF_IPS_FILE" "$new"
}

# Leer el archivo de marcas de libre ({} si no existe o esta corrupto)
read_clear_file() {
    if [[ -f "$CLEAR_FILE" ]] && [[ -s "$CLEAR_FILE" ]]; then
        jq -c "${CANON_JQ}"' if type == "object" then with_entries(.key |= canon) else {} end' \
            "$CLEAR_FILE" 2>/dev/null || echo '{}'
    else
        echo '{}'
    fi
}

# Epoch desde el que un dominio esta libre (vacio si no hay marca)
clear_since_for() {
    read_clear_file | jq -r --arg d "$1" '.[$d] // empty'
}

# Marcar un dominio como libre desde <epoch>
set_clear_since() {
    local new
    new="$(read_clear_file | jq -c --arg d "$1" --argjson t "$2" '.[$d] = $t')" \
        && atomic_write "$CLEAR_FILE" "$new"
}

# Borrar la marca de libre de un dominio (nuevo bloqueo o ya rehabilitado)
forget_clear_for() {
    local new
    [[ -f "$CLEAR_FILE" ]] || return 0
    new="$(read_clear_file | jq -c --arg d "$1" 'del(.[$d])')" \
        && atomic_write "$CLEAR_FILE" "$new"
}

# =============================================================================
# Ficheros corruptos: cuarentena, nunca "vacio"
# =============================================================================
# Un fichero ilegible o con otra forma se mueve a <fichero>.corrupt-<epoch>,
# se registra como ERROR y se alerta. No se sustituye en silencio por un
# valor vacio que luego borre los demas ficheros. En DRY_RUN no se mueve.
CORRUPT_LINES=""

quarantine_if_invalid() { # <fichero> <condicion_jq_sobre_el_documento>
    local file="$1" cond="$2" dest
    [[ -s "$file" ]] || return 0
    if jq -se "length == 1 and (.[0] | ${cond})" "$file" >/dev/null 2>&1; then
        return 0
    fi
    if [[ "$DRY_RUN" == "true" ]]; then
        log "ERROR" "$file esta corrupto (DRY_RUN: no se mueve)"
        return 0
    fi
    dest="${file}.corrupt-$(date +%s)"
    if mv "$file" "$dest" 2>/dev/null; then
        log "ERROR" "$file esta corrupto. Movido a $dest para revisarlo."
        CORRUPT_LINES="${CORRUPT_LINES}  - $(basename "$file") → $(basename "$dest")"$'\n'
    else
        log "ERROR" "$file esta corrupto y no se pudo mover a $dest."
        CORRUPT_LINES="${CORRUPT_LINES}  - $(basename "$file") (no se pudo mover)"$'\n'
    fi
}

# Alerta de ficheros en cuarentena (una vez, en la ejecucion que los movio)
notify_corrupt_files() {
    [[ -n "$CORRUPT_LINES" ]] || return 0
    local corrupt_hint="" suspect_domains
    if [[ "$STATE_WAS_CORRUPT" == "true" ]]; then
        suspect_domains="$(read_ips_file | jq -r 'if type == "object" then keys | join(", ") else "" end' 2>/dev/null || true)"
        corrupt_hint="El script ya no sabe que registros quito y no los restaurara solo. Revisa en Cloudflare los registros en gris${suspect_domains:+ de $(html_escape "$suspect_domains")} y borra el fichero .corrupt cuando termines."
    fi
    notify_telegram "$(cat <<EOF
⚠️ <b>Fichero de estado corrupto</b>

Se ha movido a cuarentena:
<code>$(html_escape "$(truncate_text "$CORRUPT_LINES" "$TELEGRAM_TEXT_BUDGET")")</code>
${corrupt_hint}
EOF
)"
    CORRUPT_LINES=""
}

# 0 si hay un state en cuarentena pendiente de revisar
state_quarantine_exists() {
    local f
    for f in "${STATE_FILE}".corrupt-*; do
        [[ -e "$f" ]] && return 0
    done
    return 1
}

quarantine_if_invalid "$STATE_FILE" \
    'type == "array" and all(.[]; type == "object" and (.record_id | type) == "string")'
STATE_WAS_CORRUPT=false
[[ -n "$CORRUPT_LINES" ]] && STATE_WAS_CORRUPT=true
quarantine_if_invalid "$CF_IPS_FILE" \
    '(type == "array" and all(.[]; type == "string"))
     or (type == "object" and all(.[]; type == "array" and all(.[]; type == "string")))'
quarantine_if_invalid "$CLEAR_FILE" 'type == "object"'
quarantine_if_invalid "$OUTBOX_FILE" 'type == "array" and all(.[]; type == "object")'
if [[ "$DRY_RUN" != "true" ]]; then
    flush_outbox
fi
if state_quarantine_exists; then
    log "WARN" "Hay un state en cuarentena (${STATE_FILE}.corrupt-*). Revisa en Cloudflare los registros en gris y borralo despues; mientras exista no se borran los ficheros de apoyo."
fi

# =============================================================================
# PASO 1: Consultar hayahora.futbol
# =============================================================================

_all_prot="${PROTECTED_DOMAINS_BUILTIN}"
[[ -n "$PROTECTED_DOMAINS" ]] && _all_prot="${_all_prot},${PROTECTED_DOMAINS}"
log "INFO" "Dominios protegidos (nunca se quita CDN): ${_all_prot}"
log "INFO" "Comprobando estado de bloqueos LaLiga para nuestros dominios..."

# Parsear DOMAINS (ZONE_ID:DOMINIO,...) en dos arrays paralelos
IFS=',' read -ra DOMAIN_LIST <<< "$DOMAINS"
ZONE_IDS=()
DOMAIN_NAMES=()
for entry in "${DOMAIN_LIST[@]}"; do
    entry="$(echo "$entry" | xargs)"
    [[ -z "$entry" ]] && continue
    zone_id="${entry%%:*}"
    domain="$(canon_name "${entry#*:}")"
    if [[ "$entry" != *:* || -z "$zone_id" || -z "$domain" ]]; then
        log "ERROR" "Entrada mal formada en DOMAINS: '$entry'. Formato: ZONE_ID:DOMINIO"
        continue
    fi
    ZONE_IDS+=("$zone_id")
    DOMAIN_NAMES+=("$domain")
done

if [[ ${#DOMAIN_NAMES[@]} -eq 0 ]]; then
    log "ERROR" "DOMAINS no contiene ninguna entrada valida. Abortando."
    exit 1
fi

# Numeros de entorno: base 10 con limites ("08" es 8, no octal invalido)
MAX_DISABLED_HOURS_RAW="${MAX_DISABLED_HOURS:-12}"
if ! MAX_DISABLED_HOURS="$(parse_uint "$MAX_DISABLED_HOURS_RAW" 1 720)"; then
    log "WARN" "MAX_DISABLED_HOURS='$MAX_DISABLED_HOURS_RAW' no es un numero de horas (1-720). Usando 12."
    MAX_DISABLED_HOURS=12
fi
MAX_DISABLED_SECONDS=$((MAX_DISABLED_HOURS * 3600))

# Histeresis: minutos que un dominio debe seguir libre antes de rehabilitarlo.
# Evita el ciclo deshabilitar/rehabilitar cuando hayahora alterna IPs vecinas.
MIN_CLEAR_MINUTES_RAW="${MIN_CLEAR_MINUTES:-15}"
if ! MIN_CLEAR_MINUTES="$(parse_uint "$MIN_CLEAR_MINUTES_RAW" 0 10080)"; then
    log "WARN" "MIN_CLEAR_MINUTES='$MIN_CLEAR_MINUTES_RAW' no es un numero de minutos (0-10080). Usando 15."
    MIN_CLEAR_MINUTES=15
fi
MIN_CLEAR_SECONDS=$((MIN_CLEAR_MINUTES * 60))

hayahora_ok=true
# -f: un HTTP >= 400 hace fallar a curl. Despues se valida la forma: un 2xx
# vacio o con {"error":..} tambien cuenta como feed no disponible
hayahora_data="$(curl -sf --max-time 15 "$HAYAHORA_API" 2>/dev/null)" || hayahora_ok=false

if [[ "$hayahora_ok" == "true" ]] && ! printf '%s' "$hayahora_data" | feed_is_valid; then
    log "WARN" "Respuesta de hayahora.futbol vacia o con formato inesperado: ${hayahora_data:0:200}"
    hayahora_ok=false
fi

if [[ "$hayahora_ok" == "true" ]]; then
    # Entradas con bloqueo activo ("ip<TAB>isp"), calculadas una sola vez.
    # La forma ya esta validada; aun asi un fallo de jq no aborta la ejecucion
    hayahora_active="$(printf '%s' "$hayahora_data" | jq -r "$HAYAHORA_ACTIVE_JQ")" || hayahora_ok=false
    # Para state files antiguos sin IPs guardadas: cualquier bloqueo de Cloudflare
    cf_blocked_count="$(printf '%s' "$hayahora_data" | jq '
        [.data[]
         | select((.description // "") | test("^Cloudflare"))
         | select(.stateChanges | length > 0)
         | select(.stateChanges[-1].state == true)
        ] | length
    ')" || hayahora_ok=false
fi

if [[ "$hayahora_ok" == "true" ]]; then
    log "INFO" "hayahora.futbol: $(printf '%s' "$hayahora_active" | grep -c . || true) entrada(s) con bloqueo activo"
else
    log "WARN" "No se pudo obtener datos de $HAYAHORA_API"
    if [[ "$(read_state | jq 'length')" -eq 0 ]]; then
        log "INFO" "Sin state file activo. Abortando sin cambios (fail-safe)."
        notify_corrupt_files
        exit 0
    fi
fi

# =============================================================================
# PASO 2 y 3: Decidir y actuar dominio a dominio
# =============================================================================

any_error=false
total_disabled=0
# Registros deshabilitados en ESTA ejecucion (la alerta solo lleva estos)
new_disabled_lines=""
total_reapplied=0
reapplied_names=""
disable_reasons=""
restored_lines=""
total_restored=0
partial_warnings=""
domain_partial=""
restore_pending_lines=""
enable_reasons=""

# Quitar el proxy a los registros proxied de un dominio
disable_domain() {
    local zone_id="$1" domain="$2"

    log "INFO" "=== DESHABILITANDO proxy de Cloudflare: $domain (zona: ${zone_id:0:8}...) ==="

    # Inicializar state file si no existe
    if [[ ! -f "$STATE_FILE" ]] || [[ ! -s "$STATE_FILE" ]]; then
        atomic_write "$STATE_FILE" '[]'
    fi

    local records_json target_records record_count i record record_id record_name
    local record_type record_content body

    if ! cf_list_records "$zone_id"; then
        log "ERROR" "No se pudieron obtener registros DNS para $domain. Saltando."
        any_error=true
        return 0
    fi
    records_json="$ZONE_RECORDS"

    # Solo registros proxied del dominio y subdominios. Los read-only (p.ej.
    # creados por un Worker) no se pueden editar: Cloudflare responde 400/1043
    target_records="$(printf '%s' "$records_json" | jq -c --arg domain "$domain" "${CANON_JQ}"'
        [.[]
         | select(.type == "A" or .type == "AAAA" or .type == "CNAME")
         | .name |= canon
         | select(.name == $domain or (.name | endswith("." + $domain)))
         | select(.proxiable == true)
         | select(.proxied == true)
         | select((.meta.read_only // false) != true)
         | {id, name, type, content, ttl}
        ]
    ')"

    record_count="$(echo "$target_records" | jq 'length')"

    local w_name w_text
    while IFS=$'\t' read -r w_name w_text; do
        [[ -n "$w_name" ]] || continue
        is_protected_domain "$w_name" && continue
        log "WARN" "  [PARCIAL] $w_text"
        domain_partial="${domain_partial}  - ${w_text}"$'\n'
    done < <(partial_mitigation_warnings "$domain" "$records_json")

    if [[ "$record_count" -eq 0 ]]; then
        log "INFO" "  No hay registros proxied para $domain."
        return 0
    fi

    log "INFO" "  $record_count registro(s) proxied encontrado(s)"

    for i in $(seq 0 $((record_count - 1))); do
        record="$(echo "$target_records" | jq -c ".[$i]")"
        record_id="$(echo "$record" | jq -r '.id')"
        record_name="$(echo "$record" | jq -r '.name')"
        record_type="$(echo "$record" | jq -r '.type')"
        record_content="$(echo "$record" | jq -r '.content')"

        # PROTECCION: nunca deshabilitar proxy en dominios protegidos
        if is_protected_domain "$record_name"; then
            log "WARN" "  [PROTEGIDO] $record_name esta en la lista de dominios protegidos. NO se tocara."
            continue
        fi

        # Solo el estado del proxy: nunca reescribir nombre, contenido o TTL
        body='{"proxied":false}'

        # Si ya esta en state file pero vuelve a estar proxied, alguien (o algo)
        # ha reactivado la nube naranja durante el bloqueo: hay que volver a
        # quitarla. Antes se saltaba y la web se quedaba caida todo el partido.
        if read_state | jq -e --arg id "$record_id" '.[] | select(.record_id == $id)' >/dev/null 2>&1; then
            if cf_api PATCH "/zones/${zone_id}/dns_records/${record_id}" "$body"; then
                log "WARN" "  [REAPLICADO] $record_name estaba en state file pero alguien reactivo el proxy. Quitado de nuevo."
                total_reapplied=$((total_reapplied + 1))
                reapplied_names="${reapplied_names}  - ${record_name}"$'\n'
            else
                log "ERROR" "  [FAIL] No se pudo volver a deshabilitar proxy para $record_type $record_name"
                any_error=true
            fi
            continue
        fi

        # Intencion antes del PATCH: si el PATCH se aplica pero la respuesta se
        # pierde (timeout) o el proceso muere, la siguiente ejecucion sabe que
        # este registro puede estar en gris por nuestra causa
        if ! state_add_pending "$zone_id" "$domain" "$record_id" "$record_name" "$record_type" \
            "$record_content" "$(date +%s)"; then
            log "ERROR" "  No se pudo escribir el state: no se toca $record_type $record_name"
            any_error=true
            continue
        fi

        if cf_api PATCH "/zones/${zone_id}/dns_records/${record_id}" "$body"; then
            state_confirm "$record_id" || {
                log "ERROR" "  No se pudo confirmar $record_name en el state (queda pending; se comprobara)"
                any_error=true
            }
            log "INFO" "  [OK] Proxy deshabilitado: $record_type $record_name -> $record_content"
            total_disabled=$((total_disabled + 1))
            new_disabled_lines="${new_disabled_lines}  - ${record_type} ${record_name} → ${record_content}"$'\n'
        elif cf_rejected; then
            # Cloudflare lo rechazo: el registro no cambio, se retira la intencion
            state_remove "$record_id" || any_error=true
            log "ERROR" "  [FAIL] No se pudo deshabilitar proxy para $record_type $record_name"
            any_error=true
        else
            log "ERROR" "  [INCIERTO] Sin respuesta al quitar el proxy de $record_type $record_name. Queda pending y se comprobara en la proxima ejecucion."
            any_error=true
        fi
    done
}

# Reconciliar las intenciones "pending" de un dominio con el estado real en
# Cloudflare (PATCH sin respuesta, crash o fallo de log en la ejecucion
# anterior):
#   en gris        -> el PATCH se aplico: se confirma (y se alerta)
#   con proxy      -> no se aplico: se descarta (si sigue bloqueado, el
#                     dominio se deshabilita de nuevo mas abajo)
#   ya no existe   -> se descarta
#   GET fallido    -> se deja pending para la siguiente ejecucion
reconcile_pending() {
    local zone_id="$1" domain="$2" id name type content proxied
    while IFS=$'\t' read -r id name type content; do
        [[ -n "$id" ]] || continue
        if ! cf_api GET "/zones/${zone_id}/dns_records/${id}"; then
            if cf_record_missing; then
                log "WARN" "  [PENDIENTE] $name ya no existe en Cloudflare. Se descarta."
                state_remove "$id" || any_error=true
            else
                log "ERROR" "  [PENDIENTE] No se pudo comprobar $name. Se reintentara."
                any_error=true
            fi
            continue
        fi
        proxied="$(printf '%s' "$CF_BODY" | jq -r '.result.proxied' 2>/dev/null || echo "unknown")"
        if [[ "$proxied" == "false" ]]; then
            if state_confirm "$id"; then
                log "INFO" "  [CONFIRMADO] $type $name quedo sin proxy en una ejecucion anterior."
                total_disabled=$((total_disabled + 1))
                new_disabled_lines="${new_disabled_lines}  - ${type} ${name} → ${content}"$'\n'
            else
                any_error=true
            fi
        elif [[ "$proxied" == "true" ]]; then
            log "INFO" "  [PENDIENTE] $name sigue con proxy: el cambio no llego a aplicarse. Se descarta."
            state_remove "$id" || any_error=true
        else
            log "ERROR" "  [PENDIENTE] Respuesta inesperada al comprobar $name. Se reintentara."
            any_error=true
        fi
    done < <(read_state | jq -r --arg zid "$zone_id" --arg d "$domain" "$STATE_MINE_JQ"'
        .[] | select(mine($zid; $d)) | select(.status == "pending")
        | [.record_id, .name, .type, .content] | @tsv')
}

# Restaurar el proxy en los registros que este script quito a un dominio
enable_domain() {
    local zone_id="$1" domain="$2"

    log "INFO" "=== REHABILITANDO proxy de Cloudflare: $domain (zona: ${zone_id:0:8}...) ==="

    local state_records record_count i record_id record_name record_type
    local record_content current current_proxied current_name body remaining
    record_type=""

    state_records="$(read_state | jq -c --arg zid "$zone_id" --arg d "$domain" \
        "$STATE_MINE_JQ"' [.[] | select(mine($zid; $d))]')"
    record_count="$(echo "$state_records" | jq 'length')"

    log "INFO" "  Restaurando $record_count registro(s) deshabilitado(s) previamente"

    for i in $(seq 0 $((record_count - 1))); do
        record_id="$(echo "$state_records" | jq -r ".[$i].record_id")"
        record_name="$(echo "$state_records" | jq -r ".[$i].name")"

        # Obtener estado actual del registro en Cloudflare
        if ! cf_api GET "/zones/${zone_id}/dns_records/${record_id}"; then
            if cf_record_missing; then
                # Borrado en Cloudflare: no hay nada que restaurar
                log "WARN" "  $record_name ya no existe en Cloudflare. Se da por resuelto."
                state_remove "$record_id" || any_error=true
            else
                log "ERROR" "  No se pudo obtener registro $record_id ($record_name). Saltando."
                any_error=true
            fi
            continue
        fi
        current="$CF_BODY"

        current_proxied="$(echo "$current" | jq '.result.proxied')"

        if [[ "$current_proxied" == "true" ]]; then
            log "INFO" "  [SKIP] $record_name ya tiene proxy activo"
        else
            record_type="$(echo "$current" | jq -r '.result.type')"
            record_content="$(echo "$current" | jq -r '.result.content')"

            # Solo el estado del proxy: un registro renombrado mientras estaba
            # en gris conserva su nombre nuevo
            current_name="$(echo "$current" | jq -r "${CANON_JQ}"' (.result.name // "") | canon')"
            if [[ "$current_name" != "$(canon_name "$record_name")" ]]; then
                log "WARN" "  $record_name ahora se llama $current_name. Se restaura el proxy sin tocar el nombre."
            fi
            body='{"proxied":true}'

            if cf_api PATCH "/zones/${zone_id}/dns_records/${record_id}" "$body"; then
                log "INFO" "  [OK] Proxy rehabilitado: $record_type $record_name"
            else
                log "ERROR" "  [FAIL] No se pudo rehabilitar proxy para $record_name"
                any_error=true
                continue  # No eliminar del state file si fallo
            fi
        fi

        # Eliminar este registro del state file INMEDIATAMENTE (crash-safe) y
        # contarlo ya: aunque otro registro del dominio falle, este se alerta
        state_remove "$record_id" || {
            log "ERROR" "  No se pudo actualizar state file tras rehabilitar $record_name"
            any_error=true
        }
        total_restored=$((total_restored + 1))
        restored_lines="${restored_lines}  - ${record_type:-$(echo "$state_records" | jq -r ".[$i].type")} ${record_name}"$'\n'
        record_type=""
    done

    remaining="$(domain_state_count "$zone_id" "$domain")"
    if [[ "$remaining" -eq 0 ]]; then
        forget_ips_for "$domain"
        forget_clear_for "$domain"
        log "INFO" "  Todos los registros de $domain restaurados."
    else
        log "WARN" "  $remaining registro(s) de $domain no se pudieron rehabilitar. Se reintentara en la proxima ejecucion."
        restore_pending_lines="${restore_pending_lines}  - ${domain}: ${remaining} registro(s) siguen en gris"$'\n'
    fi
}

checked_domains=0

for idx in "${!DOMAIN_NAMES[@]}"; do
    zone_id="${ZONE_IDS[$idx]}"
    domain="${DOMAIN_NAMES[$idx]}"
    state_n="$(domain_state_count "$zone_id" "$domain")"
    domain_reason_added=false
    # Cache de registros solo dentro de un dominio (los PATCH la dejan vieja)
    ZONE_RECORDS_ZONE=""

    log "INFO" "--- $domain ---"

    # 0. Intenciones sin confirmar de una ejecucion anterior
    if [[ "$state_n" -gt 0 && "$DRY_RUN" != "true" ]] \
        && [[ "$(read_state | jq --arg zid "$zone_id" --arg d "$domain" "$STATE_MINE_JQ"' [.[] | select(mine($zid; $d)) | select(.status == "pending")] | length')" -gt 0 ]]; then
        confirmed_before="$total_disabled"
        reconcile_pending "$zone_id" "$domain"
        if [[ "$total_disabled" -gt "$confirmed_before" ]]; then
            disable_reasons="${disable_reasons}${domain}: confirmado tras una respuesta incierta de Cloudflare"$'\n'
            domain_reason_added=true
        fi
        state_n="$(domain_state_count "$zone_id" "$domain")"
    fi

    # 1. IPs candidatas. Si ya quitamos el proxy, dig devuelve las IPs de origen:
    #    usar las IPs de Cloudflare guardadas al deshabilitarlo.
    legacy_check=false
    if [[ "$state_n" -gt 0 ]]; then
        candidates="$(saved_ips_for "$domain")"
        if [[ -n "$candidates" ]]; then
            log "INFO" "  Proxy deshabilitado ($state_n registro(s)). Usando IPs de Cloudflare guardadas."
        else
            # State sin IPs guardadas (version antigua): check amplio de Cloudflare
            log "WARN" "  State sin IPs guardadas para $domain (version antigua). Usando check amplio de Cloudflare."
            legacy_check=true
        fi
    else
        candidates="$(resolve_candidates "$domain")"
        if [[ -z "$candidates" ]]; then
            log "INFO" "  El apex de $domain no da IPs de Cloudflare. Probando sus subdominios con proxy."
            # Listar aqui (no en la subshell) para que disable_domain reutilice la cache
            if [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]]; then cf_list_records "$zone_id" || any_error=true; fi
            candidates="$(resolve_child_candidates "$zone_id" "$domain")"
        fi
        if [[ -z "$candidates" ]]; then
            log "WARN" "  Ninguna IP resuelta de $domain es de Cloudflare. El proxy podria estar desactivado manualmente. Sin accion."
            continue
        fi
    fi
    checked_domains=$((checked_domains + 1))
    [[ "$legacy_check" == "false" ]] && log "INFO" "  IPs candidatas: $(echo "$candidates" | tr '\n' ' ')"

    # 2. Decidir
    blocked=false
    reason=""
    if [[ "$hayahora_ok" == "true" ]]; then
        if [[ "$legacy_check" == "true" ]]; then
            if [[ "$cf_blocked_count" -gt 0 ]]; then
                blocked=true
                reason="check amplio: $cf_blocked_count IPs de Cloudflare bloqueadas"
                log "WARN" "  BLOQUEO CLOUDFLARE ACTIVO ($cf_blocked_count IPs bloqueadas). Manteniendo proxy deshabilitado."
            else
                log "INFO" "  No hay bloqueos de Cloudflare activos. Se puede rehabilitar."
            fi
        else
            matches="$(printf '%s\n' "$hayahora_active" | find_blocks "$candidates")"
            if [[ -n "$matches" ]]; then
                blocked=true
                match_count=0
                while IFS=$'\t' read -r m_isp m_ip m_rule m_cand; do
                    if [[ "$m_rule" == "exact" ]]; then
                        log "WARN" "  [exact] $m_isp bloquea $m_ip (IP nuestra)"
                    else
                        log "WARN" "  [$m_rule] $m_isp bloquea $m_ip (mismo bloque que nuestra $m_cand)"
                    fi
                    match_count=$((match_count + 1))
                done <<< "$matches"
                # Motivo acotado: total y como mucho 3 coincidencias por dominio
                reason="$(summarize_matches 3 <<< "$matches")"
                log "WARN" "  BLOQUEO DE $domain ($match_count entradas)"
            else
                log "INFO" "  Nuestras IPs de $domain NO estan bloqueadas"
            fi
        fi
    else
        # hayahora caida: solo importa el timeout de los registros ya deshabilitados
        if [[ "$state_n" -eq 0 ]]; then
            log "INFO" "  hayahora caida y proxy activo. Sin accion (fail-safe)."
            continue
        fi
        # Solo cuentan comprobaciones libres seguidas con el feed sano: la
        # caida reinicia el contador de libre
        if [[ "$DRY_RUN" != "true" && -n "$(clear_since_for "$domain")" ]]; then
            log "INFO" "  hayahora caida: se reinicia el contador de libre de $domain."
            forget_clear_for "$domain" || any_error=true
        fi
        # Timeout desde la entrada mas antigua del dominio. disabled_at puede ser
        # epoch (actual) o ISO 8601 (legacy, siempre UTC). Uno ilegible se da
        # por vencido: esperar para siempre dejaria el proxy quitado sin limite
        oldest_epoch=""
        while IFS= read -r ts_raw; do
            if ! ts_epoch="$(epoch_of "$ts_raw")"; then
                log "ERROR" "  disabled_at='$ts_raw' ilegible en el state de $domain. Se da por vencido el timeout."
                ts_epoch=0
            fi
            if [[ -z "$oldest_epoch" || "$ts_epoch" -lt "$oldest_epoch" ]]; then
                oldest_epoch="$ts_epoch"
            fi
        done < <(read_state | jq -r --arg zid "$zone_id" --arg d "$domain" \
            "$STATE_MINE_JQ"' .[] | select(mine($zid; $d)) | .disabled_at | tostring')
        [[ -n "$oldest_epoch" ]] || oldest_epoch=0
        elapsed=$(( $(date +%s) - oldest_epoch ))
        if [[ "$elapsed" -lt "$MAX_DISABLED_SECONDS" ]]; then
            remaining_h=$(( (MAX_DISABLED_SECONDS - elapsed) / 3600 ))
            log "INFO" "  Proxy deshabilitado hace $(( elapsed / 3600 ))h. Quedan ~${remaining_h}h hasta rehabilitar por timeout. Esperando."
            continue
        fi
        log "WARN" "  Proxy deshabilitado hace $(( elapsed / 3600 ))h. Superado limite de ${MAX_DISABLED_HOURS}h. Rehabilitando."
        reason="hayahora caida, timeout ${MAX_DISABLED_HOURS}h alcanzado"
    fi

    # 3. Actuar. Matriz por dominio:
    #   bloqueado + sin state  -> DISABLE (primer bloqueo)
    #   bloqueado + con state  -> DISABLE (retomar tras crash / reaplicar)
    #   libre     + con state  -> ENABLE
    #   libre     + sin state  -> nada
    if [[ "$blocked" == "true" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            if is_protected_domain "$domain"; then
                log "DRY_RUN" "  $domain bloqueado pero PROTEGIDO: no se tocaria."
            elif [[ "$state_n" -gt 0 ]]; then
                log "DRY_RUN" "  Bloqueo activo. Ya hay $state_n registro(s) deshabilitado(s) en $domain. Se comprobarian los restantes."
            else
                log "DRY_RUN" "  ACCION NECESARIA: se DESHABILITARIA el proxy de $domain"
            fi
            continue
        fi
        # Bloqueado otra vez: el contador de libre vuelve a empezar
        if [[ -n "$(clear_since_for "$domain")" ]]; then
            log "INFO" "  Bloqueo de nuevo: se reinicia el contador de libre de $domain."
            forget_clear_for "$domain"
        fi
        # Guardar las IPs de Cloudflare actuales (antes de cambiar el proxy)
        # para comprobar en siguientes ejecuciones si el bloqueo sigue
        if [[ "$legacy_check" == "false" ]]; then
            save_ips_for "$domain" "$(echo "$candidates" | jq -R . | jq -sc .)"
        fi
        disabled_before="$total_disabled"
        domain_partial=""
        disable_domain "$zone_id" "$domain"
        if [[ "$total_disabled" -gt "$disabled_before" && -n "$domain_partial" ]]; then
            partial_warnings="${partial_warnings}${domain_partial}"
        fi
        # Motivo solo si esta ejecucion ha deshabilitado algo de este dominio:
        # un bloqueo que sigue activo no vuelve a alertar
        if [[ "$total_disabled" -gt "$disabled_before" && "$domain_reason_added" == "false" ]]; then
            disable_reasons="${disable_reasons}${domain}: ${reason}"$'\n'
        fi
    elif [[ "$state_n" -gt 0 ]]; then
        # Histeresis (solo con hayahora accesible; si esta caida manda el
        # timeout de arriba): rehabilitar tras MIN_CLEAR_MINUTES libre seguido
        if [[ "$hayahora_ok" == "true" ]]; then
            now="$(date +%s)"
            # Marca guardada: epoch base 10; cualquier otra cosa es "sin marca"
            clear_since="$(parse_uint "$(clear_since_for "$domain")" 0 9999999999 || true)"
            if ! restore_due "$clear_since" "$now" "$MIN_CLEAR_SECONDS"; then
                if [[ ! "$clear_since" =~ ^[0-9]+$ ]]; then
                    if [[ "$DRY_RUN" == "true" ]]; then
                        log "DRY_RUN" "  Libre por primera vez. Se empezaria a contar ${MIN_CLEAR_MINUTES}m antes de rehabilitar $domain."
                        continue
                    fi
                    set_clear_since "$domain" "$now" || {
                        log "ERROR" "  No se pudo guardar la marca de libre de $domain"
                        any_error=true
                    }
                    clear_since="$now"
                fi
                clear_elapsed=$((now - clear_since))
                clear_wait=$(( (MIN_CLEAR_SECONDS - clear_elapsed + 59) / 60 ))
                log "INFO" "  Libre desde hace $((clear_elapsed / 60))m, rehabilitando en ${clear_wait}m (MIN_CLEAR_MINUTES=${MIN_CLEAR_MINUTES})."
                continue
            fi
        fi
        if [[ "$DRY_RUN" == "true" ]]; then
            log "DRY_RUN" "  ACCION NECESARIA: bloqueo terminado. Se REHABILITARIA el proxy en $state_n registro(s) de $domain."
            continue
        fi
        enable_domain "$zone_id" "$domain"
        [[ -n "$reason" ]] && enable_reasons="${enable_reasons}${domain}: ${reason}"$'\n'
    else
        log "INFO" "  Sin bloqueo y proxy activo. Sin accion."
    fi
done

if [[ "$checked_domains" -eq 0 ]]; then
    log "INFO" "Ningun dominio con IPs de Cloudflare que comprobar. Si el proxy esta activo, comprueba la configuracion de DNS."
fi

if [[ "$DRY_RUN" == "true" ]]; then
    log "DRY_RUN" "No se ha modificado nada en Cloudflare (modo prueba)"
    exit 0
fi

# =============================================================================
# PASO 4: Resumen, limpieza y notificaciones
# =============================================================================

final_count="$(read_state | jq 'length')"
if [[ "$final_count" -eq 0 ]] && [[ -f "$STATE_FILE" || -f "$CF_IPS_FILE" || -f "$CLEAR_FILE" ]]; then
    if state_quarantine_exists; then
        # Con el state en cuarentena las IPs guardadas indican que dominios
        # pueden tener registros en gris: no se borran
        rm -f "$STATE_FILE"
    else
        rm -f "$STATE_FILE" "$CF_IPS_FILE" "$CLEAR_FILE"
        log "INFO" "Todos los registros restaurados. State file eliminado."
    fi
fi

notify_corrupt_files

if [[ "$total_disabled" -gt 0 ]]; then
    log "INFO" "Total en state file: $final_count registro(s) ($total_disabled nuevos en esta ejecucion)"
    notify_telegram "$(cat <<EOF
🔴 <b>Proxy Cloudflare DESHABILITADO</b>

LaLiga ha activado bloqueos. Se ha quitado el proxy (nube naranja → gris) en $total_disabled registro(s) nuevo(s), $final_count en total:

<code>$(html_escape "$(truncate_text "$new_disabled_lines" $(( (TELEGRAM_TEXT_BUDGET - 500) / 2 )))")</code>

Motivo:
$(html_escape "$(truncate_text "$disable_reasons" $(( (TELEGRAM_TEXT_BUDGET - 500) / 2 )))")${partial_warnings:+

⚠️ Mitigacion parcial:
$(html_escape "$(truncate_text "$partial_warnings" 500)")}
EOF
)"
fi

if [[ "$total_reapplied" -gt 0 ]]; then
    notify_telegram "$(cat <<EOF
⚠️ <b>Alguien reactivo el proxy de Cloudflare durante el bloqueo</b>

Se ha vuelto a quitar (naranja → gris) en $total_reapplied registro(s):

<code>$(html_escape "$(truncate_text "$reapplied_names" "$TELEGRAM_TEXT_BUDGET")")</code>
EOF
)"
fi

if [[ "$total_restored" -gt 0 ]]; then
    notify_telegram "$(cat <<EOF
🟢 <b>Proxy Cloudflare REHABILITADO</b>

El bloqueo de LaLiga ha terminado. Se ha restaurado el proxy (nube gris → naranja) en $total_restored registro(s):

<code>$(html_escape "$(truncate_text "$restored_lines" $(( (TELEGRAM_TEXT_BUDGET - 400) / 2 )))")</code>
${enable_reasons:+
Motivo:
$(html_escape "$(truncate_text "$enable_reasons" $(( (TELEGRAM_TEXT_BUDGET - 400) / 2 )))")}${restore_pending_lines:+

Restauracion parcial, pendiente de reintentar:
$(html_escape "$(truncate_text "$restore_pending_lines" 400)")}
EOF
)"
fi

if [[ "$any_error" == "true" ]]; then
    log "WARN" "Algunos registros fallaron. Se reintentara en la proxima ejecucion."
fi

log "INFO" "Hecho."
