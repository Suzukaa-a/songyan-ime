#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 36-grammar-window-harness.sh — focused native regression for the bounded/lazy
# grammar validation in Tools/BuildRimeIOS/src/rime_grammar_bounds.h.
#
# Self-contained: needs only the Xcode clang toolchain and macOS SDK (no librime,
# no glog, no simulator). Runs the same probe twice:
#   * plain build  — predicate parity, bounded-lookup safety, and the residency
#                    measurement (page faults + phys_footprint + RSS) on a huge
#                    synthetic array and on the real grammar model when present;
#   * ASan+UBSan build — proves hostile/truncated arrays never read out of the
#                    mapping, no matter how the validation/lookup are called.
#
# Nothing is deleted; outputs go to a fresh isolated run directory.
#
# Usage: Tools/BuildRimeIOS/scripts/36-grammar-window-harness.sh [real-model.gram]
# The real-model measurement runs only when a .gram path is given (argument or
# GRAMMAR_REAL_MODEL); otherwise only the synthetic arrays are checked.
# ---------------------------------------------------------------------------
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/harness.sh"

REAL_MODEL="${1:-${GRAMMAR_REAL_MODEL:-}}"
if [[ -n "${REAL_MODEL}" && ! -f "${REAL_MODEL}" ]]; then
  die "grammar model not found: ${REAL_MODEL}"
fi
MAC_SDK="$(xcrun --sdk macosx --show-sdk-path)"
RUN="$(new_harness_dir grammar-window)"
HARNESS="${IOS_TOOLS_DIR}/harness-mac/grammar-window-main.cc"
INCLUDE="${IOS_TOOLS_DIR}/src"

say "compile grammar-window harness (plain)"
"${MAC_CXX}" -std=c++17 -O2 -isysroot "${MAC_SDK}" -mmacosx-version-min=13.0 \
  -I"${INCLUDE}" "${HARNESS}" -o "${RUN}/grammar-window"
say "run grammar-window harness (plain)"
"${RUN}/grammar-window" "${RUN}/probe" "${REAL_MODEL}" | tee "${RUN}/plain.log"

say "compile grammar-window harness (ASan + UBSan)"
"${MAC_CXX}" -std=c++17 -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer \
  -isysroot "${MAC_SDK}" -mmacosx-version-min=13.0 \
  -I"${INCLUDE}" "${HARNESS}" -o "${RUN}/grammar-window-asan"
say "run grammar-window harness (ASan + UBSan)"
ASAN_OPTIONS=detect_leaks=0 "${RUN}/grammar-window-asan" "${RUN}/probe-asan" "${REAL_MODEL}" \
  | tee "${RUN}/asan.log"

say "grammar-window harness PASS; logs in ${RUN}"
