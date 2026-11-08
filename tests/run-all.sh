#!/usr/bin/env bash
# Ejecuta todos los tests con bash del PATH y, si existe, con /bin/bash (bash 3
# en macOS). Uso: bash tests/run-all.sh
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
shells=(bash)
if [[ -x /bin/bash ]] && [[ "$(/bin/bash -c 'echo $BASH_VERSION')" != "$(bash -c 'echo $BASH_VERSION')" ]]; then
    shells+=(/bin/bash)
fi

failed=()
for sh in "${shells[@]}"; do
    for t in "${ROOT_DIR}"/tests/test-*.sh; do
        echo "=== $(basename "$t") ($sh) ==="
        if TEST_BASH="$sh" "$sh" "$t" > "${TMPDIR:-/tmp}/run-all.$$.log" 2>&1; then
            tail -1 "${TMPDIR:-/tmp}/run-all.$$.log"
        else
            grep -E '^(FAIL|  )' "${TMPDIR:-/tmp}/run-all.$$.log" | head -40
            tail -1 "${TMPDIR:-/tmp}/run-all.$$.log"
            failed+=("$(basename "$t") ($sh)")
        fi
    done
done
rm -f "${TMPDIR:-/tmp}/run-all.$$.log"

echo
if [[ ${#failed[@]} -gt 0 ]]; then
    echo "FALLAN: ${failed[*]}"
    exit 1
fi
echo "Todos los tests pasan (${shells[*]})"
