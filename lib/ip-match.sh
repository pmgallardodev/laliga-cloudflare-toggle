#!/usr/bin/env bash
# =============================================================================
# lib/ip-match.sh
# Funciones puras para decidir si una IP bloqueada por hayahora.futbol afecta
# a un dominio. Sin efectos secundarios: las usan toggle-proxy.sh y
# tests/test-ip-match.sh. Compatible con bash 3 (sin arrays asociativos).
# =============================================================================

# Rangos publicados en https://www.cloudflare.com/ips/ (ips-v4 e ips-v6).
# Lista unica: is_cloudflare_ip y los tests la recorren.
CF_IPV4_RANGES="173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22
141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 197.234.240.0/22
198.41.128.0/17 162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 131.0.72.0/22"
CF_IPV6_RANGES="2400:cb00::/32 2606:4700::/32 2803:f800::/32 2405:b500::/32
2405:8100::/32 2a06:98c0::/29 2c0f:f248::/32"

# Validar una IPv4 a.b.c.d y dejar su valor entero en _IP4_INT.
# Rechaza octetos > 255 y con ceros a la izquierda. Sin subshells: se llama
# por cada entrada del feed.
ipv4_parse() {
    local o1 o2 o3 o4 o
    [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    o1="${BASH_REMATCH[1]}"
    o2="${BASH_REMATCH[2]}"
    o3="${BASH_REMATCH[3]}"
    o4="${BASH_REMATCH[4]}"
    for o in "$o1" "$o2" "$o3" "$o4"; do
        [[ "$o" == 0 || "$o" != 0* ]] || return 1
        [[ "$o" -le 255 ]] || return 1
    done
    _IP4_INT=$(( (o1 << 24) | (o2 << 16) | (o3 << 8) | o4 ))
}

# Validar una IPv6 y dejar sus 8 grupos (decimal) en el array _IP6.
# Admite "::" una vez, mayusculas y zona (%eth0). Sin IPv4 embebida.
ipv6_parse() {
    local ip="${1%%%*}" head tail n i g
    local h=() t=()
    [[ "$ip" =~ ^[0-9a-fA-F:]+$ ]] || return 1
    if [[ "$ip" == *::* ]]; then
        head="${ip%%::*}"
        tail="${ip#*::}"
        [[ "$tail" != *::* ]] || return 1
    else
        head="$ip"
        tail=""
    fi
    [[ "$head" != :* && "$head" != *: && "$tail" != :* && "$tail" != *: ]] || return 1
    if [[ -n "$head" ]]; then IFS=':' read -ra h <<< "$head"; fi
    if [[ -n "$tail" ]]; then IFS=':' read -ra t <<< "$tail"; fi
    if [[ "$ip" == *::* ]]; then
        n=$(( 8 - ${#h[@]} - ${#t[@]} ))
        [[ "$n" -ge 1 ]] || return 1
    else
        [[ ${#h[@]} -eq 8 ]] || return 1
        n=0
    fi
    _IP6=()
    for g in ${h[@]+"${h[@]}"}; do
        [[ "$g" =~ ^[0-9a-fA-F]{1,4}$ ]] || return 1
        _IP6+=( $((16#$g)) )
    done
    for (( i = 0; i < n; i++ )); do _IP6+=(0); done
    for g in ${t[@]+"${t[@]}"}; do
        [[ "$g" =~ ^[0-9a-fA-F]{1,4}$ ]] || return 1
        _IP6+=( $((16#$g)) )
    done
}

# Comprobar si una IP (v4 o v6) pertenece a los rangos de Cloudflare con
# pertenencia numerica exacta al prefijo. Un nombre (CNAME de dig) no lo es.
is_cloudflare_ip() {
    local ip="$1" range len shift_bits x i bits same
    if [[ "$ip" == *:* ]]; then
        ipv6_parse "$ip" || return 1
        local ipg=("${_IP6[@]}")
        for range in $CF_IPV6_RANGES; do
            len="${range#*/}"
            ipv6_parse "${range%/*}" || continue
            same=1
            for (( i = 0; i < 8; i++ )); do
                bits=$(( len - 16 * i ))
                if [[ "$bits" -le 0 ]]; then break; fi
                if [[ "$bits" -gt 16 ]]; then bits=16; fi
                shift_bits=$(( 16 - bits ))
                if [[ $(( ipg[i] >> shift_bits )) -ne $(( _IP6[i] >> shift_bits )) ]]; then
                    same=0
                    break
                fi
            done
            if [[ "$same" -eq 1 ]]; then return 0; fi
        done
        return 1
    fi

    ipv4_parse "$ip" || return 1
    x="$_IP4_INT"
    for range in $CF_IPV4_RANGES; do
        len="${range#*/}"
        ipv4_parse "${range%/*}" || continue
        shift_bits=$(( 32 - len ))
        if [[ $(( x >> shift_bits )) -eq $(( _IP4_INT >> shift_bits )) ]]; then return 0; fi
    done
    return 1
}

# Prefijo /48 normalizado de una IPv6 (los 3 primeros grupos, sin ceros a la
# izquierda, en minusculas). Expande "::". Ej: 2606:4700:0010::1 -> 2606:4700:10
ipv6_prefix48() {
    ipv6_parse "$1" || return 1
    printf '%x:%x:%x\n' "${_IP6[0]}" "${_IP6[1]}" "${_IP6[2]}"
}

# Clave de bloque vecino: /24 para IPv4 (a.b.c), /48 para IPv6
ip_block_key() {
    local ip="$1"
    if [[ "$ip" == *:* ]]; then
        ipv6_prefix48 "$ip"
    else
        printf '%s\n' "${ip%.*}"
    fi
}

# Nombre de la regla de vecindad segun la familia
ip_block_rule() {
    if [[ "$1" == *:* ]]; then echo "same48"; else echo "same24"; fi
}

# Comparar una IP bloqueada contra el conjunto de IPs candidatas de un dominio.
#   match_blocked_ip <ip_bloqueada> <candidata>...
# Imprime "<regla> <candidata>" y devuelve 0 si hay coincidencia:
#   exact   -> la IP bloqueada esta en el conjunto
#   same24  -> misma /24 IPv4 que una candidata y dentro de Cloudflare
#   same48  -> misma /48 IPv6 que una candidata y dentro de Cloudflare
# Devuelve 1 si no hay coincidencia. Exact tiene prioridad sobre vecindad.
match_blocked_ip() {
    local blocked="$1"
    shift
    [[ -n "$blocked" ]] || return 1

    local blocked_norm cand cand_norm
    blocked_norm="$(printf '%s' "$blocked" | tr 'A-F' 'a-f')"

    for cand in "$@"; do
        cand_norm="$(printf '%s' "$cand" | tr 'A-F' 'a-f')"
        if [[ "$cand_norm" == "$blocked_norm" ]]; then
            echo "exact $cand"
            return 0
        fi
    done

    # Vecindad: solo si la IP bloqueada es de Cloudflare (IP compartida anycast)
    is_cloudflare_ip "$blocked" || return 1

    local blocked_key cand_key
    blocked_key="$(ip_block_key "$blocked")" || return 1
    for cand in "$@"; do
        # No mezclar familias
        if [[ "$cand" == *:* && "$blocked" != *:* ]] || [[ "$cand" != *:* && "$blocked" == *:* ]]; then
            continue
        fi
        is_cloudflare_ip "$cand" || continue
        cand_key="$(ip_block_key "$cand")" || continue
        if [[ "$cand_key" == "$blocked_key" ]]; then
            echo "$(ip_block_rule "$blocked") $cand"
            return 0
        fi
    done
    return 1
}

# Escapar texto para mensajes de Telegram con parse_mode=HTML.
# Todo valor externo (feed de hayahora, nombres de dominio y registros) pasa
# por aqui antes de componer el mensaje. & primero para no re-escapar.
# sed y no ${var//&/...}: en bash >= 5.2 "&" en el reemplazo es el match.
html_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# Cuerpo JSON para sendMessage de Telegram. jq codifica el texto, asi que
# "&", "=" o saltos de linea no pueden inyectar campos. El HTML del texto
# debe venir ya escapado con html_escape.
telegram_payload() {
    jq -nc --arg chat_id "$1" --arg text "$2" \
        '{chat_id: $chat_id, text: $text, parse_mode: "HTML"}'
}

# Recortar texto a un maximo de caracteres (no bytes) para Telegram.
#   truncate_text <texto> <max_caracteres>
# Si no cabe, corta y anade "\n… (truncado)" sin pasarse del maximo.
# jq cuenta y corta por caracteres Unicode, asi que no parte emojis ni
# flechas aunque el locale del contenedor sea C. Recortar el texto en crudo,
# antes de html_escape: asi nunca se corta una entidad (&amp;) por la mitad.
truncate_text() {
    jq -nj --arg s "$1" --argjson max "$2" --arg suffix $'\n… (truncado)' '
        if ($s | length) <= $max then $s
        elif ($suffix | length) >= $max then $s[0:$max]
        else $s[0:($max - ($suffix | length))] + $suffix
        end'
}

# Resumir las coincidencias de un dominio para el motivo de la alerta.
#   summarize_matches <max> < lineas "isp<TAB>ip<TAB>regla<TAB>candidata"
# Imprime "N coincidencias: ISP ip (regla), ... +M mas" con como mucho <max>
# coincidencias detalladas. Sin coincidencias no imprime nada.
summarize_matches() {
    local max="$1" total=0 shown="" isp ip rule _cand
    while IFS=$'\t' read -r isp ip rule _cand; do
        [[ -n "$ip" ]] || continue
        total=$((total + 1))
        if [[ "$total" -le "$max" ]]; then
            [[ -n "$shown" ]] && shown="${shown}, "
            shown="${shown}${isp} ${ip} (${rule})"
        fi
    done
    [[ "$total" -gt 0 ]] || return 0

    local out="${total} coincidencias:"
    [[ "$total" -eq 1 ]] && out="1 coincidencia:"
    [[ -n "$shown" ]] && out="${out} ${shown}"
    [[ "$total" -gt "$max" ]] && out="${out} +$((total - max)) mas"
    printf '%s\n' "$out"
}

# Histeresis: decidir si ya toca rehabilitar un dominio que esta libre.
#   restore_due <libre_desde_epoch_o_vacio> <ahora_epoch> <min_segundos>
# Devuelve 0 si lleva libre al menos <min_segundos> (o si min es 0).
# Sin marca valida devuelve 1: el dominio acaba de quedar libre.
restore_due() {
    local clear_since="$1" now="$2" min_seconds="$3"
    [[ "$min_seconds" -le 0 ]] && return 0
    [[ "$clear_since" =~ ^[0-9]+$ ]] || return 1
    [[ $((now - clear_since)) -ge "$min_seconds" ]]
}

# Filtro jq: entradas de hayahora con bloqueo activo, como "ip<TAB>isp"
# shellcheck disable=SC2034  # la usan toggle-proxy.sh y los tests
HAYAHORA_ACTIVE_JQ='.data[]
    | select((.stateChanges | length) > 0)
    | select(.stateChanges[-1].state == true)
    | "\(.ip)\t\(.isp)"'

# Validar la forma del feed de hayahora (lee stdin). Devuelve 0 solo si es
# exactamente un objeto JSON con .data array de objetos con ip/isp string,
# description string o null y stateChanges array de objetos. Cualquier otra
# cosa (cuerpo vacio, {"error":..}, data null...) es "feed no disponible".
feed_is_valid() {
    jq -se '
        length == 1
        and (.[0] | type == "object"
            and (.data | type) == "array"
            and all(.data[];
                type == "object"
                and (.ip | type) == "string"
                and (.isp | type) == "string"
                and ((.description | type) as $t | $t == "string" or $t == "null")
                and (.stateChanges | type) == "array"
                and all(.stateChanges[]; type == "object")))
    ' >/dev/null 2>&1
}

# Buscar bloqueos activos que afectan a un conjunto de candidatas.
#   find_blocks <candidatas_separadas_por_salto_de_linea>
# Lee de stdin lineas "ip<TAB>isp" (salida de HAYAHORA_ACTIVE_JQ) e imprime
# una linea "isp<TAB>ip_bloqueada<TAB>regla<TAB>candidata" por coincidencia.
find_blocks() {
    local candidates_str="$1"
    local cands=() c
    while IFS= read -r c; do
        [[ -n "$c" ]] && cands+=("$c")
    done <<< "$candidates_str"
    [[ ${#cands[@]} -gt 0 ]] || return 0

    local ip isp result rule cand
    while IFS=$'\t' read -r ip isp; do
        [[ -n "$ip" ]] || continue
        if result="$(match_blocked_ip "$ip" "${cands[@]}")"; then
            rule="${result%% *}"
            cand="${result#* }"
            printf '%s\t%s\t%s\t%s\n' "$isp" "$ip" "$rule" "$cand"
        fi
    done
    return 0
}
