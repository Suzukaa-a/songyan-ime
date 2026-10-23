#!/usr/bin/env bash
set -euo pipefail

CI_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CI_ROOT="$(cd "${CI_LIB_DIR}/../../../.." && pwd)"
CI_OUTPUT_ROOT="${CI_OUTPUT_ROOT:-${CI_ROOT}/.local/ci}"

new_run_dir() {
  local task="$1" stamp candidate suffix=0
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  candidate="${CI_OUTPUT_ROOT}/${task}/${stamp}.$$"
  while [[ -e "${candidate}" ]]; do
    suffix=$((suffix + 1))
    candidate="${CI_OUTPUT_ROOT}/${task}/${stamp}.$$.$suffix"
  done
  mkdir -p "${candidate}"
  printf '%s' "${candidate}"
}
