#!/usr/bin/env bash
# =============================================================================
# lib/ip-match.sh
# Funciones puras para decidir si una IP bloqueada por hayahora.futbol afecta
# a un dominio. Sin efectos secundarios: las usan toggle-proxy.sh y
# tests/test-ip-match.sh. Compatible con bash 3 (sin arrays asociativos).
# =============================================================================

# Comprobar si una IP pertenece a los rangos de Cloudflare
# Usa los rangos publicados en cloudflare.com/ips
is_cloudflare_ip() {
    local ip="$1"

    # IPv6: comprobar prefijos conocidos de Cloudflare
    if [[ "$ip" == *:* ]]; then
        local cf6_prefixes="2400:cb00 2606:4700 2803:f800 2405:b500 2405:8100 2a06:98c 2c0f:f248"
        local lower prefix
        lower="$(printf '%s' "$ip" | tr 'A-F' 'a-f')"
        for prefix in $cf6_prefixes; do
            [[ "$lower" == ${prefix}* ]] && return 0
        done
        return 1
    fi

    # Solo IPv4 con forma a.b.c.d (descarta CNAMEs que devuelve dig +short)
    [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1

    local oct1 oct2 oct3
    IFS='.' read -r oct1 oct2 oct3 _ <<< "$ip"

    # Rangos Cloudflare IPv4 (de cloudflare.com/ips-v4):
    # 103.21.244.0/22, 103.22.200.0/22, 103.31.4.0/22
    # 104.16.0.0/13 (104.16-23.x.x), 104.24.0.0/14 (104.24-27.x.x)
    # 108.162.192.0/18
    # 131.0.72.0/22
    # 141.101.64.0/18
    # 162.158.0.0/15 (162.158-159.x.x)
    # 172.64.0.0/13 (172.64-71.x.x)
    # 173.245.48.0/20
    # 188.114.96.0/20 (188.114.96-111.x.x)
    # 190.93.240.0/20
    # 197.234.240.0/22
    # 198.41.128.0/17 (198.41.128-255.x.x)
    case "$oct1" in
        103) [[ "$oct2" -eq 21 || "$oct2" -eq 22 || "$oct2" -eq 31 ]] && return 0 ;;
        104) [[ "$oct2" -ge 16 && "$oct2" -le 27 ]] && return 0 ;;
        108) [[ "$oct2" -eq 162 ]] && return 0 ;;
        131) [[ "$oct2" -eq 0 && "$oct3" -ge 72 && "$oct3" -le 75 ]] && return 0 ;;
        141) [[ "$oct2" -eq 101 ]] && return 0 ;;
        162) [[ "$oct2" -ge 158 && "$oct2" -le 159 ]] && return 0 ;;
        172) [[ "$oct2" -ge 64 && "$oct2" -le 71 ]] && return 0 ;;
        173) [[ "$oct2" -eq 245 ]] && return 0 ;;
        188) [[ "$oct2" -eq 114 && "$oct3" -ge 96 && "$oct3" -le 111 ]] && return 0 ;;
        190) [[ "$oct2" -eq 93 ]] && return 0 ;;
        197) [[ "$oct2" -eq 234 ]] && return 0 ;;
        198) [[ "$oct2" -eq 41 && "$oct3" -ge 128 ]] && return 0 ;;
    esac
    return 1
}

# Prefijo /48 normalizado de una IPv6 (los 3 primeros grupos, sin ceros a la
# izquierda, en minusculas). Expande "::". Ej: 2606:4700:0010::1 -> 2606:4700:10
ipv6_prefix48() {
    local ip head tail n i g out
    ip="$(printf '%s' "$1" | tr 'A-F' 'a-f')"
    ip="${ip%%%*}"  # quitar zona (%eth0) si la hubiera

    if [[ "$ip" == *::* ]]; then
        head="${ip%%::*}"
        tail="${ip#*::}"
    else
        head="$ip"
        tail=""
    fi

    local h=() t=() groups=()
    [[ -n "$head" ]] && IFS=':' read -ra h <<< "$head"
    [[ -n "$tail" ]] && IFS=':' read -ra t <<< "$tail"

    groups=(${h[@]+"${h[@]}"})
    n=$(( 8 - ${#h[@]} - ${#t[@]} ))
    for (( i = 0; i < n; i++ )); do groups+=("0"); done
    groups+=(${t[@]+"${t[@]}"})

    [[ ${#groups[@]} -ge 3 ]] || return 1

    out=""
    for (( i = 0; i < 3; i++ )); do
        g="${groups[$i]}"
        [[ "$g" =~ ^[0-9a-f]{1,4}$ ]] || return 1
        out="${out}$(printf '%x' "0x$g")"
        [[ $i -lt 2 ]] && out="${out}:"
    done
    printf '%s\n' "$out"
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

# Filtro jq: entradas de hayahora con bloqueo activo, como "ip<TAB>isp"
HAYAHORA_ACTIVE_JQ='.data[]
    | select((.stateChanges | length) > 0)
    | select(.stateChanges[-1].state == true)
    | "\(.ip)\t\(.isp)"'

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
