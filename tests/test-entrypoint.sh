#!/usr/bin/env bash
# Tests de entrypoint.sh: senales TERM/INT, espera al hijo, sleep
# interrumpible y CHECK_INTERVAL. Uso: bash tests/test-entrypoint.sh
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_BASH="${TEST_BASH:-bash}"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/toggle-ep.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

# Control de trabajos: sin el, un "&" de un bash no interactivo arranca el
# entrypoint con INT ignorado y no se podria probar INT (en Docker es PID 1)
set -m

pass=0
fail=0
check() {
    if [[ "$2" == "$3" ]]; then
        echo "PASS  $1"
        pass=$((pass + 1))
    else
        echo "FAIL  $1"
        echo "      esperado: '$2'"
        echo "      obtenido: '$3'"
        fail=$((fail + 1))
    fi
}

# wait_for <segundos> <condicion>: espera activa corta
wait_for() {
    local limit=$(( $1 * 10 )) i
    for (( i = 0; i < limit; i++ )); do
        eval "$2" && return 0
        sleep 0.1
    done
    return 1
}

# start_entrypoint <caso> <cuerpo del toggle-proxy falso> [VAR=valor]...
start_entrypoint() {
    D="${TMP_ROOT}/$1"
    local body="$2"
    shift 2
    mkdir -p "${D}/app/lib"
    cp "${ROOT_DIR}/entrypoint.sh" "${D}/app/"
    cp "${ROOT_DIR}"/lib/*.sh "${D}/app/lib/"
    printf '#!/usr/bin/env bash\nD=%q\n%s\n' "$D" "$body" > "${D}/app/toggle-proxy.sh"
    chmod +x "${D}/app/toggle-proxy.sh"
    env HEARTBEAT_FILE="${D}/heartbeat" CHECK_INTERVAL=30 "$@" \
        "$TEST_BASH" "${D}/app/entrypoint.sh" > "${D}/out.log" 2>&1 &
    EP_PID=$!
}

# stop_entrypoint <senal>: envia la senal y mide cuanto tarda en salir
stop_entrypoint() {
    local start end
    start="$(date +%s)"
    kill -"$1" "$EP_PID"
    wait "$EP_PID"
    EP_RC=$?
    end="$(date +%s)"
    EP_SECS=$(( end - start ))
}

# --- TERM durante una ejecucion: se reenvia y se espera al hijo ---
start_entrypoint during-run '
trap "echo term >> \"\$D/child.log\"; sleep 1; echo done >> \"\$D/child.log\"; exit 143" TERM
echo start >> "$D/child.log"
sleep 20 & wait'
wait_for 5 '[[ -f "${D}/child.log" ]]'
stop_entrypoint TERM
check "TERM en ejecucion: exit 0" "0" "$EP_RC"
check "TERM en ejecucion: el hijo recibe TERM" "yes" "$(grep -q term "${D}/child.log" && echo yes || echo no)"
check "TERM en ejecucion: espera a que el hijo termine" "yes" "$(grep -q "done" "${D}/child.log" && echo yes || echo no)"
check "TERM en ejecucion: sale enseguida (< 5 s)" "yes" "$([[ "$EP_SECS" -lt 5 ]] && echo yes || echo no)"
check "latido escrito" "yes" "$([[ -f "${D}/heartbeat" ]] && echo yes || echo no)"

# --- TERM durante el sleep: interrumpible ---
start_entrypoint during-sleep 'echo ran >> "$D/child.log"'
wait_for 5 '[[ -f "${D}/child.log" ]]'
sleep 0.5
stop_entrypoint TERM
check "TERM en el sleep: exit 0" "0" "$EP_RC"
check "TERM en el sleep: no espera CHECK_INTERVAL (< 5 s)" "yes" "$([[ "$EP_SECS" -lt 5 ]] && echo yes || echo no)"

# --- INT tambien ---
start_entrypoint int 'echo ran >> "$D/child.log"'
wait_for 5 '[[ -f "${D}/child.log" ]]'
sleep 0.5
stop_entrypoint INT
check "INT: exit 0 enseguida" "0 yes" "$EP_RC $([[ "$EP_SECS" -lt 5 ]] && echo yes || echo no)"

# --- CHECK_INTERVAL base 10 con limites ---
start_entrypoint interval-060 'echo ran >> "$D/child.log"' CHECK_INTERVAL=060
wait_for 5 '[[ -f "${D}/child.log" ]]'
stop_entrypoint TERM
check "CHECK_INTERVAL=060 son 60 s" "yes" "$(grep -q 'Interval:  60s' "${D}/out.log" && echo yes || echo no)"
start_entrypoint interval-bad 'echo ran >> "$D/child.log"' CHECK_INTERVAL=abc
wait_for 5 '[[ -f "${D}/child.log" ]]'
stop_entrypoint TERM
check "CHECK_INTERVAL invalido usa 300" "yes" "$(grep -q 'Interval:  300s' "${D}/out.log" && echo yes || echo no)"

echo
echo "Entrypoint ($TEST_BASH): $pass ok, $fail fallos"
[[ "$fail" -eq 0 ]]
