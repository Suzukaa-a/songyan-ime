#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/xcode.sh
source "${SCRIPT_DIR}/lib/xcode.sh"

python3 "${SCRIPT_DIR}/lib/native-lock.py" "${CI_OUTPUT_ROOT}/locks/native-engine.lock" -- \
  bash "${CI_ROOT}/Tools/BuildRimeIOS/scripts/36-grammar-window-harness.sh"

require_xcode
RIMEKIT="${CI_ROOT}/Packages/RimeBridge/Vendored/RimeKit.xcframework"
[[ -d "${RIMEKIT}" ]] || {
  echo "Reviewed RimeKit is required for extended tests: ${RIMEKIT}" >&2
  exit 1
}

RUN_DIR="$(new_run_dir native-harnesses)"
LOCK_FILE="${CI_OUTPUT_ROOT}/locks/native-engine.lock"
SCRIPTS=(
  32-bridge-contracts-harness.sh
  34-t9-letter-lock-harness.sh
  25-ambiguity-harness.sh
)

for harness in "${SCRIPTS[@]}"; do
  printf '\n[CI] native harness: %s\n' "${harness}"
  if ! python3 "${SCRIPT_DIR}/lib/native-lock.py" "${LOCK_FILE}" -- \
    bash "${CI_ROOT}/Tools/BuildRimeIOS/scripts/${harness}" \
    >"${RUN_DIR}/${harness%.sh}.log" 2>&1; then
    printf '[CI] native harness failed: %s\n' "${harness}" >&2
    tail -80 "${RUN_DIR}/${harness%.sh}.log" >&2
    exit 1
  fi
done

printf '\n[CI] Native harness logs: %s\n' "${RUN_DIR}"
