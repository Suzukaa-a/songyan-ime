#!/usr/bin/env bash
# macOS harness tooling only; no iOS SDKs or CMake needed.
set -euo pipefail

HARNESS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_TOOLS_DIR="$(cd "${HARNESS_LIB_DIR}/../.." && pwd)"
PROJECT_ROOT="$(cd "${IOS_TOOLS_DIR}/../.." && pwd)"
source "${PROJECT_ROOT}/Tools/BuildRime/VERSIONS.env"
if [[ -z "${DEVELOPER_DIR:-}" && -n "${XCODE_DEV_DIR:-}" ]]; then
  export DEVELOPER_DIR="${XCODE_DEV_DIR}"
fi

MACOS_SDK="$(xcrun --sdk macosx --show-sdk-path)"
MAC_CC="${MAC_CC:-$(xcrun --find clang)}"
MAC_CXX="${MAC_CXX:-$(xcrun --find clang++)}"
SHIM_SRC_DIR="${IOS_TOOLS_DIR}/src"
NATIVE_ENGINE_ROOT="${NATIVE_ENGINE_ROOT:-${PROJECT_ROOT}/.local/engine}"
MAC_PREFIX="${MAC_PREFIX:-${NATIVE_ENGINE_ROOT}/prefix}"
LIBRIME_SRC="${NATIVE_ENGINE_ROOT}/src/librime"
BOOST_SRC="${NATIVE_ENGINE_ROOT}/src/${BOOST_DIRNAME}"

say() { printf '\n[Harness] %s\n' "$*"; }
die() { printf '[Harness:error] %s\n' "$*" >&2; exit 1; }

new_harness_dir() {
  local parent="${HARNESS_OUTPUT_ROOT:-${PROJECT_ROOT}/.scratch/native-harnesses}"
  mkdir -p "${parent}"
  mktemp -d "${parent}/$1.XXXXXX"
}

new_isolated_dir() {
  mkdir -p "$(dirname "$1")"
  mktemp -d "$1.XXXXXX"
}

rime_generated_include() {
  local cfg="${LIBRIME_BUILD_CONFIG:-}"
  if [[ -z "${cfg}" ]]; then
    local candidates=("${NATIVE_ENGINE_ROOT}"/build/librime-static*/src/rime/build_config.h)
    [[ -f "${candidates[0]}" ]] && cfg="${candidates[0]}"
  fi
  [[ -n "${cfg}" && -f "${cfg}" ]] || die \
    "Missing generated build_config.h; set LIBRIME_BUILD_CONFIG or run Tools/BuildRime/scripts/03-build-librime.sh."
  (cd "$(dirname "$(dirname "${cfg}")")" && pwd)
}

prepare_native_bridge() {
  [[ -f "${MAC_PREFIX}/lib/librime.a" ]] || die \
    "Missing ${MAC_PREFIX}/lib/librime.a; build Tools/BuildRime or set NATIVE_ENGINE_ROOT."
  mkdir -p "${RUN_DIR}/RimeKitModule"
  cp "${MAC_PREFIX}/include/rime_api.h" "${RUN_DIR}/RimeKitModule/"
  cp "${SHIM_SRC_DIR}/rime_bridge.h" "${RUN_DIR}/RimeKitModule/"
  cp "${IOS_TOOLS_DIR}/harness-mac/RimeKit.modulemap" "${RUN_DIR}/RimeKitModule/module.modulemap"
  cp "${IOS_TOOLS_DIR}/harness-mac/RimeKit.h" "${RUN_DIR}/RimeKitModule/"
  MAC_CXX_FLAGS=(
    -std=c++17 -O2 -c -isysroot "${MACOS_SDK}" -mmacosx-version-min=13.0
    -DBOOST_DLL_USE_STD_FS '-DGLOG_DEPRECATED=__attribute__((deprecated))'
    -DGLOG_EXPORT= -DGLOG_NO_EXPORT= -DOpencc_BUILT_AS_STATIC
    -DYAML_CPP_STATIC_DEFINE '-DRIME_VERSION="1.17.0"'
    -I"${SHIM_SRC_DIR}" -I"${MAC_PREFIX}/include"
    -I"${LIBRIME_SRC}/src" -I"${LIBRIME_SRC}/include" -I"${BOOST_SRC}" -I"${GEN_INCLUDE}"
  )
  MAC_LINK_FLAGS=()
  local library
  for library in rime glog leveldb marisa opencc yaml-cpp; do
    MAC_LINK_FLAGS+=(-Xlinker "${MAC_PREFIX}/lib/lib${library}.a")
  done
  MAC_LINK_FLAGS+=(
    -Xlinker "${BOOST_SRC}/stage/lib/libboost_regex.a"
    -Xlinker -lc++ -Xlinker -lc++abi -liconv -lpthread
  )
}

compile_bridge_c() {
  "${MAC_CC}" -std=c11 -O2 -c -isysroot "${MACOS_SDK}" -mmacosx-version-min=13.0 \
    -I"${SHIM_SRC_DIR}" -I"${MAC_PREFIX}/include" "$@" \
    "${SHIM_SRC_DIR}/rime_bridge.c" -o "${RUN_DIR}/rime_bridge.o"
}

compile_bridge_cpp() {
  local source="$1"
  shift
  "${MAC_CXX}" "${MAC_CXX_FLAGS[@]}" "$@" \
    "${SHIM_SRC_DIR}/${source}.cc" -o "${RUN_DIR}/${source}.o"
}
