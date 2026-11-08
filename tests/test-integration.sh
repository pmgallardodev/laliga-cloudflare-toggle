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

# --- T6: validacion del feed ---------------------------------------------------

# Registro gris en state desde hace mas de 12h (timeout vencido) o reciente
overdue_state() {
    records "[$(rec r1 example.test false)]"
    printf '[%s]\n' "$(st r1 example.test "${1:-1999900000}")" > "$STATE"
    echo '{"example.test":["104.21.13.225"]}' > "$IPS"
}

t_feed_invalid_shapes_use_timeout() {
    local name payload
    for name in error-object data-null data-string changes-object empty-body not-json; do
        case "$name" in
            error-object) payload='{"error":"maintenance"}' ;;
            data-null) payload='{"data":null}' ;;
            data-string) payload='{"data":"unavailable"}' ;;
            changes-object) payload='{"data":[{"ip":"104.21.13.229","isp":"X","description":"Cloudflare","stateChanges":{"state":true}}]}' ;;
            empty-body) payload='' ;;
            not-json) payload='<html>502</html>' ;;
        esac
        setup "feed-$name"
        overdue_state
        feed_raw "$payload"
        run_app
        ok "feed invalido no aborta (exit 0)" '[[ $RC == 0 ]]'
        ok "feed invalido se trata como caido" 'out_has "No se pudo obtener datos"'
        ok "timeout vencido restaura" '[[ $(patches r1) == 1 && $(proxied_of r1) == true ]]'
    done
}

t_feed_empty_body_does_not_restore_early() {
    setup feed-empty-recent
    overdue_state 1999990000
    echo '{"example.test":1999998000}' > "$CLEAR"
    feed_raw ''
    run_app
    ok "cuerpo vacio no cuenta como libre" '[[ $(patches r1) == 0 && $(state_ids) == r1 ]]'
}

t_feed_http_error_is_unavailable() {
    setup feed-http-500
    overdue_state 1999990000
    feed
    echo 500 > "${HDATA}/feed_code"
    run_app
    ok "HTTP 500 cuenta como feed caido" 'out_has "No se pudo obtener datos" && [[ $(patches r1) == 0 ]]'
}

t_feed_null_description() {
    setup feed-null-description
    overdue_state
    feed_raw '{"data":[{"ip":"104.21.13.229","isp":"ISP","description":null,"stateChanges":[{"state":true}]}]}'
    run_app
    ok "description null no aborta" '[[ $RC == 0 ]] && out_has "1 entrada(s) con bloqueo activo"'
    ok "sigue bloqueado: no restaura" '[[ $(patches r1) == 0 ]]'
    rm -f "$IPS"
    run_app
    ok "check amplio (sin IPs guardadas) con description null" '[[ $RC == 0 ]] && out_has "No hay bloqueos de Cloudflare activos"'
}

# --- T7: CIDR exacto ------------------------------------------------------------

t_cidr_origin_not_cloudflare() {
    setup cidr-origin-not-cloudflare
    records "[$(rec r1 example.test false A 108.162.1.2),$(rec r2 www.example.test true)]"
    dns example.test A 108.162.1.2
    feed 108.162.1.9:ISP
    run_app
    ok "IP fuera de 108.162.192.0/18 no es candidata: nada se toca" '[[ $(patches r2) == 0 ]]'
}

# --- T8: numeros base 10 con limites --------------------------------------------

t_numeric_minutes_08() {
    setup minutes-08
    overdue_state 1999990000
    feed
    run_app MIN_CLEAR_MINUTES=08
    ok "MIN_CLEAR_MINUTES=08 no aborta" '[[ $RC == 0 ]] && ! out_has "value too great" && out_has "Libre desde hace"'
    ok "guarda la marca de libre" '[[ $(jq -r ".[\"example.test\"]" "$CLEAR") == 2000000000 ]]'
    set_now 2000000479
    run_app MIN_CLEAR_MINUTES=08
    ok "a los 7m59s no restaura" '[[ $(patches r1) == 0 ]]'
    set_now 2000000480
    run_app MIN_CLEAR_MINUTES=08
    ok "a los 8 minutos restaura" '[[ $(patches r1) == 1 ]]'
}

t_numeric_max_hours() {
    setup max-hours-012
    overdue_state 1999956800   # hace 43200 s = 12 h
    feed_raw 'down'
    run_app MAX_DISABLED_HOURS=012
    ok "MAX_DISABLED_HOURS=012 son 12 h: restaura" '[[ $RC == 0 && $(patches r1) == 1 ]]'
    setup max-hours-invalid
    overdue_state 1999956801
    feed_raw 'down'
    run_app MAX_DISABLED_HOURS=abc
    ok "MAX_DISABLED_HOURS invalido avisa y usa 12" 'out_has "MAX_DISABLED_HOURS" && [[ $RC == 0 && $(patches r1) == 0 ]]'
}

t_numeric_defaults_when_unset() {
    setup defaults-unset
    overdue_state
    feed_raw 'down'
    OUT="$(cd "$APP" && env -i PATH="${STUB_BIN}:${PATH}" HDATA="$HDATA" DOMAINS=Z:example.test \
        CLOUDFLARE_API_TOKEN=FAKE "$TEST_BASH" ./toggle-proxy.sh 2>&1)"
    RC=$?
    ok "sin MAX_DISABLED_HOURS ni MIN_CLEAR_MINUTES usa los defaults" '[[ $RC == 0 ]] && out_has "Superado limite de 12h"'
}

# --- T9: marcas de tiempo ISO legacy ---------------------------------------------

t_legacy_iso_timestamp_utc() {
    local tz
    for tz in UTC Europe/Madrid; do
        setup "legacy-iso-${tz//\//-}"
        overdue_state '"2026-11-07T12:00:00Z"'
        feed_raw 'down'
        set_now 1794094200   # 11.5 h despues
        TZ="$tz" run_app
        ok "TZ=$tz: a las 11.5 h no restaura" '[[ $RC == 0 && $(patches r1) == 0 ]]'
        set_now 1794096000   # 12 h despues
        TZ="$tz" run_app
        ok "TZ=$tz: a las 12 h restaura" '[[ $(patches r1) == 1 ]]'
    done
}

t_unparseable_timestamp_expires() {
    setup unparseable-timestamp
    overdue_state '"ayer por la tarde"'
    feed_raw 'down'
    run_app
    ok "disabled_at ilegible: ERROR y se da por vencido" 'out_has "ERROR.*disabled_at" && [[ $(patches r1) == 1 ]]'
}

t_timeout_uses_oldest_entry() {
    setup timeout-oldest
    records "[$(rec r1 example.test false),$(rec r2 www.example.test false)]"
    printf '[%s,%s]\n' "$(st r1 example.test 1999990000)" "$(st r2 www.example.test 1999900000)" > "$STATE"
    echo '{"example.test":["104.21.13.225"]}' > "$IPS"
    feed_raw 'down'
    run_app
    ok "el timeout cuenta desde la entrada mas antigua" '[[ $(patches r1) == 1 && $(patches r2) == 1 ]]'
}

# --- T10: nombres canonicos ----------------------------------------------------------

t_names_protected_case_insensitive() {
    setup protected-case
    feed 104.21.13.229:ISP
    run_app PROTECTED_DOMAINS="EXAMPLE.TEST."
    ok "PROTECTED_DOMAINS ignora mayusculas y punto final" '[[ $(patches r1) == 0 ]] && out_has PROTEGIDO'
}

t_names_domains_and_records_canonical() {
    setup names-canonical
    records "[$(rec r1 example.test true),$(rec r2 WWW.Example.Test. true)]"
    feed 104.21.13.229:ISP
    run_app DOMAINS="Z:Example.TEST."
    ok "DOMAINS y nombres de registro sin distinguir mayusculas" '[[ $(patches r1) == 1 && $(patches r2) == 1 ]]'
    ok "state con dominio y nombres canonicos" '[[ $(jq -r "[.[] | .domain, .name] | unique | join(\",\")" "$STATE") == example.test,www.example.test ]]'
    ok "IPs guardadas con clave canonica" '[[ $(jq -r "keys | join(\",\")" "$IPS") == example.test ]]'
}

t_names_legacy_state_mixed_case() {
    setup names-legacy-case
    records "[$(rec r1 example.test false)]"
    printf '[%s]\n' "$(st r1 Example.Test 1999990000 EXAMPLE.test)" > "$STATE"
    echo '{"Example.Test.":["104.21.13.225"]}' > "$IPS"
    run_app MIN_CLEAR_MINUTES=0
    ok "state e IPs legacy con mayusculas se reconocen" 'out_has "Usando IPs de Cloudflare guardadas" && [[ $(patches r1) == 1 ]]'
}

# --- T11: el PATCH solo cambia proxied -------------------------------------------------

t_patch_body_only_proxied() {
    setup patch-body
    feed 104.21.13.229:ISP
    run_app
    ok "PATCH de deshabilitar solo lleva proxied" '[[ "$(patch_bodies)" == "{\"proxied\":false}" ]]'
    setup rename-not-reverted
    records "[$(rec r1 new.example.test false)]"
    printf '[%s]\n' "$(st r1 old.example.test)" > "$STATE"
    echo '{"example.test":["104.21.13.225"]}' > "$IPS"
    run_app MIN_CLEAR_MINUTES=0
    ok "PATCH de restaurar solo lleva proxied" '[[ "$(patch_bodies)" == "{\"proxied\":true}" ]]'
    ok "un registro renombrado conserva su nombre nuevo" '[[ $(name_of r1) == new.example.test && $(proxied_of r1) == true ]]'
}

# --- T12: intencion escrita antes del PATCH -------------------------------------------

state_status() { jq -r --arg id "$1" '.[] | select(.record_id == $id) | .status // "legacy"' "$STATE" 2>/dev/null; }
pending_state() { # pending_state <id> <nombre>
    printf '[%s]\n' "$(st "$1" "$2" | jq -c '.status = "pending"')" > "$STATE"
    echo '{"example.test":["104.21.13.225"]}' > "$IPS"
}

t_writeahead_ambiguous_patch() {
    setup ambiguous-patch
    feed 104.21.13.229:ISP
    touch "${HDATA}/patch_ambiguous"
    run_app
    ok "PATCH incierto (curl 28) no aborta" '[[ $RC == 0 ]]'
    ok "el registro quedo gris en Cloudflare" '[[ $(proxied_of r1) == false ]]'
    ok "la intencion queda en el state como pending" '[[ $(state_status r1) == pending ]]'
    rm -f "${HDATA}/patch_ambiguous"
    run_app
    ok "siguiente ejecucion confirma por GET sin repetir el PATCH" '[[ $(patches r1) == 0 && $(state_status r1) == disabled ]]'
    ok "y alerta del registro confirmado" 'tg_texts | grep -q "DESHABILITADO" && tg_texts | grep -q "A example.test"'
    feed
    run_app MIN_CLEAR_MINUTES=0
    ok "cuando queda libre lo restaura" '[[ $(proxied_of r1) == true && ! -f $STATE ]]'
}

t_writeahead_pending_proxied_clear_dropped() {
    setup pending-proxied-clear
    pending_state r1 example.test
    run_app
    ok "pending con proxy activo y libre: se descarta sin PATCH" '[[ $(patches r1) == 0 && ! -f $STATE ]]'
}

t_writeahead_pending_proxied_blocked_retried() {
    setup pending-proxied-blocked
    pending_state r1 example.test
    feed 104.21.13.229:ISP
    run_app
    ok "pending con proxy activo y bloqueado: se reintenta" '[[ $(patches r1) == 1 && $(state_status r1) == disabled ]]'
    ok "alerta del reintento" 'tg_texts | grep -q DESHABILITADO'
}

t_writeahead_pending_missing_record() {
    setup pending-missing
    pending_state r9 gone.example.test
    feed 104.21.13.229:ISP
    run_app
    ok "pending de un registro borrado (404) se descarta" '[[ $(state_ids) == r1 ]] && out_has "ya no existe"'
}

t_writeahead_log_failure_keeps_state() {
    setup log-failure
    mkdir -p "${APP}/logs"
    : > "$LOG"
    chmod 444 "$LOG"
    feed 104.21.13.229:ISP
    run_app
    chmod 644 "$LOG"
    ok "un log que no se puede escribir no aborta" '[[ $RC == 0 ]]'
    ok "el state se guarda igualmente" '[[ $(state_status r1) == disabled && $(proxied_of r1) == false ]]'
    ok "y la alerta sale" 'tg_texts | grep -q DESHABILITADO'
}

# --- T13: ficheros corruptos --------------------------------------------------------

t_corrupt_state_quarantined() {
    setup corrupt-state
    records "[$(rec r1 example.test false)]"
    dns example.test A 203.0.113.20
    printf '{garbage' > "$STATE"
    echo '{"example.test":["104.21.13.225"]}' > "$IPS"
    echo '{"example.test":1999990000}' > "$CLEAR"
    run_app
    ok "exit 0" '[[ $RC == 0 ]]'
    ok "state movido a .corrupt-<epoch> con su contenido" '[[ $(cat "${STATE}.corrupt-2000000000" 2>/dev/null) == "{garbage" && ! -f $STATE ]]'
    ok "ERROR en el log" 'out_has "ERROR.*corrupto"'
    ok "no borra IPs ni marcas de libre" '[[ -f $IPS && -f $CLEAR ]]'
    ok "alerta con el fichero y los dominios a revisar" 'tg_texts | grep -q "corrupt" && tg_texts | grep -q "example.test"'
    run_app
    ok "siguientes ejecuciones tampoco borran los ficheros de apoyo" '[[ -f $IPS && -f $CLEAR ]] && out_has "cuarentena"'
    ok "y no repiten la alerta" '[[ $(tg_count) == 0 ]]'
}

t_corrupt_state_feed_down_still_alerts() {
    setup corrupt-state-feed-down
    printf '{garbage' > "$STATE"
    feed_raw 'down'
    run_app
    ok "con el feed caido tambien alerta del state corrupto" '[[ $RC == 0 ]] && tg_texts | grep -q corrupt'
}

t_corrupt_state_wrong_type() {
    setup corrupt-state-type
    echo '{"record_id":"r1"}' > "$STATE"
    run_app
    ok "state con tipo incorrecto tambien va a cuarentena" '[[ -f "${STATE}.corrupt-2000000000" ]]'
}

t_corrupt_clear_keeps_restoring() {
    setup corrupt-clear
    overdue_state 1999990000
    printf 'not json' > "$CLEAR"
    feed
    run_app MIN_CLEAR_MINUTES=0
    ok "clear corrupto en cuarentena" '[[ -f "${CLEAR}.corrupt-2000000000" ]]'
    ok "el state parseable se sigue restaurando" '[[ $(patches r1) == 1 && $(proxied_of r1) == true ]]'
}

t_corrupt_ips_keeps_restoring() {
    setup corrupt-ips
    overdue_state 1999990000
    echo '{"example.test":"not-an-array"}' > "$IPS"
    feed
    run_app MIN_CLEAR_MINUTES=0
    ok "IPs con forma invalida en cuarentena, sin abortar" '[[ $RC == 0 && -f "${IPS}.corrupt-2000000000" ]]'
    ok "restaura con el check amplio" '[[ $(patches r1) == 1 ]]'
}

t_corrupt_state_dry_run_untouched() {
    setup corrupt-dry-run
    printf '{garbage' > "$STATE"
    run_app DRY_RUN=true
    ok "DRY_RUN no mueve el state corrupto" '[[ $(cat "$STATE") == "{garbage" ]] && out_has "ERROR.*corrupto"'
}

# --- T14: paginacion de dns_records ---------------------------------------------------

t_pagination_101_records() {
    setup pagination-101
    local i recs
    recs="$(rec r0 example.test true)"
    for i in $(seq 1 100); do recs="${recs},$(rec "r$i" "s$i.example.test" true)"; done
    records "[$recs]"
    feed 104.21.13.229:ISP
    run_app
    ok "pide la segunda pagina" 'grep -q "dns_records?per_page=100&page=2" "${HDATA}/calls.log"'
    ok "deshabilita los 101 registros" '[[ $(grep -c "^PATCH " "${HDATA}/calls.log") == 101 ]]'
    ok "ninguno queda con proxy" '[[ $(jq "[.[] | select(.proxied)] | length" "${HDATA}/records.json") == 0 ]]'
}

# --- T15: una caida del feed reinicia el contador de libre ------------------------------

t_outage_resets_clear_timer() {
    setup outage-resets-clear
    overdue_state 1999990000
    feed
    run_app
    ok "primera ejecucion libre guarda la marca" '[[ $(jq -r ".[\"example.test\"]" "$CLEAR") == 2000000000 ]]'
    set_now 2000000300
    feed_raw 'down'
    run_app
    ok "feed caido borra la marca de libre" '[[ $(jq -r ".[\"example.test\"] // \"none\"" "$CLEAR" 2>/dev/null || echo none) == none ]]'
    set_now 2000003600
    feed
    run_app
    ok "al volver el feed no restaura: el contador empieza de nuevo" '[[ $(patches r1) == 0 && $(jq -r ".[\"example.test\"]" "$CLEAR") == 2000003600 ]]'
    set_now 2000004500
    run_app
    ok "restaura tras MIN_CLEAR_MINUTES seguidos con feed sano" '[[ $(patches r1) == 1 ]]'
}

# --- T16: contabilidad de restauracion por registro ---------------------------------------

t_partial_restore_alerted() {
    setup partial-restore
    records "[$(rec r1 example.test false),$(rec r2 www.example.test false)]"
    printf '[%s,%s]\n' "$(st r1 example.test)" "$(st r2 www.example.test)" > "$STATE"
    echo '{"example.test":["104.21.13.225"]}' > "$IPS"
    echo r2 > "${HDATA}/fail_ids"
    run_app MIN_CLEAR_MINUTES=0
    ok "r1 restaurado y r2 sigue en el state" '[[ $(proxied_of r1) == true && $(state_ids) == r2 ]]'
    ok "alerta de la restauracion parcial" 'tg_texts | grep -q REHABILITADO && tg_texts | grep -q "A example.test" && tg_texts | grep -q "1 registro(s)"'
    ok "la alerta avisa de lo pendiente" 'tg_texts | grep -q "pendiente"'
    rm -f "${HDATA}/fail_ids"
    run_app MIN_CLEAR_MINUTES=0
    ok "el reintento alerta solo de r2" 'tg_texts | grep -q "A www.example.test" && ! tg_texts | grep -q "A example.test$"'
    ok "y limpia los ficheros" '[[ ! -f $STATE && ! -f $IPS ]]'
}

t_restore_missing_record_resolved() {
    setup restore-missing
    printf '[%s,%s]\n' "$(st r1 example.test)" "$(st r9 gone.example.test)" > "$STATE"
    records "[$(rec r1 example.test false)]"
    echo '{"example.test":["104.21.13.225"]}' > "$IPS"
    run_app MIN_CLEAR_MINUTES=0
    ok "un registro borrado (404) se da por resuelto" 'out_has "gone.example.test ya no existe" && [[ ! -f $STATE ]]'
    ok "el resto se restaura y se alerta" '[[ $(proxied_of r1) == true ]] && tg_texts | grep -q REHABILITADO'
}

# --- T17: candidatas desde subdominios con proxy ----------------------------------------

t_grey_apex_proxied_child() {
    setup grey-apex-proxied-child
    records "[$(rec r1 example.test false),$(rec r2 www.example.test true),$(rec r3 '*.example.test' true)]"
    dns example.test A 203.0.113.20
    dns www.example.test A 104.21.13.225
    feed 104.21.13.229:ISP
    run_app
    ok "apex gris: se resuelven los subdominios con proxy y se deshabilita www" '[[ $(patches r2) == 1 && $(proxied_of r2) == false ]]'
    ok "consultas acotadas por subdominio (<= 7)" '[[ $(grep -c " www.example.test " "${HDATA}/dig.log") -le 7 ]]'
    ok "la zona se lista una sola vez" '[[ $(grep -c "dns_records?per_page=100" "${HDATA}/calls.log") == 1 ]]'
    ok "el comodin no se resuelve" '! grep -q "\*.example.test" "${HDATA}/dig.log"'
}

t_child_candidates_bounded() {
    setup child-candidates-bounded
    local i recs
    recs="$(rec r0 example.test false)"
    for i in $(seq 1 15); do recs="${recs},$(rec "r$i" "h$i.example.test" true)"; dns "h$i.example.test" A 104.21.13.225; done
    records "[$recs]"
    dns example.test A 203.0.113.20
    run_app
    ok "15 subdominios: solo se resuelven 10, sin abortar" '[[ $RC == 0 && $(cut -d" " -f2 "${HDATA}/dig.log" | grep -c "^h") -le 70 && $(cut -d" " -f2 "${HDATA}/dig.log" | grep "^h" | sort -u | wc -l | xargs) == 10 ]]'
}

# --- T18: avisos de mitigacion parcial ----------------------------------------------------

t_partial_mitigation_cname_other_zone() {
    setup cname-other-zone
    records "[$(rec r1 example.test true CNAME origin.other.test),$(rec r2 www.example.test true CNAME example.test)]"
    feed 104.21.13.229:ISP
    run_app
    ok "CNAME fuera del dominio avisado en la alerta" 'tg_texts | grep -q "parcial" && tg_texts | grep -q "origin.other.test"'
    ok "CNAME dentro del dominio sin aviso" '! tg_texts | grep -q "www.example.test -&gt; example.test"'
    ok "aviso tambien en el log" 'out_has "WARN.*origin.other.test"'
}

t_partial_mitigation_read_only_same_name() {
    setup read-only-same-name
    records "[$(rec r1 example.test true),$(rec r2 example.test true AAAA 100:: '{"read_only":true}')]"
    feed 104.21.13.229:ISP
    run_app
    ok "registro read-only con proxy en el mismo nombre avisado" 'tg_texts | grep -q "parcial" && tg_texts | grep -q "AAAA example.test"'
}

t_no_partial_warning_when_complete() {
    setup no-partial-warning
    feed 104.21.13.229:ISP
    run_app
    ok "sin avisos si la mitigacion es completa" 'tg_texts | grep -q DESHABILITADO && ! tg_texts | grep -q "parcial"'
}

# --- T19: bandeja de salida de notificaciones -----------------------------------------

TG_429='{"ok":false,"error_code":429,"description":"Too Many Requests: retry after 1","parameters":{"retry_after":1}}'
outbox_len() { jq length "$OUTBOX" 2>/dev/null || echo 0; }

t_outbox_retries_after_429() {
    setup outbox-429
    feed 104.21.13.229:ISP
    echo "$TG_429" > "${HDATA}/tg_response.json"
    run_app
    ok "429 se registra y el mensaje va a la bandeja" 'out_has "ERROR.*Too Many Requests" && [[ $(outbox_len) == 1 ]]'
    rm -f "${HDATA}/tg_response.json"
    set_now 2000000005
    run_app
    ok "la siguiente ejecucion lo reenvia aunque no haya cambios" '[[ $(tg_count) == 1 ]] && tg_texts | grep -q DESHABILITADO'
    ok "y vacia la bandeja" '[[ $(outbox_len) == 0 ]]'
}

t_outbox_honours_retry_after() {
    setup outbox-retry-after
    feed 104.21.13.229:ISP
    echo '{"ok":false,"error_code":429,"description":"Too Many Requests","parameters":{"retry_after":600}}' > "${HDATA}/tg_response.json"
    run_app
    rm -f "${HDATA}/tg_response.json"
    set_now 2000000060
    run_app
    ok "no reintenta antes de retry_after" '[[ $(tg_count) == 0 && $(outbox_len) == 1 ]]'
    set_now 2000000600
    run_app
    ok "reintenta pasado retry_after" '[[ $(tg_count) == 1 && $(outbox_len) == 0 ]]'
}

t_outbox_deduplicates() {
    setup outbox-dedupe
    feed 104.21.13.229:ISP
    echo "${TG_429/\"retry_after\":1/\"retry_after\":0}" > "${HDATA}/tg_response.json"
    run_app
    # El mismo evento otra vez: registro con proxy y sin state
    records "[$(rec r1 example.test true)]"
    rm -f "$STATE"
    run_app
    ok "un mensaje identico no se duplica en la bandeja" '[[ $(outbox_len) == 1 ]]'
}

t_outbox_capped() {
    setup outbox-cap
    jq -n '[range(20) | {hash: "h\(.)", text: "viejo \(.)", created_at: 1, attempts: 1, next_at: 9999999999}]' > "$OUTBOX"
    feed 104.21.13.229:ISP
    echo "$TG_429" > "${HDATA}/tg_response.json"
    run_app
    ok "bandeja limitada a 20 descartando el mas antiguo" '[[ $(outbox_len) == 20 && $(jq -r ".[0].hash" "$OUTBOX") == h1 ]] && out_has "WARN.*Bandeja"'
}

t_outbox_drops_permanent_400() {
    setup outbox-400
    feed 104.21.13.229:ISP
    echo '{"ok":false,"error_code":400,"description":"Bad Request: chat not found"}' > "${HDATA}/tg_response.json"
    run_app
    ok "un 400 se registra y no va a la bandeja" 'out_has "ERROR.*chat not found" && [[ $(outbox_len) == 0 ]]'
    jq -n '[{hash: "x", text: "pendiente", created_at: 1, attempts: 1, next_at: 0}]' > "$OUTBOX"
    run_app
    ok "un 400 al reenviar descarta la entrada" '[[ $(outbox_len) == 0 ]] && out_has "descarta"'
}

t_outbox_dry_run_untouched() {
    setup outbox-dry-run
    jq -n '[{hash: "x", text: "pendiente", created_at: 1, attempts: 1, next_at: 0}]' > "$OUTBOX"
    run_app DRY_RUN=true
    ok "DRY_RUN no envia ni toca la bandeja" '[[ $(tg_count) == 0 && $(outbox_len) == 1 ]]'
}

# --- Ejecutar -----------------------------------------------------------------

for t in $(declare -F | awk '{print $3}' | grep '^t_'); do
    [[ -n "$PATTERN" && "$t" != *"$PATTERN"* ]] && continue
    "$t"
done

echo
echo "Integracion ($TEST_BASH): $pass ok, $fail fallos"
[[ "$fail" -eq 0 ]]
