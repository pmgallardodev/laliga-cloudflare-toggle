#!/usr/bin/env bash
# Tests de lib/ip-match.sh. Uso: bash tests/test-ip-match.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/ip-match.sh
source "${ROOT_DIR}/lib/ip-match.sh"

pass=0
fail=0

check() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "PASS  $name"
        pass=$((pass + 1))
    else
        echo "FAIL  $name"
        echo "      esperado: '$expected'"
        echo "      obtenido: '$actual'"
        fail=$((fail + 1))
    fi
}

# match_blocked_ip devuelve "<regla> <candidata>" o "NOMATCH"
m() { match_blocked_ip "$@" || echo "NOMATCH"; }

# --- Caso real del 1-nov-2026: vemos .2 desde Alemania, Espana recibe .5 ---
check "exact IPv4" \
    "exact 188.114.96.5" "$(m 188.114.96.5 188.114.96.2 188.114.96.5)"
check "misma /24 IPv4 (bloqueada .5, resolvemos .2/.3)" \
    "same24 188.114.97.2" "$(m 188.114.97.5 188.114.96.2 188.114.97.2 188.114.97.3)"
check "exact gana a /24" \
    "exact 188.114.97.5" "$(m 188.114.97.5 188.114.97.2 188.114.97.5)"
check "sin match: otra /24 de Cloudflare" \
    "NOMATCH" "$(m 188.114.98.5 188.114.96.2 188.114.97.2)"
check "sin match: /24 compartida pero fuera de Cloudflare" \
    "NOMATCH" "$(m 203.0.113.9 203.0.113.10)"
check "sin match: conjunto vacio" \
    "NOMATCH" "$(m 188.114.96.5)"

# --- IPv6 /48 ---
check "exact IPv6" \
    "exact 2606:4700:3030::6815:1" "$(m 2606:4700:3030::6815:1 2606:4700:3030::6815:1)"
check "exact IPv6 ignora mayusculas" \
    "exact 2606:4700:3030::AC43:1" "$(m 2606:4700:3030::ac43:1 2606:4700:3030::AC43:1)"
check "misma /48 IPv6" \
    "same48 2606:4700:3030::6815:1" "$(m 2606:4700:3030::ac43:2b1 2606:4700:3030::6815:1)"
check "misma /48 IPv6 con ceros a la izquierda" \
    "same48 2606:4700:0010::6814:183a" "$(m 2606:4700:10::1 2606:4700:0010::6814:183a)"
check "sin match: otra /48 IPv6" \
    "NOMATCH" "$(m 2606:4700:3031::1 2606:4700:3030::6815:1)"
check "sin match: no mezcla familias" \
    "NOMATCH" "$(m 188.114.96.5 2606:4700:3030::6815:1)"

# --- Helpers de prefijo ---
check "ipv6_prefix48 expande ::" "2606:4700:0" "$(ipv6_prefix48 2606:4700::1)"
check "ipv6_prefix48 completa" "2a06:98c1:3120" "$(ipv6_prefix48 2A06:98C1:3120:0:0:0:0:5)"
check "ip_block_key IPv4" "188.114.96" "$(ip_block_key 188.114.96.5)"
check "is_cloudflare_ip descarta CNAME" "no" "$(is_cloudflare_ip foo.cdn.cloudflare.net. && echo si || echo no)"

# --- find_blocks sobre un fixture de hayahora ---
fixture='{"data":[
 {"ip":"188.114.96.5","isp":"DIGI","stateChanges":[{"state":false},{"state":true}]},
 {"ip":"188.114.97.5","isp":"Movistar","stateChanges":[{"state":true}]},
 {"ip":"188.114.97.5","isp":"Orange","stateChanges":[{"state":true},{"state":false}]},
 {"ip":"104.16.1.1","isp":"Vodafone","stateChanges":[{"state":true}]},
 {"ip":"2606:4700:3030::1","isp":"Masmovil","stateChanges":[{"state":true}]},
 {"ip":"172.67.1.1","isp":"DIGI","stateChanges":[]}
]}'
expected="$(printf '%s\n' \
    "DIGI	188.114.96.5	same24	188.114.96.2" \
    "Movistar	188.114.97.5	same24	188.114.97.2" \
    "Masmovil	2606:4700:3030::1	same48	2606:4700:3030::6815:1")"
actual="$(echo "$fixture" | jq -r "$HAYAHORA_ACTIVE_JQ" \
    | find_blocks "$(printf '%s\n' 188.114.96.2 188.114.97.2 2606:4700:3030::6815:1)")"
check "find_blocks: solo bloqueos activos y vecinos" "$expected" "$actual"

actual="$(echo "$fixture" | jq -r "$HAYAHORA_ACTIVE_JQ" | find_blocks "172.67.1.1")"
check "find_blocks: sin match" "" "$actual"

echo
echo "Resultado: $pass ok, $fail fallos"
[[ "$fail" -eq 0 ]]
