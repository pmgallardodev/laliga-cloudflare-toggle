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

# --- is_cloudflare_ip: pertenencia exacta a los rangos publicados (T7) ---
cf() { is_cloudflare_ip "$1" && echo si || echo no; }
# Conversion propia del test (independiente de la del lib)
t_ip2int() { local a b c d; IFS=. read -r a b c d <<< "$1"; echo $(( (a << 24) + (b << 16) + (c << 8) + d )); }
t_int2ip() { echo "$(( ($1 >> 24) & 255 )).$(( ($1 >> 16) & 255 )).$(( ($1 >> 8) & 255 )).$(( $1 & 255 ))"; }
# Fuera de un rango pero dentro del contiguo: 104.16.0.0/13 y 104.24.0.0/14
adjacent_cf="104.24.0.0 104.23.255.255"
n_ranges=0
for range in $CF_IPV4_RANGES; do
    n_ranges=$((n_ranges + 1))
    first="$(t_ip2int "${range%/*}")"
    last=$(( first + (1 << (32 - ${range#*/})) - 1 ))
    check "cf4 $range primera" "si" "$(cf "$(t_int2ip "$first")")"
    check "cf4 $range ultima" "si" "$(cf "$(t_int2ip "$last")")"
    for out in "$(t_int2ip $((first - 1)))" "$(t_int2ip $((last + 1)))"; do
        expected=no
        [[ " $adjacent_cf " == *" $out "* ]] && expected=si
        check "cf4 $range justo fuera ($out)" "$expected" "$(cf "$out")"
    done
done
check "cf4: 15 rangos publicados" "15" "$n_ranges"
check "cf4: 108.162.1.2 fuera de 108.162.192.0/18" "no" "$(cf 108.162.1.2)"
check "cf4: 131.0.76.1 fuera de 131.0.72.0/22" "no" "$(cf 131.0.76.1)"
check "cf4: octeto > 255" "no" "$(cf 104.16.0.256)"
check "cf4: ceros a la izquierda" "no" "$(cf 104.016.0.1)"
check "cf4: tres octetos" "no" "$(cf 104.16.0)"

F6="ffff:ffff:ffff:ffff:ffff:ffff"
# rango | primera | ultima | justo antes | justo despues
v6_cases="2400:cb00::/32|2400:cb00::|2400:cb00:$F6|2400:caff:$F6|2400:cb01::
2606:4700::/32|2606:4700::|2606:4700:$F6|2606:46ff:$F6|2606:4701::
2803:f800::/32|2803:f800::|2803:f800:$F6|2803:f7ff:$F6|2803:f801::
2405:b500::/32|2405:b500::|2405:b500:$F6|2405:b4ff:$F6|2405:b501::
2405:8100::/32|2405:8100::|2405:8100:$F6|2405:80ff:$F6|2405:8101::
2a06:98c0::/29|2a06:98c0::|2a06:98c7:$F6|2a06:98bf:$F6|2a06:98c8::
2c0f:f248::/32|2c0f:f248::|2c0f:f248:$F6|2c0f:f247:$F6|2c0f:f249::"
n_ranges=0
cf6_flat=" $(tr '\n' ' ' <<< "$CF_IPV6_RANGES") "
while IFS='|' read -r range first last below above; do
    n_ranges=$((n_ranges + 1))
    [[ "$cf6_flat" == *" $range "* ]] || check "cf6 $range esta en CF_IPV6_RANGES" "si" "no"
    check "cf6 $range primera" "si" "$(cf "$first")"
    check "cf6 $range ultima" "si" "$(cf "$last")"
    check "cf6 $range justo antes" "no" "$(cf "$below")"
    check "cf6 $range justo despues" "no" "$(cf "$above")"
done <<< "$v6_cases"
check "cf6: 7 rangos publicados" "7" "$(wc -w <<< "$CF_IPV6_RANGES" | xargs)"
check "cf6: 2a06:98cf::1 fuera de /29" "no" "$(cf 2a06:98cf::1)"
check "cf6: mayusculas" "si" "$(cf 2606:4700:3030::AC43:1)"
check "cf6: dos ::" "no" "$(cf 2606:4700::1::2)"
check "cf6: grupo no hex" "no" "$(cf 2606:4700:gggg::1)"
check "cf6: nueve grupos" "no" "$(cf 2606:4700:0:0:0:0:0:0:1)"
check "cf6: siete grupos sin ::" "no" "$(cf 2606:4700:0:0:0:0:1)"
check "cf6: dos puntos al final" "no" "$(cf 2606:4700::1:)"

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

# --- restore_due: histeresis antes de rehabilitar ---
due() { restore_due "$@" && echo due || echo wait; }
check "restore_due: sin marca de libre espera" "wait" "$(due "" 1000 900)"
check "restore_due: sin marca y 0 minutos rehabilita ya" "due" "$(due "" 1000 0)"
check "restore_due: 0 minutos con marca rehabilita ya" "due" "$(due 1000 1000 0)"
check "restore_due: un segundo antes del limite espera" "wait" "$(due 1000 1899 900)"
check "restore_due: justo en el limite rehabilita" "due" "$(due 1000 1900 900)"
check "restore_due: pasado el limite rehabilita" "due" "$(due 1000 5000 900)"
check "restore_due: marca no numerica espera" "wait" "$(due "abc" 5000 900)"
check "restore_due: marca en el futuro espera" "wait" "$(due 6000 5000 900)"

# --- feed_is_valid: forma del feed de hayahora (T6) ---
valid() { printf '%s' "$1" | feed_is_valid && echo valid || echo invalid; }
check "feed_is_valid: fixture valido" "valid" "$(valid "$fixture")"
check "feed_is_valid: data vacia" "valid" "$(valid '{"data":[]}')"
check "feed_is_valid: description null" "valid" \
    "$(valid '{"data":[{"ip":"1.2.3.4","isp":"X","description":null,"stateChanges":[]}]}')"
check "feed_is_valid: sin description" "valid" "$(valid '{"data":[{"ip":"1.2.3.4","isp":"X","stateChanges":[]}]}')"
check "feed_is_valid: cuerpo vacio" "invalid" "$(valid '')"
check "feed_is_valid: no JSON" "invalid" "$(valid 'not json')"
check "feed_is_valid: objeto de error" "invalid" "$(valid '{"error":"maintenance"}')"
check "feed_is_valid: data null" "invalid" "$(valid '{"data":null}')"
check "feed_is_valid: data string" "invalid" "$(valid '{"data":"unavailable"}')"
check "feed_is_valid: array en la raiz" "invalid" "$(valid '[]')"
check "feed_is_valid: dos documentos" "invalid" "$(valid '{"data":[]}{"data":[]}')"
check "feed_is_valid: stateChanges objeto" "invalid" \
    "$(valid '{"data":[{"ip":"1.2.3.4","isp":"X","stateChanges":{"state":true}}]}')"
check "feed_is_valid: stateChanges con no objetos" "invalid" \
    "$(valid '{"data":[{"ip":"1.2.3.4","isp":"X","stateChanges":[true]}]}')"
check "feed_is_valid: ip numerica" "invalid" "$(valid '{"data":[{"ip":1,"isp":"X","stateChanges":[]}]}')"
check "feed_is_valid: isp ausente" "invalid" "$(valid '{"data":[{"ip":"1.2.3.4","stateChanges":[]}]}')"
check "feed_is_valid: description numerica" "invalid" \
    "$(valid '{"data":[{"ip":"1.2.3.4","isp":"X","description":5,"stateChanges":[]}]}')"
check "feed_is_valid: entrada no objeto" "invalid" "$(valid '{"data":["1.2.3.4"]}')"

# --- parse_uint: enteros base 10 con limites (T8) ---
pu() { parse_uint "$@" || echo "invalid"; }
check "parse_uint: 08 es 8 (no octal)" "8" "$(pu 08 0 100)"
check "parse_uint: 010 es 10" "10" "$(pu 010 0 100)"
check "parse_uint: 0" "0" "$(pu 0 0 100)"
check "parse_uint: 0000 es 0" "0" "$(pu 0000 0 100)"
check "parse_uint: limite superior incluido" "100" "$(pu 100 0 100)"
check "parse_uint: por encima del limite" "invalid" "$(pu 101 0 100)"
check "parse_uint: por debajo del minimo" "invalid" "$(pu 0 1 100)"
check "parse_uint: vacio" "invalid" "$(pu '' 0 100)"
check "parse_uint: negativo" "invalid" "$(pu -1 0 100)"
check "parse_uint: decimal" "invalid" "$(pu 1.5 0 100)"
check "parse_uint: espacios" "invalid" "$(pu ' 5' 0 100)"
check "parse_uint: desbordamiento" "invalid" "$(pu 99999999999999999999999 0 100)"
check "parse_uint: texto" "invalid" "$(pu abc 0 100)"

# --- iso_to_epoch: marcas ISO 8601 legacy, siempre UTC (T9) ---
iso() { iso_to_epoch "$1" || echo "invalid"; }
check "iso_to_epoch: Z" "1794052800" "$(iso 2026-11-07T12:00:00Z)"
check "iso_to_epoch: Z con TZ=Europe/Madrid" "1794052800" "$(TZ=Europe/Madrid iso_to_epoch 2026-11-07T12:00:00Z)"
check "iso_to_epoch: epoch 0" "0" "$(iso 1970-01-01T00:00:00Z)"
check "iso_to_epoch: bisiesto" "1709251199" "$(iso 2024-02-29T23:59:59Z)"
check "iso_to_epoch: offset +01:00" "1794052800" "$(iso 2026-11-07T13:00:00+01:00)"
check "iso_to_epoch: offset -0230" "1794061800" "$(iso 2026-11-07T12:00:00-0230)"
check "iso_to_epoch: fraccion de segundo" "1794052800" "$(iso 2026-11-07T12:00:00.123Z)"
check "iso_to_epoch: verano (julio)" "1783425600" "$(iso 2026-07-07T12:00:00Z)"
check "iso_to_epoch: basura" "invalid" "$(iso garbage)"
check "iso_to_epoch: mes 13" "invalid" "$(iso 2026-13-07T12:00:00Z)"
check "iso_to_epoch: hora 24" "invalid" "$(iso 2026-11-07T24:00:00Z)"

# --- epoch_of: disabled_at numerico o ISO ---
eo() { epoch_of "$1" || echo "invalid"; }
check "epoch_of: numerico" "1794052800" "$(eo 1794052800)"
check "epoch_of: numerico con ceros" "8" "$(eo 08)"
check "epoch_of: ISO" "1794052800" "$(eo 2026-11-07T12:00:00Z)"
check "epoch_of: null" "invalid" "$(eo null)"
check "epoch_of: vacio" "invalid" "$(eo '')"

# --- canon_name: nombres DNS canonicos (T10) ---
check "canon_name: minusculas y sin punto final" "example.test" "$(canon_name "EXAMPLE.Test.")"
check "canon_name: ya canonico" "www.example.test" "$(canon_name www.example.test)"
check "canon_name: recorta espacios" "example.test" "$(canon_name "  Example.test ")"
check "canon_name: vacio" "" "$(canon_name "")"

echo
echo "Resultado: $pass ok, $fail fallos"
[[ "$fail" -eq 0 ]]
