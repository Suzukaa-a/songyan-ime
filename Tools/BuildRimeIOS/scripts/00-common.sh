# shellcheck disable=SC2034  # these variables are read by the scripts that source this file
# ---------------------------------------------------------------------------
# 00-common.sh — shared helpers for Tools/BuildRimeIOS scripts.
#
# Safety contract:
#   * NEVER delete anything (no rm, no destructive cleanup, no overwrite of an
#     existing artifact). If a target already exists, either it is verified and
#     skipped, or the script stops with a conflict error and points the caller
#     to a fresh sibling directory.
#   * Everything is built into <repo>/.local/ios-engine/ — a brand-new,
#     dedicated output root that never touches .local/engine/ (the read-only
#     macOS sources) nor the repo tree.
#   * Xcode is selected locally via DEVELOPER_DIR only; the global
#     xcode-select is never changed.
#   * No system-wide installs; no network fetches (sources are reused from the
#     pinned .local/engine checkouts).
# ---------------------------------------------------------------------------
set -euo pipefail

# Resolve repo layout regardless of CWD.
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_TOOLS_DIR="$(cd "${_SCRIPT_DIR}/.." && pwd)"       # Tools/BuildRimeIOS
PROJECT_ROOT="$(cd "${IOS_TOOLS_DIR}/../.." && pwd)"   # repo root

# Read the pinned versions table (values only; never runs BuildRime scripts).
# shellcheck disable=SC1091
source "${PROJECT_ROOT}/Tools/BuildRime/VERSIONS.env"

IOS_ROOT="${IOS_ROOT:-${PROJECT_ROOT}/.local/ios-engine}"
IOS_LOG_DIR="${IOS_ROOT}/logs"
IOS_OUT="${IOS_ROOT}/out"

# iOS slices (two static prefixes, fully separate from the macOS prefix)
PREFIX_SIM="${PREFIX_SIM:-${IOS_ROOT}/prefix/sim-arm64}"
PREFIX_DEV="${PREFIX_DEV:-${IOS_ROOT}/prefix/device-arm64}"
BUILD_DIR_ROOT="${IOS_ROOT}/build"

# Deployment target for iOS slices (iOS 17 or later).
IOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-17.0}"

# Xcode selection — local only.
XCODE_DEV_DIR="${XCODE_DEV_DIR:-${DEVELOPER_DIR:-$(xcode-select -p)}}"
export DEVELOPER_DIR="${XCODE_DEV_DIR}"
XCODE_TOOLCHAIN="${XCODE_DEV_DIR}/Toolchains/XcodeDefault.xctoolchain/usr/bin"
export CC="${XCODE_TOOLCHAIN}/clang"
export CXX="${XCODE_TOOLCHAIN}/clang++"
export AR="${XCODE_TOOLCHAIN}/ar"
export RANLIB="${XCODE_TOOLCHAIN}/ranlib"

# SDKs
SIM_SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
DEV_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
SIM_SDK_VERSION="$(xcrun --sdk iphonesimulator --show-sdk-version)"
DEV_SDK_VERSION="$(xcrun --sdk iphoneos --show-sdk-version)"

# Explicit clang targets per slice (mirrors what CMake derives from the SDK).
SIM_TARGET="arm64-apple-ios${IOS_DEPLOYMENT_TARGET}-simulator"
DEV_TARGET="arm64-apple-ios${IOS_DEPLOYMENT_TARGET}"

# Pinned local cmake from Tools/BuildRime fetch (read-only reuse).
CMAKE="${PROJECT_ROOT}/.local/engine/tools/cmake/CMake.app/Contents/bin/cmake"
[[ -x "${CMAKE}" ]] || { echo "[BuildRimeIOS:error] pinned cmake missing at ${CMAKE} (run Tools/BuildRime/scripts/01-fetch.sh once)" >&2; exit 1; }

# macOS prefix produced by the pinned macOS build (Tools/BuildRime). The macOS
# harnesses link its libraries and headers read-only; the iOS build's host
# opencc_dict lives in HOST_OPENCC_PREFIX instead (scripts/lib/host-tools.sh).
MAC_PREFIX="${MAC_PREFIX:-${PROJECT_ROOT}/.local/engine/prefix}"

# Host-tool paths; 11-build-deps.sh uses HOST_OPENCC_EMULATOR for OpenCC data.
# shellcheck source=lib/host-tools.sh
source "${_SCRIPT_DIR}/lib/host-tools.sh"

# Read-only sources (checked out at pinned commits by Tools/BuildRime/scripts/01-fetch.sh).
LIBRIME_SRC="${PROJECT_ROOT}/.local/engine/src/librime"
BOOST_SRC="${PROJECT_ROOT}/.local/engine/src/${BOOST_DIRNAME}"
DEP_SRC_ROOT="${LIBRIME_SRC}/deps"

# The five static deps plus googletest (which is a submodule present under
# librime/deps but is only needed for tests; it is never built here).
RIME_DEPS=(glog leveldb marisa-trie opencc yaml-cpp)

NPROC="${NPROC:-$(sysctl -n hw.ncpu 2>/dev/null || echo 8)}"

say()  { printf '\n\033[1;36m[BuildRimeIOS] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[BuildRimeIOS:error] %s\033[0m\n' "$*" >&2; exit 1; }
warn() { printf '\033[1;33m[BuildRimeIOS:warn] %s\033[0m\n' "$*" >&2; }

# Resolve the generated `rime/build_config.h` include directory for the macOS librime
# C++ ABI. Deterministic and documented — never a silent tree-wide find:
#   1. `LIBRIME_BUILD_CONFIG` (full path to build_config.h) wins when set;
#   2. otherwise the Tools/BuildRime build dir, i.e.
#      `${PROJECT_ROOT}/.local/engine/build/librime-static*/src/rime/build_config.h`
#      (see Tools/BuildRime/scripts/03-build-librime.sh + common.sh ENGINE_BUILD);
#   3. otherwise fail with an actionable message.
# Echoes the directory that must be passed as `-I` (i.e. the `src` dir above `rime/`).
rime_generated_include() {
  local engine_build="${PROJECT_ROOT}/.local/engine/build"
  local cfg="${LIBRIME_BUILD_CONFIG:-}"
  if [[ -z "${cfg}" ]]; then
    local candidates=("${engine_build}"/librime-static*/src/rime/build_config.h)
    [[ -f "${candidates[0]:-}" ]] && cfg="${candidates[0]}"
  fi
  [[ -n "${cfg}" && -f "${cfg}" ]] || die \
    "generated librime build_config.h not found." \
    "Set LIBRIME_BUILD_CONFIG=/abs/path/to/src/rime/build_config.h, or run Tools/BuildRime/scripts/03-build-librime.sh."
  (cd "$(dirname "$(dirname "${cfg}")")" && pwd)
}

ensure_ios_dirs() {
  mkdir -p "${IOS_LOG_DIR}" "${IOS_OUT}" \
    "${PREFIX_SIM}/lib" "${PREFIX_DEV}/lib" \
    "${BUILD_DIR_ROOT}" "${IOS_ROOT}/slices"
}

# Verify every required read-only source is present and at its pinned commit.
dep_pinned_commit() { # $1 dep name -> echoes its pinned commit
  case "$1" in
    glog) echo "${GLOG_COMMIT}" ;;
    leveldb) echo "${LEVELDB_COMMIT}" ;;
    marisa-trie) echo "${MARISA_COMMIT}" ;;
    opencc) echo "${OPENCC_COMMIT}" ;;
    yaml-cpp) echo "${YAMLCPP_COMMIT}" ;;
    *) return 1 ;;
  esac
}
verify_pins() {
  ensure_ios_dirs
  [[ -d "${LIBRIME_SRC}/.git" ]] || die "librime checkout missing at ${LIBRIME_SRC}"
  local head got want
  head="$(git -C "${LIBRIME_SRC}" rev-parse HEAD 2>/dev/null || true)"
  [[ "${head}" == "${LIBRIME_COMMIT}" ]] || die "librime HEAD ${head:-<none>} != pinned ${LIBRIME_COMMIT}"
  for name in "${RIME_DEPS[@]}"; do
    local d="${DEP_SRC_ROOT}/${name}"
    got="$(git -C "${d}" rev-parse HEAD 2>/dev/null || true)"
    [[ -n "${got}" ]] || die "dep checkout missing/invalid: ${d}"
    want="$(dep_pinned_commit "${name}")"
    [[ "${got}" == "${want}" ]] || die "dep ${name} @ ${got:-<none>} != pinned ${want}"
  done
  [[ -x "${BOOST_SRC}/bootstrap.sh" ]] || die "boost source missing at ${BOOST_SRC}"
  say "sources verified at pinned commits (librime ${LIBRIME_COMMIT}, boost ${BOOST_VERSION})"
}

# Create a brand-new empty directory under $1 that did not exist before.
# Never deletes; on collision retries with a numeric suffix.
new_isolated_dir() { # $1 base path
  local base="$1" d i=0
  d="${base}.$$"
  while [[ -e "${d}" ]]; do d="${base}.$$.$((i++))"; done
  mkdir -p "${d}"
  printf '%s' "${d}"
}

# Common iOS cmake args for one slice. $1 = prefix, $2 = sdk, $3 = sdk name
ios_cmake_common() { # prefix sdk
  printf -- '-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=%s -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=%s -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=%s' \
    "$2" "${IOS_DEPLOYMENT_TARGET}" "$1"
}

logfile() { printf '%s/%s-%s.log' "${IOS_LOG_DIR}" "$1" "$2"; }

# Inspect actual archive bytes, not version labels. Pinned 0.3.1 objects embed
# marisa-trie source paths; bundled 0.2.6 objects embed marisa-0.2.6 paths.
verify_marisa_prefix() {
  local prefix="$1" archive matches
  matches="$(strings "${prefix}/lib/libmarisa.a" | grep -c 'marisa-trie/lib/marisa' || true)"
  [[ "${matches}" -gt 0 ]] || die "${prefix}: external marisa 0.3.1 fingerprint missing; rebuild in a fresh IOS_ROOT"
  for archive in "${prefix}/lib/"*.a; do
    matches="$(strings "${archive}" | grep -c 'marisa-0\.2\.6' || true)"
    [[ "${matches}" -eq 0 ]] || die "bundled marisa 0.2.6 in ${archive}; rebuild in a fresh IOS_ROOT"
  done
  say "PASS: ${prefix} archives use pinned external marisa, no bundled 0.2.6"
}
