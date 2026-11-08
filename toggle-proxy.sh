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
    source "$ENV_FILE"
    set +a
fi

# --- Valores por defecto ----------------------------------------------------

LOG_FILE="${LOG_FILE:-${SCRIPT_DIR}/logs/toggle-proxy.log}"
STATE_FILE="${STATE_FILE:-${SCRIPT_DIR}/state/proxy_disabled.json}"
LOCK_FILE="${SCRIPT_DIR}/state/toggle-proxy.lock"
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

log() {
    local level="$1"
    shift
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$timestamp] [$level] $*" | tee -a "$LOG_FILE"
}

notify_telegram() {
    local message="$1"
    if [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]]; then
        # Cuerpo JSON (no -d campo=valor): un "&" en el texto no puede partir
        # el mensaje en campos de formulario extra
        local payload
        payload="$(telegram_payload "$TELEGRAM_CHAT_ID" "$message")" || {
            log "WARN" "No se pudo construir la notificacion de Telegram"
            return 0
        }
        # Capturar la respuesta: Telegram contesta HTTP 400 con ok=false (p.ej.
        # mensaje > 4096 caracteres) y antes se perdia sin dejar rastro
        local response tg_ok tg_desc
        response="$(curl -s --max-time 10 \
            "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -H 'Content-Type: application/json' \
            --data-binary "$payload" 2>/dev/null)" || {
            log "WARN" "No se pudo enviar notificacion de Telegram (error de red)"
            return 0
        }
        tg_ok="$(printf '%s' "$response" | jq -r '.ok' 2>/dev/null || true)"
        if [[ "$tg_ok" != "true" ]]; then
            tg_desc="$(printf '%s' "$response" | jq -r '.description // empty' 2>/dev/null || true)"
            log "ERROR" "Telegram rechazo la notificacion: ${tg_desc:-respuesta no valida: ${response:0:200}}"
        fi
    fi
    return 0
}

# Comprobar si un registro DNS pertenece a un dominio protegido
# Devuelve 0 (true) si el nombre coincide con un dominio protegido o es subdominio de el
is_protected_domain() {
    local record_name="$1"
    local all_protected="${PROTECTED_DOMAINS_BUILTIN}"
    if [[ -n "$PROTECTED_DOMAINS" ]]; then
        all_protected="${all_protected},${PROTECTED_DOMAINS}"
    fi

    IFS=',' read -ra prot_list <<< "$all_protected"
    for prot in "${prot_list[@]}"; do
        prot="$(echo "$prot" | xargs)"
        [[ -z "$prot" ]] && continue
        if [[ "$record_name" == "$prot" || "$record_name" == *".${prot}" ]]; then
            return 0
        fi
    done
    return 1
}


# Escritura atomica: escribe a tmp y luego mv (previene corrupcion por crash)
atomic_write() {
    local file="$1"
    local content="$2"
    echo "$content" > "${file}.tmp" && mv "${file}.tmp" "$file"
}

# Leer state file de forma segura (devuelve [] si no existe o esta corrupto)
read_state() {
    if [[ -f "$STATE_FILE" ]] && [[ -s "$STATE_FILE" ]]; then
        jq '.' "$STATE_FILE" 2>/dev/null || echo '[]'
    else
        echo '[]'
    fi
}

cleanup() {
    rm -f "$LOCK_FILE"
}

# --- Lock file (prevenir ejecucion concurrente) -----------------------------

if [[ -f "$LOCK_FILE" ]]; then
    lock_pid="$(cat "$LOCK_FILE" 2>/dev/null || echo "")"
    if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
        log "WARN" "Otra instancia en ejecucion (PID $lock_pid). Saliendo."
        exit 0
    else
        log "WARN" "Lock file huerfano encontrado (PID $lock_pid ya no existe). Limpiando."
        rm -f "$LOCK_FILE"
    fi
fi

echo $$ > "$LOCK_FILE"
trap cleanup EXIT

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

cf_api() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"

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
    response="$(curl --max-time 30 "${args[@]}")"

    local http_code
    http_code="$(echo "$response" | tail -1)"
    local body
    body="$(echo "$response" | sed '$d')"

    if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
        # Incluir los errores de Cloudflare (p.ej. code 1043 en registros read-only)
        local cf_errors
        cf_errors="$(echo "$body" | jq -c '.errors // empty' 2>/dev/null || true)"
        log "ERROR" "Cloudflare API $method $endpoint -> HTTP $http_code${cf_errors:+ $cf_errors}"
        return 1
    fi

    local success
    success="$(echo "$body" | jq -r '.success' 2>/dev/null || echo "false")"
    if [[ "$success" != "true" ]]; then
        log "ERROR" "Cloudflare API error: $(echo "$body" | jq -c '.errors' 2>/dev/null)"
        return 1
    fi

    echo "$body"
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

# Filtro jq: registros del state que pertenecen a un dominio de DOMAINS.
# Las entradas nuevas llevan "domain"; las antiguas se asignan por nombre.
STATE_MINE_JQ='def mine($zid; $d):
    .zone_id == $zid
    and ((.domain // null) == $d
         or ((.domain // null) == null and (.name == $d or (.name | endswith("." + $d)))));'

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

# Numero de registros en el state file que pertenecen al dominio
domain_state_count() {
    read_state | jq --arg zid "$1" --arg d "$2" "$STATE_MINE_JQ"' [.[] | select(mine($zid; $d))] | length'
}

# Leer el archivo de IPs guardadas ({} si no existe o esta corrupto).
# Formato actual: {"dominio": ["ip", ...]}. Formato antiguo: ["ip", ...].
read_ips_file() {
    if [[ -f "$CF_IPS_FILE" ]] && [[ -s "$CF_IPS_FILE" ]]; then
        jq -c '.' "$CF_IPS_FILE" 2>/dev/null || echo '{}'
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
    domain="${entry#*:}"
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

MAX_DISABLED_SECONDS="${MAX_DISABLED_HOURS:-12}"
MAX_DISABLED_SECONDS=$((MAX_DISABLED_SECONDS * 3600))

hayahora_ok=true
hayahora_data="$(curl -s --max-time 15 "$HAYAHORA_API")" || hayahora_ok=false

if [[ "$hayahora_ok" == "true" ]] && ! echo "$hayahora_data" | jq empty 2>/dev/null; then
    hayahora_ok=false
fi

if [[ "$hayahora_ok" == "true" ]]; then
    # Entradas con bloqueo activo ("ip<TAB>isp"), calculadas una sola vez
    hayahora_active="$(echo "$hayahora_data" | jq -r "$HAYAHORA_ACTIVE_JQ")"
    # Para state files antiguos sin IPs guardadas: cualquier bloqueo de Cloudflare
    cf_blocked_count="$(echo "$hayahora_data" | jq '
        [.data[]
         | select(.description | test("^Cloudflare"))
         | select(.stateChanges | length > 0)
         | select(.stateChanges[-1].state == true)
        ] | length
    ')"
    log "INFO" "hayahora.futbol: $(echo "$hayahora_data" | jq "[${HAYAHORA_ACTIVE_JQ}] | length") entrada(s) con bloqueo activo"
else
    log "WARN" "No se pudo obtener datos de $HAYAHORA_API"
    if [[ "$(read_state | jq 'length')" -eq 0 ]]; then
        log "INFO" "Sin state file activo. Abortando sin cambios (fail-safe)."
        exit 0
    fi
fi

# =============================================================================
# PASO 2 y 3: Decidir y actuar dominio a dominio
# =============================================================================

any_error=false
total_disabled=0
total_reapplied=0
reapplied_names=""
disable_reasons=""
restored_lines=""
total_restored=0
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
    local record_type record_content record_ttl body new_state

    records_json="$(cf_api GET "/zones/${zone_id}/dns_records?per_page=100")" || {
        log "ERROR" "No se pudieron obtener registros DNS para $domain. Saltando."
        any_error=true
        return 0
    }

    # Solo registros proxied del dominio y subdominios. Los read-only (p.ej.
    # creados por un Worker) no se pueden editar: Cloudflare responde 400/1043
    target_records="$(echo "$records_json" | jq -c --arg domain "$domain" '
        [.result[]
         | select(.type == "A" or .type == "AAAA" or .type == "CNAME")
         | select(.name == $domain or (.name | endswith("." + $domain)))
         | select(.proxiable == true)
         | select(.proxied == true)
         | select((.meta.read_only // false) != true)
         | {id, name, type, content, ttl}
        ]
    ')"

    record_count="$(echo "$target_records" | jq 'length')"

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
        record_ttl="$(echo "$record" | jq '.ttl')"

        # PROTECCION: nunca deshabilitar proxy en dominios protegidos
        if is_protected_domain "$record_name"; then
            log "WARN" "  [PROTEGIDO] $record_name esta en la lista de dominios protegidos. NO se tocara."
            continue
        fi

        body="$(jq -n \
            --arg name "$record_name" \
            --arg type "$record_type" \
            --arg content "$record_content" \
            --argjson ttl "$record_ttl" \
            '{name: $name, type: $type, content: $content, ttl: $ttl, proxied: false}'
        )"

        # Si ya esta en state file pero vuelve a estar proxied, alguien (o algo)
        # ha reactivado la nube naranja durante el bloqueo: hay que volver a
        # quitarla. Antes se saltaba y la web se quedaba caida todo el partido.
        if jq -e --arg id "$record_id" '.[] | select(.record_id == $id)' "$STATE_FILE" >/dev/null 2>&1; then
            if cf_api PATCH "/zones/${zone_id}/dns_records/${record_id}" "$body" >/dev/null; then
                log "WARN" "  [REAPLICADO] $record_name estaba en state file pero alguien reactivo el proxy. Quitado de nuevo."
                total_reapplied=$((total_reapplied + 1))
                reapplied_names="${reapplied_names}  - ${record_name}"$'\n'
            else
                log "ERROR" "  [FAIL] No se pudo volver a deshabilitar proxy para $record_type $record_name"
                any_error=true
            fi
            continue
        fi

        if cf_api PATCH "/zones/${zone_id}/dns_records/${record_id}" "$body" >/dev/null; then
            log "INFO" "  [OK] Proxy deshabilitado: $record_type $record_name -> $record_content"
            total_disabled=$((total_disabled + 1))

            # Guardar en state file INMEDIATAMENTE tras cada PATCH exitoso
            new_state="$(jq \
                --arg zid "$zone_id" \
                --arg domain "$domain" \
                --arg id "$record_id" \
                --arg name "$record_name" \
                --arg type "$record_type" \
                --arg content "$record_content" \
                --argjson ts "$(date +%s)" \
                '. + [{zone_id: $zid, domain: $domain, record_id: $id, name: $name, type: $type, content: $content, disabled_at: $ts}]' \
                "$STATE_FILE" 2>/dev/null)" && atomic_write "$STATE_FILE" "$new_state" || {
                log "ERROR" "  No se pudo actualizar state file para $record_name"
                any_error=true
            }
        else
            log "ERROR" "  [FAIL] No se pudo deshabilitar proxy para $record_type $record_name"
            any_error=true
        fi
    done
}

# Restaurar el proxy en los registros que este script quito a un dominio
enable_domain() {
    local zone_id="$1" domain="$2"

    log "INFO" "=== REHABILITANDO proxy de Cloudflare: $domain (zona: ${zone_id:0:8}...) ==="

    local state_records record_count i record_id record_name record_type
    local record_content record_ttl current current_proxied body new_state remaining

    state_records="$(read_state | jq -c --arg zid "$zone_id" --arg d "$domain" \
        "$STATE_MINE_JQ"' [.[] | select(mine($zid; $d))]')"
    record_count="$(echo "$state_records" | jq 'length')"

    log "INFO" "  Restaurando $record_count registro(s) deshabilitado(s) previamente"

    for i in $(seq 0 $((record_count - 1))); do
        record_id="$(echo "$state_records" | jq -r ".[$i].record_id")"
        record_name="$(echo "$state_records" | jq -r ".[$i].name")"

        # Obtener estado actual del registro en Cloudflare
        current="$(cf_api GET "/zones/${zone_id}/dns_records/${record_id}")" || {
            log "ERROR" "  No se pudo obtener registro $record_id ($record_name). Saltando."
            any_error=true
            continue
        }

        current_proxied="$(echo "$current" | jq '.result.proxied')"

        if [[ "$current_proxied" == "true" ]]; then
            log "INFO" "  [SKIP] $record_name ya tiene proxy activo"
        else
            record_type="$(echo "$current" | jq -r '.result.type')"
            record_content="$(echo "$current" | jq -r '.result.content')"
            record_ttl="$(echo "$current" | jq '.result.ttl')"

            body="$(jq -n \
                --arg name "$record_name" \
                --arg type "$record_type" \
                --arg content "$record_content" \
                --argjson ttl "$record_ttl" \
                '{name: $name, type: $type, content: $content, ttl: $ttl, proxied: true}'
            )"

            if cf_api PATCH "/zones/${zone_id}/dns_records/${record_id}" "$body" >/dev/null; then
                log "INFO" "  [OK] Proxy rehabilitado: $record_type $record_name"
            else
                log "ERROR" "  [FAIL] No se pudo rehabilitar proxy para $record_name"
                any_error=true
                continue  # No eliminar del state file si fallo
            fi
        fi

        # Eliminar este registro del state file INMEDIATAMENTE (crash-safe)
        new_state="$(jq --arg id "$record_id" 'map(select(.record_id != $id))' "$STATE_FILE" 2>/dev/null)" \
            && atomic_write "$STATE_FILE" "$new_state" || {
            log "ERROR" "  No se pudo actualizar state file tras rehabilitar $record_name"
            any_error=true
        }
    done

    remaining="$(domain_state_count "$zone_id" "$domain")"
    if [[ "$remaining" -eq 0 ]]; then
        forget_ips_for "$domain"
        log "INFO" "  Todos los registros de $domain restaurados."
        total_restored=$((total_restored + record_count))
        restored_lines="${restored_lines}$(echo "$state_records" | jq -r '.[] | "  - \(.type) \(.name)"')"$'\n'
    else
        log "WARN" "  $remaining registro(s) de $domain no se pudieron rehabilitar. Se reintentara en la proxima ejecucion."
    fi
}

checked_domains=0

for idx in "${!DOMAIN_NAMES[@]}"; do
    zone_id="${ZONE_IDS[$idx]}"
    domain="${DOMAIN_NAMES[$idx]}"
    state_n="$(domain_state_count "$zone_id" "$domain")"

    log "INFO" "--- $domain ---"

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
                    [[ -n "$reason" ]] && reason="${reason}; "
                    reason="${reason}${m_isp} bloqueando ${m_ip} (${m_rule})"
                    match_count=$((match_count + 1))
                done <<< "$matches"
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
        oldest_ts="$(read_state | jq -r --arg zid "$zone_id" --arg d "$domain" \
            "$STATE_MINE_JQ"' [.[] | select(mine($zid; $d))][0].disabled_at')"
        # disabled_at puede ser epoch (numerico) o ISO 8601 (legacy)
        if [[ "$oldest_ts" =~ ^[0-9]+$ ]]; then
            oldest_epoch="$oldest_ts"
        else
            oldest_epoch="$(date -d "$oldest_ts" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$oldest_ts" +%s 2>/dev/null || echo "")"
        fi
        # Si no se pudo parsear, no asumir timeout -- esperar
        if [[ -z "$oldest_epoch" || "$oldest_epoch" == "0" ]]; then
            log "WARN" "  No se pudo parsear disabled_at='$oldest_ts'. Esperando sin cambios."
            continue
        fi
        elapsed=$(( $(date +%s) - oldest_epoch ))
        if [[ "$elapsed" -lt "$MAX_DISABLED_SECONDS" ]]; then
            remaining_h=$(( (MAX_DISABLED_SECONDS - elapsed) / 3600 ))
            log "INFO" "  Proxy deshabilitado hace $(( elapsed / 3600 ))h. Quedan ~${remaining_h}h hasta rehabilitar por timeout. Esperando."
            continue
        fi
        log "WARN" "  Proxy deshabilitado hace $(( elapsed / 3600 ))h. Superado limite de ${MAX_DISABLED_HOURS:-12}h. Rehabilitando."
        reason="hayahora caida, timeout ${MAX_DISABLED_HOURS:-12}h alcanzado"
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
        # Guardar las IPs de Cloudflare actuales (antes de cambiar el proxy)
        # para comprobar en siguientes ejecuciones si el bloqueo sigue
        if [[ "$legacy_check" == "false" ]]; then
            save_ips_for "$domain" "$(echo "$candidates" | jq -R . | jq -sc .)"
        fi
        disable_domain "$zone_id" "$domain"
        disable_reasons="${disable_reasons}${domain}: ${reason}"$'\n'
    elif [[ "$state_n" -gt 0 ]]; then
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
if [[ "$final_count" -eq 0 ]] && [[ -f "$STATE_FILE" || -f "$CF_IPS_FILE" ]]; then
    rm -f "$STATE_FILE" "$CF_IPS_FILE"
    log "INFO" "Todos los registros restaurados. State file eliminado."
fi

if [[ "$total_disabled" -gt 0 ]]; then
    log "INFO" "Total en state file: $final_count registro(s) ($total_disabled nuevos en esta ejecucion)"
    records_list="$(jq -r '.[] | "  - \(.type) \(.name) → \(.content)"' "$STATE_FILE" 2>/dev/null)"
    notify_telegram "$(cat <<EOF
🔴 <b>Proxy Cloudflare DESHABILITADO</b>

LaLiga ha activado bloqueos. Se ha quitado el proxy (nube naranja → gris) en $final_count registro(s):

<code>$(html_escape "$(truncate_text "$records_list" $((TELEGRAM_TEXT_BUDGET / 2)))")</code>

Motivo:
$(html_escape "$(truncate_text "$disable_reasons" $((TELEGRAM_TEXT_BUDGET / 2)))")
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

<code>$(html_escape "$(truncate_text "$restored_lines" $((TELEGRAM_TEXT_BUDGET / 2)))")</code>
${enable_reasons:+
Motivo:
$(html_escape "$(truncate_text "$enable_reasons" $((TELEGRAM_TEXT_BUDGET / 2)))")}
EOF
)"
fi

if [[ "$any_error" == "true" ]]; then
    log "WARN" "Algunos registros fallaron. Se reintentara en la proxima ejecucion."
fi

log "INFO" "Hecho."
