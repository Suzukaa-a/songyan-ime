#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 06-verify-macos.sh — verify the macOS deployment target actually reached the
# produced artifacts.
#
# Checks the Mach-O minimum OS of:
#   * ${ENGINE_BIN}/rime_cli            (final link flags)
#   * one object member of every static library in ${ENGINE_PREFIX}/lib
#     (compiled with the exported MACOSX_DEPLOYMENT_TARGET)
# and requires each to equal MACOSX_DEPLOYMENT_TARGET (default 13.0).
#
# Safety: read-only; object members are extracted with `ar -p` into a
# fresh, never-before-used directory under ${ENGINE_RUNS}; nothing is deleted.
# ---------------------------------------------------------------------------
set -uo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

RIME_CLI="${ENGINE_BIN}/rime_cli"
[[ -x "${RIME_CLI}" ]] || die "rime_cli missing; run scripts/01..04 first"
command -v vtool >/dev/null 2>&1 || die "vtool not found (need CommandLineTools)"

echo "expected minimum OS: ${MACOSX_DEPLOYMENT_TARGET}"
pass=0; fail=0

verify_macho() { # $1 label, $2 mach-o path
  local minos
  minos="$(vtool -show-build "$2" 2>/dev/null | awk '/^[[:space:]]*minos[[:space:]]/{print $2; exit}')"
  if [[ "${minos}" == "${MACOSX_DEPLOYMENT_TARGET}" ]]; then
    echo "PASS: ${1} minos=${minos}"
    pass=$((pass+1))
  else
    echo "FAIL: ${1} minos=${minos:-<none>} != ${MACOSX_DEPLOYMENT_TARGET}"
    fail=$((fail+1))
  fi
}

verify_macho "rime_cli" "${RIME_CLI}"

for lib in "${ENGINE_PREFIX}"/lib/*.a; do
  [[ -f "${lib}" ]] || continue
  name="$(basename "${lib}")"
  member="$(ar -t "${lib}" | grep -v '^__.SYMDEF' | head -1)"
  [[ -n "${member}" ]] || { echo "FAIL: ${name} has no members"; fail=$((fail+1)); continue; }
  tmp="$(new_isolated_dir "${ENGINE_RUNS}/minos-${name}")"
  (cd "${tmp}" && ar -p "${lib}" "${member}" > "${member}.o")
  verify_macho "${name} (member ${member})" "${tmp}/${member}.o"
done

echo
echo "== results: pass=${pass} fail=${fail} =="
[[ "${fail}" -eq 0 ]] || die "deployment target verification failed"
