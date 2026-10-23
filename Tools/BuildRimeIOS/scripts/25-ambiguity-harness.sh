#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 25-ambiguity-harness.sh — macOS production-path verification of the
# ambiguity-spelling bridge against the pinned librime.
#
# Builds the same bridge sources (rime_bridge.c + rime_spelling.cc) and the
# RimeBridge Swift wrapper used by the iOS keyboard, then runs
# ambiguity-main.swift over real generated schemas. It proves enumeration is
# read-only, that spelling locks apply and restore, and covers the built-in
# 9-key (72 / 986), built-in 14-key flypy (ug), rime-ice t9 (72) and 26-key
# isolation fixtures, plus stale/cap/no-composition semantics.
#
# It never renders UI or touches a device.
#
# Usage (defaults use the repo's built-in package; the rime-ice t9 profile runs only
# when AMBIG_ICE_SHARED and AMBIG_ICE_USER point at a deployed rime-ice t9 tree):
#   Tools/BuildRimeIOS/scripts/25-ambiguity-harness.sh
#
# Overrides:
#   AMBIG_BUILTIN_SHARED / AMBIG_BUILTIN_USER
#   AMBIG_ICE_SHARED / AMBIG_ICE_USER / AMBIG_ICE_PREBUILT
#   AMBIG_SKIP_BUILTIN=1 / AMBIG_SKIP_ICE=1
#
# C bridge OUTCOME contract section (harness-mac/ambiguity-outcome-main.c):
# drives the exported C API directly and pins the invalid/no-session early-outs
# of rb_apply_ambiguity_spelling / rb_restore_ambiguity_spelling so they can
# never claim RB_AMBIG_FAILED's "the write was attempted and the rollback was
# RE-READ byte-equal" promise. Overrides:
#   AMBIG_SKIP_OUTCOME=1       skip the outcome contract section entirely
#   AMBIG_OUTCOME_ONLY=1       run ONLY that section, then exit
#   AMBIG_OUTCOME_STUB=current|fixed  run the harness against a stub service
#                              (no engine/cmake); proves the assertion is
#                              load-bearing and satisfiable
#   AMBIG_OUTCOME_SHARED / AMBIG_OUTCOME_USER
#
# Safety: nothing is deleted; all outputs go to a fresh isolated run dir.
# ---------------------------------------------------------------------------
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_IOS_TOOLS_DIR="$(cd "${_SCRIPT_DIR}/.." && pwd)"
_PROJECT_ROOT="$(cd "${_IOS_TOOLS_DIR}/../.." && pwd)"

# Refuse a self-contradictory request up front, before the engine/cmake probes,
# so the misuse is reported as such rather than as a missing-prerequisite error.
if [[ "${AMBIG_OUTCOME_ONLY:-0}" == "1" && "${AMBIG_SKIP_OUTCOME:-0}" == "1" ]]; then
  echo "[BuildRimeIOS:error] AMBIG_OUTCOME_ONLY=1 conflicts with AMBIG_SKIP_OUTCOME=1" >&2
  exit 2
fi
# Self-contained stub run: proves ambiguity-outcome-main.c's assertion logic is
# load-bearing (it FAILS on the current guard behaviour) and satisfiable (it
# PASSES once the guards report RB_AMBIG_INVALID), without the pinned engine.
# The stub is a negative control only — the production proof is the real-engine
# section below, which stays fail-closed on a missing prefix.
if [[ -n "${AMBIG_OUTCOME_STUB:-}" ]]; then
  case "${AMBIG_OUTCOME_STUB}" in
    current|fixed) ;;
    *) echo "AMBIG_OUTCOME_STUB must be 'current' or 'fixed' (got '${AMBIG_OUTCOME_STUB}')" >&2; exit 2 ;;
  esac
  _MACOS_SDK="$(xcrun --sdk macosx --show-sdk-path)"
  # Scratch directory OUTSIDE the repo. The trap removes only this directory,
  # which mktemp just created; no project artifact or engine output is touched.
  _STUB_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ambiguity-outcome-stub.XXXXXX")"
  trap 'rm -rf "${_STUB_DIR}"' EXIT
  echo "[BuildRimeIOS] ambiguity outcome contract: STUB run (AMBIG_OUTCOME_STUB=${AMBIG_OUTCOME_STUB}, no engine)"
  echo "[BuildRimeIOS] negative control — the real-engine proof is the default run"
  # The stub supplies its own engine/session/snapshot service; the harness source
  # is compiled UNMODIFIED, exactly as in the production run.
  xcrun --sdk macosx clang -std=c11 -O1 -Wall -Wextra -Werror \
    -isysroot "${_MACOS_SDK}" -mmacosx-version-min=13.0 \
    -I"${_IOS_TOOLS_DIR}/src" \
    "${_IOS_TOOLS_DIR}/harness-mac/ambiguity-outcome-main.c" \
    "${_IOS_TOOLS_DIR}/harness-mac/ambiguity-outcome-contract-stub.c" \
    -o "${_STUB_DIR}/ambiguity-outcome-stub"
  _STUB_SHARED="${_IOS_TOOLS_DIR}/testdata/shared"
  if [[ ! -f "${_STUB_SHARED}/default.yaml" ]]; then
    _STUB_SHARED="${_PROJECT_ROOT}/Tools/BuildRime/testdata/shared"
  fi
  mkdir -p "${_STUB_DIR}/user"
  set +e
  AMBIG_OUTCOME_STUB_MODE="${AMBIG_OUTCOME_STUB}" \
    "${_STUB_DIR}/ambiguity-outcome-stub" \
    --shared "${_STUB_SHARED}" --user "${_STUB_DIR}/user"
  _STUB_STATUS=$?
  set -e
  echo "[BuildRimeIOS] stub exit=${_STUB_STATUS}"
  if [[ "${AMBIG_OUTCOME_STUB}" == "current" && "${_STUB_STATUS}" == "0" ]]; then
    echo "[BuildRimeIOS:error] the harness PASSED against current (defective) guards — it is vacuous" >&2
    exit 1
  fi
  if [[ "${AMBIG_OUTCOME_STUB}" == "fixed" && "${_STUB_STATUS}" != "0" ]]; then
    echo "[BuildRimeIOS:error] the harness FAILED against contract-correct guards — it is unsatisfiable" >&2
    exit 1
  fi
  echo "[BuildRimeIOS] PASS: assertion is load-bearing and satisfiable"
  exit 0
fi

# shellcheck disable=SC1091
source "${_SCRIPT_DIR}/lib/harness.sh"

SHIM_SRC_DIR="${IOS_TOOLS_DIR}/src"

[[ -f "${MAC_PREFIX}/lib/librime.a" ]] || die "missing ${MAC_PREFIX}/lib/librime.a (run Tools/BuildRime)"

# Use the pinned macOS librime configuration, including an explicit isolated override.
GEN_INCLUDE="$(rime_generated_include)"

RUN_DIR="$(new_harness_dir ambiguity)"
prepare_native_bridge
compile_bridge_c
compile_bridge_cpp rime_spelling -DRB_AMBIGUITY_SELFTEST
compile_bridge_cpp rime_display_map

# ---- C bridge outcome contract (harness-mac/ambiguity-outcome-main.c) ------
# A pure-C harness: it drives the exported rb_apply/rb_restore API directly, so
# it links only rime_bridge.o + rime_spelling.o and never needs the Swift
# wrapper nor rime_display_map.o. It still requires the pinned macOS librime
# prefix (already asserted fail-closed above).
#
# The result is ACCUMULATED rather than aborting immediately: the contract
# violation must be reported without masking the existing Swift profile
# coverage, and the script still exits non-zero (fail closed) at the end.
OUTCOME_STATUS=0
OUTCOME_SECTION=0
if [[ "${AMBIG_SKIP_OUTCOME:-0}" != "1" ]]; then
  OUTCOME_SECTION=1
  say "compile + link C ambiguity outcome contract harness"
  OUTCOME_USER="${AMBIG_OUTCOME_USER:-$(new_isolated_dir "${RUN_DIR}/outcome-user")}"
  # The contract section only needs ONE bootable librime service and one live
  # session; the engine self-test tree is enough and is the same tree
  # 21-macos-allocation.sh uses. Resolve explicitly and fail closed.
  if [[ -n "${AMBIG_OUTCOME_SHARED:-}" ]]; then
    OUTCOME_SHARED="${AMBIG_OUTCOME_SHARED}"
  else
    OUTCOME_SHARED=""
    for candidate in "${IOS_TOOLS_DIR}/testdata/shared" \
                     "${PROJECT_ROOT}/Tools/BuildRime/testdata/shared"; do
      if [[ -f "${candidate}/default.yaml" ]]; then OUTCOME_SHARED="${candidate}"; break; fi
    done
    [[ -n "${OUTCOME_SHARED}" ]] || die \
      "no engine self-test shared tree found; set AMBIG_OUTCOME_SHARED to a directory containing default.yaml"
  fi
  "${MAC_CC}" -std=c11 -O2 -Wall -Wextra -Werror -c -isysroot "${MACOS_SDK}" \
    -I"${SHIM_SRC_DIR}" -I"${MAC_PREFIX}/include" \
    -mmacosx-version-min=13.0 \
    "${IOS_TOOLS_DIR}/harness-mac/ambiguity-outcome-main.c" \
    -o "${RUN_DIR}/ambiguity_outcome_main.o"
  "${MAC_CC}" -isysroot "${MACOS_SDK}" -mmacosx-version-min=13.0 \
    "${RUN_DIR}/ambiguity_outcome_main.o" \
    "${RUN_DIR}/rime_bridge.o" "${RUN_DIR}/rime_spelling.o" \
    "${MAC_LINK_FLAGS[@]}" \
    -o "${RUN_DIR}/ambiguity-outcome-harness"
  [[ -f "${OUTCOME_SHARED}/default.yaml" ]] || die "outcome shared data missing: ${OUTCOME_SHARED}"
  say "run C ambiguity outcome contract (invalid/no-session early-outs)"
  set +e
  "${RUN_DIR}/ambiguity-outcome-harness" \
    --shared "${OUTCOME_SHARED}" --user "${OUTCOME_USER}" \
    > "${RUN_DIR}/outcome.log" 2>&1
  OUTCOME_STATUS=$?
  set -e
  cat "${RUN_DIR}/outcome.log"
  if [[ "${OUTCOME_STATUS}" != "0" ]]; then
    printf '\n[BuildRimeIOS:warn] C ambiguity outcome contract FAILED (exit %d); full log: %s\n' \
      "${OUTCOME_STATUS}" "${RUN_DIR}/outcome.log"
  fi
fi

# AMBIG_OUTCOME_ONLY short-circuits before the Swift profiles so the contract
# section can be run on its own (the built-in/ice fixtures are not needed for it).
if [[ "${AMBIG_OUTCOME_ONLY:-0}" == "1" ]]; then
  say "outcome-only run complete; harness dir: ${RUN_DIR}"
  exit "${OUTCOME_STATUS}"
fi

say "compile + link harness"
PKG="${PROJECT_ROOT}/Packages"
# Learning bridge C adapter: same -fno-modules + original public header ABI the
# SPM target uses. RimeEngine.swift references RimeLearningBackup.swift, so the
# explicit wrapper list gains that file and the link gains the adapter object.
say "compile learning C adapter"
MACOS_SDK="$(xcrun --sdk macosx --show-sdk-path)"
python3 "${PROJECT_ROOT}/Tools/BuildRimeIOS/scripts/build-learning-support.py" \
  --sdk "${MACOS_SDK}" --target arm64-apple-macos13.0 \
  --kit-include-dir "${MAC_PREFIX}/include" \
  --output-dir "${RUN_DIR}/learning-support"
swiftc -O -Xcc -fmodule-map-file="${RUN_DIR}/RimeKitModule/module.modulemap" \
  -Xcc -DRB_AMBIGUITY_SELFTEST \
  -Xcc -fmodule-map-file="${RUN_DIR}/learning-support/module/module.modulemap" \
  -I "${RUN_DIR}/RimeKitModule" -I "${MAC_PREFIX}/include" -I "${RUN_DIR}/learning-support/module" \
  "${IOS_TOOLS_DIR}/harness-mac/ambiguity-main.swift" \
  "${PKG}/RimeBridge/Sources/RimeBridge/RimeModels.swift" \
  "${PKG}/RimeBridge/Sources/RimeBridge/RimeKey.swift" \
  "${PKG}/RimeBridge/Sources/RimeBridge/RimeEngine.swift" \
  "${PKG}/RimeBridge/Sources/RimeBridge/RimeEngine+Maintenance.swift" \
  "${PKG}/RimeBridge/Sources/RimeBridge/RimeEngine+SchemaConfig.swift" \
  "${PKG}/RimeBridge/Sources/RimeBridge/RimeEngine+Snapshot.swift" \
  "${PKG}/RimeBridge/Sources/RimeBridge/RimeEngine+Spelling.swift" \
  "${PKG}/RimeBridge/Sources/RimeBridge/RimeLearningBackup.swift" \
  "${RUN_DIR}/rime_bridge.o" "${RUN_DIR}/rime_spelling.o" "${RUN_DIR}/rime_display_map.o" \
  "${RUN_DIR}/learning-support/RimeLeversSupport.o" \
  "${MAC_LINK_FLAGS[@]}" \
  -target arm64-apple-macos13.0 -o "${RUN_DIR}/harness"

BUILTIN_SHARED="${AMBIG_BUILTIN_SHARED:-${PROJECT_ROOT}/Resources/BuiltinPackages/Basic}"
BUILTIN_USER="${AMBIG_BUILTIN_USER:-$(new_isolated_dir "${RUN_DIR}/builtin-user")}"
ICE_SHARED="${AMBIG_ICE_SHARED:-}"
ICE_USER="${AMBIG_ICE_USER:-}"
ICE_PREBUILT="${AMBIG_ICE_PREBUILT:-${ICE_USER:+${ICE_USER}/build}}"
if [[ -z "${ICE_SHARED}" || -z "${ICE_USER}" ]]; then
  AMBIG_SKIP_ICE=1
  say "skip rime-ice t9 profile: set AMBIG_ICE_SHARED and AMBIG_ICE_USER to run it"
fi

if [[ "${AMBIG_SKIP_BUILTIN:-0}" != "1" ]]; then
  [[ -f "${BUILTIN_SHARED}/default.yaml" ]] || die "built-in package missing: ${BUILTIN_SHARED}"
  say "run built-in profile (9-key, 14-key flypy, songyan_flypy)"
  "${RUN_DIR}/harness" --shared "${BUILTIN_SHARED}" --user "${BUILTIN_USER}" | tee "${RUN_DIR}/builtin.log"
fi

if [[ "${AMBIG_SKIP_ICE:-0}" != "1" ]]; then
  for required in "${ICE_SHARED}/default.yaml" "${ICE_PREBUILT}/default.yaml"; do
    [[ -f "${required}" ]] || die "ice t9 staged data missing: ${required} (provide AMBIG_ICE_SHARED/AMBIG_ICE_PREBUILT or set AMBIG_SKIP_ICE=1)"
  done
  say "run rime-ice t9 profile (t9)"
  "${RUN_DIR}/harness" --shared "${ICE_SHARED}" --user "${ICE_USER}" --prebuilt "${ICE_PREBUILT}" \
    | tee "${RUN_DIR}/ice.log"
fi

if [[ "${AMBIG_SKIP_GENERIC:-0}" != "1" ]]; then
  GENERIC_SHARED="${AMBIG_GENERIC_SHARED:-${IOS_TOOLS_DIR}/testdata/generic-ambiguity/bad-bindings}"
  [[ -f "${GENERIC_SHARED}/default.yaml" ]] || die "generic ambiguity data missing: ${GENERIC_SHARED}"
  say "run fail-closed adapter profile (cross-wired adapter)"
  "${RUN_DIR}/harness" --shared "${GENERIC_SHARED}" \
    --user "$(new_isolated_dir "${RUN_DIR}/generic-user")" | tee "${RUN_DIR}/generic.log"
fi

say "harness dir: ${RUN_DIR}"

if [[ "${OUTCOME_SECTION}" == "1" && "${OUTCOME_STATUS}" != "0" ]]; then
  die "C ambiguity outcome contract failed (exit ${OUTCOME_STATUS}); log: ${RUN_DIR}/outcome.log"
fi
