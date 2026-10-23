#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/xcode.sh
source "${SCRIPT_DIR}/lib/xcode.sh"

# SwiftPM validates source/dependency changes on every invocation. Keep its build
# state across runs, and serialize users of these paths instead of rebuilding all
# seven packages in timestamped directories on every local gate.
if [[ "${1:-}" != --locked ]]; then
  [[ $# -eq 0 ]] || { echo "usage: test-swift-packages.sh" >&2; exit 64; }
  exec python3 "${SCRIPT_DIR}/lib/native-lock.py" "${CI_OUTPUT_ROOT}/locks/swift-packages.lock" -- \
    bash "${BASH_SOURCE[0]}" --locked
fi
[[ $# -eq 1 ]] || exit 64

require_xcode
RUN_DIR="$(new_run_dir swift-packages)"
BUILD_ROOT="${CI_OUTPUT_ROOT}/swift-package-builds"
PACKAGES=(
  AppearanceKit
  CandidateKit
  KeyboardCore
  LayoutKit
  PackageManager
  QuickContentKit
  SkinKit
)

for package in "${PACKAGES[@]}"; do
  printf '\n[CI] swift test: %s\n' "${package}"
  # Reviewed external dependencies are pinned. Reuse those exact revisions from
  # cache instead of refreshing remote refs on every isolated test build.
  TEST_OPTIONS=(--jobs "${SWIFT_TEST_JOBS:-4}" --cache-path "${CI_ROOT}/.local/swiftpm-cache")
  if [[ "${CI_SWIFTPM_DISABLE_SANDBOX:-0}" == 1 ]]; then
    TEST_OPTIONS+=(--disable-sandbox)
  fi
  if [[ -f "${CI_ROOT}/Packages/${package}/Package.resolved" ]]; then
    TEST_OPTIONS+=(--force-resolved-versions)
  fi
  started=${SECONDS}
  swift test \
    --package-path "${CI_ROOT}/Packages/${package}" \
    --scratch-path "${BUILD_ROOT}/${package}" \
    "${TEST_OPTIONS[@]}" 2>&1 | tee "${RUN_DIR}/${package}.log"
  printf '[CI] %s tests completed in %ss\n' "${package}" "$((SECONDS - started))"
done

printf '\n[CI] Swift package logs: %s\n[CI] Swift package build cache: %s\n' "${RUN_DIR}" "${BUILD_ROOT}"
