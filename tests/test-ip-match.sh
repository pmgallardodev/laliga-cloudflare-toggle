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

# --- html_escape para Telegram (parse_mode=HTML) ---
check "html_escape: & < >" "&lt;b&gt;DIGI&lt;/b&gt; &amp; Co" "$(html_escape '<b>DIGI</b> & Co')"
check "html_escape: no re-escapa &amp;" "&amp;amp;" "$(html_escape '&amp;')"
check "html_escape: texto normal intacto" "DIGI bloqueando 188.114.96.5 (same24)" \
    "$(html_escape 'DIGI bloqueando 188.114.96.5 (same24)')"
check "html_escape: multilinea" "$(printf 'a &lt;x&gt;\nb')" "$(html_escape "$(printf 'a <x>\nb')")"
# isp malicioso del feed: find_blocks lo devuelve tal cual, el escape lo neutraliza
evil_fixture='{"data":[{"ip":"188.114.96.5","isp":"<a href=\"https://evil\">x</a>","stateChanges":[{"state":true}]}]}'
evil_isp="$(echo "$evil_fixture" | jq -r "$HAYAHORA_ACTIVE_JQ" | find_blocks "188.114.96.2" | cut -f1)"
check "html_escape: isp malicioso del feed" '&lt;a href="https://evil"&gt;x&lt;/a&gt;' "$(html_escape "$evil_isp")"

# --- telegram_payload: cuerpo JSON, sin inyeccion de campos ---
evil_text="$(printf 'a & parse_mode=Markdown&chat_id=666 "q" \\ <b>\nlinea2')"
payload="$(telegram_payload "-1001" "$evil_text")"
check "telegram_payload: JSON valido con 3 campos" "chat_id,parse_mode,text" \
    "$(echo "$payload" | jq -r 'keys | join(",")')"
check "telegram_payload: texto intacto (round-trip)" "$evil_text" "$(echo "$payload" | jq -r '.text')"
check "telegram_payload: chat_id y parse_mode no inyectables" "-1001 HTML" \
    "$(echo "$payload" | jq -r '"\(.chat_id) \(.parse_mode)"')"
check "telegram_payload: una sola linea" "1" "$(printf '%s\n' "$payload" | wc -l | xargs)"

# --- truncate_text: limite de caracteres (no bytes) para Telegram ---
# Cuenta caracteres Unicode con jq (independiente del locale)
chars() { printf '%s' "$1" | jq -Rs 'length'; }
check "truncate_text: corto intacto" "hola" "$(truncate_text "hola" 10)"
check "truncate_text: justo en el limite intacto" "0123456789" "$(truncate_text "0123456789" 10)"
check "truncate_text: conserva saltos de linea finales" "$(printf 'a\nb\n')." "$(truncate_text "$(printf 'a\nb\n')" 10; echo .)"
long="$(printf 'x%.0s' $(seq 1 200))"
cut_text="$(truncate_text "$long" 50)"
check "truncate_text: largo cabe en el limite" "50" "$(chars "$cut_text")"
check "truncate_text: largo lleva sufijo" "yes" "$([[ "$cut_text" == *"(truncado)" ]] && echo yes || echo no)"
check "truncate_text: largo empieza por el original" "yes" "$([[ "$cut_text" == xxxx* ]] && echo yes || echo no)"
multi="$(printf '→🙂ñ%.0s' $(seq 1 100))"
cut_multi="$(truncate_text "$multi" 40)"
check "truncate_text: multibyte cuenta caracteres" "40" "$(chars "$cut_multi")"
check "truncate_text: multibyte sigue siendo UTF-8 valido" "ok" \
    "$(printf '%s' "$cut_multi" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 && echo ok || echo roto)"
check "truncate_text: multibyte intacto si cabe" "$(printf '→🙂ñ')" "$(truncate_text "$(printf '→🙂ñ')" 3)"

# --- summarize_matches: motivo resumido por dominio ---
five="$(printf '%s\t%s\t%s\t%s\n' \
    DIGI 188.114.96.5 same24 188.114.96.2 \
    Movistar 188.114.97.5 exact 188.114.97.5 \
    Orange 188.114.96.7 same24 188.114.96.2 \
    Vodafone 188.114.96.8 same24 188.114.96.2 \
    Masmovil 188.114.96.9 same24 188.114.96.2)"
check "summarize_matches: corta en max y anade +N mas" \
    "5 coincidencias: DIGI 188.114.96.5 (same24), Movistar 188.114.97.5 (exact), Orange 188.114.96.7 (same24) +2 mas" \
    "$(summarize_matches 3 <<< "$five")"
check "summarize_matches: justo max sin +N mas" \
    "3 coincidencias: DIGI 188.114.96.5 (same24), Movistar 188.114.97.5 (exact), Orange 188.114.96.7 (same24)" \
    "$(head -3 <<< "$five" | summarize_matches 3)"
check "summarize_matches: una coincidencia en singular" \
    "1 coincidencia: DIGI 188.114.96.5 (same24)" "$(head -1 <<< "$five" | summarize_matches 3)"
check "summarize_matches: entrada vacia" "" "$(summarize_matches 3 < /dev/null)"
check "summarize_matches: ignora lineas vacias" \
    "1 coincidencia: DIGI 188.114.96.5 (same24)" "$(printf '\n%s\n\n' "$(head -1 <<< "$five")" | summarize_matches 3)"
check "summarize_matches: max 0 solo cuenta" "5 coincidencias: +5 mas" "$(summarize_matches 0 <<< "$five")"

echo
echo "Resultado: $pass ok, $fail fallos"
[[ "$fail" -eq 0 ]]
