#!/usr/bin/env bash
# Las condiciones de ok() se evaluan con eval: shellcheck no ve esos usos
# shellcheck disable=SC2034
# Tests de integracion de toggle-proxy.sh con curl, dig y date falsos
# (tests/integration/bin). Nunca llaman a Cloudflare ni a Telegram de verdad.
# Uso: bash tests/test-integration.sh [patron]
#      TEST_BASH=/bin/bash bash tests/test-integration.sh   (bash 3)
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STUB_BIN="${ROOT_DIR}/tests/integration/bin"
TEST_BASH="${TEST_BASH:-bash}"
PATTERN="${1:-}"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/toggle-it.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

pass=0
fail=0

# --- Infraestructura ---------------------------------------------------------

# setup <caso>: copia la app a un directorio limpio y deja datos por defecto:
# un registro A proxied example.test, dig -> 104.21.13.225 y feed sin bloqueos.
setup() {
    CASE="$1"
    CASE_DIR="${TMP_ROOT}/${CASE}"
    APP="${CASE_DIR}/app"
    HDATA="${CASE_DIR}/data"
    mkdir -p "${APP}/lib" "${APP}/state" "${HDATA}/dns"
    cp "${ROOT_DIR}/toggle-proxy.sh" "${APP}/"
    cp "${ROOT_DIR}"/lib/*.sh "${APP}/lib/"
    STATE="${APP}/state/proxy_disabled.json"
    IPS="${APP}/state/proxy_disabled_ips.json"
    CLEAR="${APP}/state/proxy_disabled_clear.json"
    OUTBOX="${APP}/state/proxy_disabled_outbox.json"
    LOG="${APP}/logs/toggle-proxy.log"
    echo 2000000000 > "${HDATA}/now"
    records "[$(rec r1 example.test true)]"
    dns example.test A 104.21.13.225
    feed
}

# rec <id> <nombre> <proxied> [tipo] [contenido] [meta_json]
rec() {
    local empty_meta='{}'
    jq -nc --arg id "$1" --arg name "$2" --argjson p "$3" --arg type "${4:-A}" \
        --arg content "${5:-203.0.113.20}" --argjson meta "${6:-$empty_meta}" \
        '{id: $id, name: $name, type: $type, content: $content, ttl: 1,
          proxiable: true, proxied: $p, meta: $meta}'
}
records() { printf '%s\n' "$1" > "${HDATA}/records.json"; }
# dns <nombre> <tipo> <ip>...
dns() { local n="$1" t="$2"; shift 2; printf '%s\n' "$@" > "${HDATA}/dns/${n}.${t}"; }
# feed [ip:isp]...: entradas con bloqueo activo y descripcion Cloudflare
feed() {
    local e
    for e in "$@"; do
        jq -nc --arg ip "${e%%:*}" --arg isp "${e#*:}" \
            '{ip: $ip, isp: $isp, description: "Cloudflare", stateChanges: [{state: false}, {state: true}]}'
    done | jq -sc '{data: .}' > "${HDATA}/feed.json"
}
feed_raw() { printf '%s' "$1" > "${HDATA}/feed.json"; }
set_now() { echo "$1" > "${HDATA}/now"; }
# st <id> <nombre> [disabled_at_json] [dominio]: entrada del state
st() {
    jq -nc --arg id "$1" --arg name "$2" --argjson ts "${3:-1999990000}" --arg d "${4:-example.test}" \
        '{zone_id: "Z", domain: $d, record_id: $id, name: $name, type: "A", content: "203.0.113.20", disabled_at: $ts}'
}

# run_app [VAR=valor]...: ejecuta el script con entorno hermetico
run_app() {
    : > "${HDATA}/calls.log"
    : > "${HDATA}/telegram.log"
    : > "${HDATA}/dig.log"
    OUT="$(env -i PATH="${STUB_BIN}:${PATH}" HOME="${HOME:-/tmp}" TZ="${TZ:-UTC}" HDATA="$HDATA" \
        DOMAINS="Z:example.test" CLOUDFLARE_API_TOKEN=FAKE TELEGRAM_BOT_TOKEN=FAKE TELEGRAM_CHAT_ID=1 \
        DRY_RUN=false MIN_CLEAR_MINUTES=15 MAX_DISABLED_HOURS=12 \
        "$@" "$TEST_BASH" "${APP}/toggle-proxy.sh" 2>&1)"
    RC=$?
    # El log del fichero incluye lo que el script manda a /dev/null por stdout
    if [[ -f "$LOG" ]]; then
        OUT="${OUT}"$'\n'"$(cat "$LOG")"
        [[ -n "${KEEP_LOG:-}" ]] || : > "$LOG"
    fi
    printf '%s\nexit=%s\n' "$OUT" "$RC" >> "${CASE_DIR}/runs.log"
}

patches() { grep -c "^PATCH [^ ]*/dns_records/$1 " "${HDATA}/calls.log"; }
patch_bodies() { grep "^PATCH " "${HDATA}/calls.log" | cut -d' ' -f3-; }
api_calls() { grep -c "api.cloudflare.com" "${HDATA}/calls.log"; }
proxied_of() { jq -r --arg id "$1" '.[] | select(.id == $id) | .proxied' "${HDATA}/records.json"; }
name_of() { jq -r --arg id "$1" '.[] | select(.id == $id) | .name' "${HDATA}/records.json"; }
tg_texts() { jq -r '.text' "${HDATA}/telegram.log" 2>/dev/null; }
tg_count() { grep -c . "${HDATA}/telegram.log"; }
state_ids() { jq -r '[.[].record_id] | sort | join(",")' "$STATE" 2>/dev/null; }
out_has() { grep -q -- "$1" <<< "$OUT"; }

# ok <descripcion> <condicion evaluada con eval>
ok() {
    if eval "$2"; then
        echo "PASS  ${CASE}: $1"
        pass=$((pass + 1))
    else
        echo "FAIL  ${CASE}: $1"
        echo "      condicion: $2 (exit=$RC; log en ${CASE_DIR}/runs.log)"
        printf '%s\n' "$OUT" | tail -15 | sed 's/^/      | /'
        fail=$((fail + 1))
    fi
}

# --- T1: registros read-only y errores de la API ------------------------------

t_readonly_and_api_errors() {
    setup readonly-and-api-errors
    records "[$(rec r1 example.test true),$(rec r2 www.example.test true),$(rec r3 media.example.test true AAAA 100:: '{"read_only":true}')]"
    echo r2 > "${HDATA}/fail_ids"
    feed 104.21.13.229:Vodafone
    run_app
    ok "registro read-only nunca recibe PATCH" '[[ $(patches r3) == 0 ]]'
    ok "PATCH de r1" '[[ $(patches r1) == 1 && $(proxied_of r1) == false ]]'
    ok "error 400 de Cloudflare se registra con su detalle" 'out_has "HTTP 400.*1043"'
    ok "solo r1 en el state" '[[ $(state_ids) == r1 ]]'
}

# --- T2: Telegram acotado y con errores registrados ---------------------------

t_telegram_rejected_and_bounded() {
    setup telegram-rejected-and-bounded
    echo '{"ok":false,"error_code":400,"description":"Bad Request: message is too long"}' > "${HDATA}/tg_response.json"
    local args=() i
    for i in $(seq 1 150); do args+=("104.21.13.$((i % 250)):ISP<$i>→🙂"); done
    feed "${args[@]}"
    run_app
    ok "ERROR con la description de Telegram" 'out_has "ERROR.*message is too long"'
    ok "exit 0" '[[ $RC == 0 ]]'
    ok "texto <= 4096 caracteres" '[[ $(tg_texts | jq -Rs length) -le 4096 ]]'
    ok "motivo resumido con +N mas" 'tg_texts | grep -q "+[0-9]* mas"'
    ok "HTML del feed escapado" 'tg_texts | grep -q "ISP&lt;1&gt;"'
}

# --- T3: alerta solo de lo nuevo ----------------------------------------------

t_alert_only_new_disables() {
    setup alert-only-new
    feed 104.21.13.229:Vodafone
    run_app
    ok "primera ejecucion alerta DESHABILITADO" 'tg_texts | grep -q DESHABILITADO'
    run_app
    ok "bloqueo que sigue no repite la alerta" '[[ $(tg_count) == 0 ]]'
    ok "no se repite el PATCH" '[[ $(patches r1) == 0 ]]'
}

# --- T4: histeresis MIN_CLEAR_MINUTES -----------------------------------------

t_hysteresis() {
    setup hysteresis
    records "[$(rec r1 example.test false)]"
    printf '[%s]\n' "$(st r1 example.test)" > "$STATE"
    echo '{"example.test":["104.21.13.225"]}' > "$IPS"
    run_app DRY_RUN=true
    ok "DRY_RUN no escribe la marca de libre" '[[ ! -f $CLEAR ]] && out_has "Se empezaria a contar"'
    run_app
    ok "primera vez libre no restaura" '[[ $(patches r1) == 0 ]]'
    ok "guarda la marca de libre" '[[ $(jq -r ".[\"example.test\"]" "$CLEAR") == 2000000000 ]]'
    set_now 2000000600
    feed 104.21.13.229:Vodafone
    run_app
    ok "nuevo bloqueo reinicia la marca" '[[ $(jq -r ".[\"example.test\"] // \"none\"" "$CLEAR") == none ]]'
    feed
    run_app
    set_now 2000001500
    run_app
    ok "a los 15 min de libre restaura" '[[ $(patches r1) == 1 && $(proxied_of r1) == true ]]'
    ok "alerta REHABILITADO" 'tg_texts | grep -q REHABILITADO'
    ok "borra state, ips y clear" '[[ ! -f $STATE && ! -f $IPS && ! -f $CLEAR ]]'
}

t_hysteresis_zero_restores_now() {
    setup hysteresis-zero
    records "[$(rec r1 example.test false)]"
    printf '[%s]\n' "$(st r1 example.test)" > "$STATE"
    echo '{"example.test":["104.21.13.225"]}' > "$IPS"
    run_app MIN_CLEAR_MINUTES=0
    ok "MIN_CLEAR_MINUTES=0 restaura en la primera ejecucion libre" '[[ $(patches r1) == 1 && $(proxied_of r1) == true ]]'
}

# --- Ejecutar -----------------------------------------------------------------

for t in $(declare -F | awk '{print $3}' | grep '^t_'); do
    [[ -n "$PATTERN" && "$t" != *"$PATTERN"* ]] && continue
    "$t"
done

echo
echo "Integracion ($TEST_BASH): $pass ok, $fail fallos"
[[ "$fail" -eq 0 ]]
