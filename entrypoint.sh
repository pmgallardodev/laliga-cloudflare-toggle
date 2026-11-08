#!/usr/bin/env bash
# Entrypoint Docker: ejecuta toggle-proxy.sh cada CHECK_INTERVAL segundos.
# Es PID 1: sin trap, bash ignora TERM y "docker stop" acaba en SIGKILL en
# mitad de un cambio. Con TERM/INT reenvia la senal a la ejecucion en curso,
# espera a que termine y sale con 0. El sleep es interrumpible.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ip-match.sh
source "${SCRIPT_DIR}/lib/ip-match.sh"

TOGGLE_SCRIPT="${SCRIPT_DIR}/toggle-proxy.sh"
HEARTBEAT_FILE="${HEARTBEAT_FILE:-/tmp/heartbeat}"

# Base 10 con limites: "08" son 8 s, no un octal invalido
if ! INTERVAL="$(parse_uint "${CHECK_INTERVAL:-300}" 10 86400)"; then
    echo "WARN: CHECK_INTERVAL='${CHECK_INTERVAL:-}' no es un numero de segundos (10-86400). Usando 300."
    INTERVAL=300
fi

echo "========================================"
echo " laliga-cloudflare-toggle"
echo "========================================"
echo " Interval:  ${INTERVAL}s"
echo " Domains:   $(echo "${DOMAINS:-none}" | tr ',' '\n' | cut -d: -f2 | tr '\n' ' ')"
echo " DRY_RUN:   ${DRY_RUN:-false}"
echo " Telegram:  $([ -n "${TELEGRAM_BOT_TOKEN:-}" ] && echo "on" || echo "off")"
echo " Timeout:   ${MAX_DISABLED_HOURS:-12}h"
echo "========================================"

child=0
in_run=false

on_signal() {
    local sig="$1"
    trap '' TERM INT
    if [[ "$child" -gt 0 ]] && kill -0 "$child" 2>/dev/null; then
        if [[ "$in_run" == "true" ]]; then
            echo "Senal $sig: esperando a que termine la ejecucion en curso..."
        fi
        # Siempre TERM: los procesos en segundo plano de un bash no
        # interactivo ignoran INT
        kill -TERM "$child" 2>/dev/null || true
        wait "$child" 2>/dev/null || true
    fi
    echo "Senal $sig: saliendo."
    exit 0
}
trap 'on_signal TERM' TERM
trap 'on_signal INT' INT

while true; do
    # Latido para el HEALTHCHECK: si el bucle se cuelga deja de tocarse
    touch "$HEARTBEAT_FILE"
    # En segundo plano + wait: el trap se atiende en cuanto llega la senal
    in_run=true
    "$TOGGLE_SCRIPT" &
    child=$!
    wait "$child" || true
    in_run=false
    sleep "$INTERVAL" &
    child=$!
    wait "$child" || true
    child=0
done
