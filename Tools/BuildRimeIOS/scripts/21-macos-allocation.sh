#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/00-common.sh"
verify_pins
RUN_DIR="$(new_isolated_dir "${IOS_ROOT}/test-runs/allocation")"
mkdir -p "${RUN_DIR}/user"
"${CC}" -std=c11 -g -O1 -fsanitize=address,undefined -fno-omit-frame-pointer \
  -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
  -I"${MAC_PREFIX}/include" -mmacosx-version-min=13.0 \
  "${IOS_TOOLS_DIR}/harness-mac/allocation-main.c" \
  "${MAC_PREFIX}/lib/librime.a" \
  "${MAC_PREFIX}/lib/libglog.a" \
  "${MAC_PREFIX}/lib/libleveldb.a" \
  "${MAC_PREFIX}/lib/libmarisa.a" \
  "${MAC_PREFIX}/lib/libopencc.a" \
  "${MAC_PREFIX}/lib/libyaml-cpp.a" \
  "${BOOST_SRC}/stage/lib/libboost_regex.a" \
  -lc++ -lc++abi -liconv -lpthread -o "${RUN_DIR}/harness" \
  > "${RUN_DIR}/build.log" 2>&1 || { tail -60 "${RUN_DIR}/build.log" >&2; exit 1; }
"${RUN_DIR}/harness" "${PROJECT_ROOT}/Tools/BuildRime/testdata/shared" "${RUN_DIR}/user" \
  > "${RUN_DIR}/run.out" 2>&1 || { tail -60 "${RUN_DIR}/run.out" >&2; exit 1; }
grep -E '^(PASS|ALL PASS)' "${RUN_DIR}/run.out"
say "allocation regression complete: ${RUN_DIR}"
