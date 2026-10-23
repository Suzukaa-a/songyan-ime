# shellcheck disable=SC2034  # these variables are read by the scripts that source this file
# ---------------------------------------------------------------------------
# Shared helpers for the Tools/BuildRime scripts.
# Safe to source from any script under Tools/BuildRime/scripts.
#
# Safety contract:
#   * These scripts never delete anything (no destructive cleanup commands).
#   * Existing valid artifacts are reused as-is (checksum / pinned commit
#     verified). A present-but-wrong artifact is a CONFLICT: the script stops
#     with an error instead of deleting or overwriting it.
#   * To build into fresh, isolated locations set ENGINE_WORK=<dir> (the dir is
#     created if missing; an existing ENGINE_WORK is reused untouched and must
#     contain the expected artifacts for incremental steps). Without ENGINE_WORK
#     every artifact path stays inside <repo>/.local/engine.
# ---------------------------------------------------------------------------
set -euo pipefail

# Resolve repo layout regardless of the CWD the caller uses.
#   Tools/BuildRime/scripts/common.sh
#   Tools/BuildRime/
#   <repo root>/
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_RIME_DIR="$(cd "${_SCRIPT_DIR}/.." && pwd)"     # Tools/BuildRime
PROJECT_ROOT="$(cd "${TOOLS_RIME_DIR}/../.." && pwd)" # repo root

# macOS deployment target. Exported so every child process — the CMake
# build of every dependency, boost b2, librime, and the final clang++ link of
# rime_cli — actually receives it. Build scripts additionally pass the value
# explicitly (-DCMAKE_OSX_DEPLOYMENT_TARGET / -mmacosx-version-min).
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"

# Root of every engine artifact. Defaults to <repo>/.local/engine. Setting
# ENGINE_WORK points the whole chain (downloads, sources, tools, prefix, bin,
# test-runs) at a fresh, isolated root; nothing in the default root is touched.
# The directory is created if it does not exist yet (never deleted).
if [[ -n "${ENGINE_WORK:-}" ]]; then
  mkdir -p "${ENGINE_WORK}"
  ENGINE_ROOT="$(cd "${ENGINE_WORK}" && pwd)"
else
  ENGINE_ROOT="${PROJECT_ROOT}/.local/engine"
fi
ENGINE_DOWNLOADS="${ENGINE_ROOT}/downloads"
ENGINE_SRC="${ENGINE_ROOT}/src"
ENGINE_BUILD="${ENGINE_ROOT}/build"
ENGINE_PREFIX="${ENGINE_ROOT}/prefix"
ENGINE_TOOLS="${ENGINE_ROOT}/tools"
ENGINE_BIN="${ENGINE_ROOT}/bin"
ENGINE_LOGS="${ENGINE_ROOT}/logs"
ENGINE_RUNS="${ENGINE_ROOT}/test-runs"

# shellcheck disable=SC1091
source "${TOOLS_RIME_DIR}/VERSIONS.env"

# CMake: use the locally fetched, pinned binary. macOS distribution keeps the
# binary under CMake.app/Contents/bin.
if [[ -x "${ENGINE_TOOLS}/cmake/CMake.app/Contents/bin/cmake" ]]; then
  CMAKE="${ENGINE_TOOLS}/cmake/CMake.app/Contents/bin/cmake"
fi

LIBRIME_SRC="${ENGINE_SRC}/librime"
BOOST_SRC="${ENGINE_SRC}/${BOOST_DIRNAME}"

NPROC="$(sysctl -n hw.ncpu 2>/dev/null || echo 8)"

say()  { printf '\n\033[1;36m[BuildRime] %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[BuildRime:warn] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[BuildRime:error] %s\033[0m\n' "$*" >&2; exit 1; }

ensure_dirs() {
  mkdir -p \
    "${ENGINE_DOWNLOADS}" "${ENGINE_SRC}" "${ENGINE_BUILD}" \
    "${ENGINE_PREFIX}" "${ENGINE_TOOLS}" "${ENGINE_BIN}" \
    "${ENGINE_LOGS}" "${ENGINE_RUNS}"
}

# Create a brand-new empty directory under $1 that did not exist before.
# Never deletes: on the (unlikely) collision it retries with a numeric suffix.
new_isolated_dir() { # $1 base path
  local base="$1" d i=0
  d="${base}.$$"
  while [[ -e "${d}" ]]; do d="${base}.$$.$((i++))"; done
  mkdir -p "${d}"
  printf '%s' "${d}"
}

require_cmake() {
  [[ -n "${CMAKE:-}" && -x "${CMAKE}" ]] \
    || die "local cmake not found; run scripts/01-fetch.sh first (looked for ${ENGINE_TOOLS}/cmake)"
}

require_librime() {
  [[ -d "${LIBRIME_SRC}/.git" ]] \
    || die "librime checkout missing; run scripts/01-fetch.sh first"
  local head
  head="$(git -C "${LIBRIME_SRC}" rev-parse HEAD 2>/dev/null || true)"
  [[ "${head}" == "${LIBRIME_COMMIT}" ]] \
    || die "librime HEAD ${head:-<none>} != pinned ${LIBRIME_COMMIT}; use ENGINE_WORK=<new dir> for an isolated fetch+build"
}

require_boost() {
  [[ -x "${BOOST_SRC}/bootstrap.sh" ]] \
    || die "boost source missing; run scripts/01-fetch.sh first"
}
