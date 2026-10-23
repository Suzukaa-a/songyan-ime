# ---------------------------------------------------------------------------
# host-tools.sh — paths of the pinned macOS host tools the iOS build runs on
# the build machine. Sourced by 00-common.sh and 14-build-host-opencc.sh; it
# stays free of xcrun/SDK lookups so the host tool builds without an iOS SDK.
#
# Inputs (a caller may preset any of them):
#   PROJECT_ROOT      repo root — computed from this file's location if unset
#   IOS_ROOT          iOS build root, default <repo>/.local/ios-engine
#   HOST_ENGINE_ROOT  pinned read-only engine root that also holds the pinned
#                     cmake; defaults to ENGINE_WORK (the Tools/BuildRime
#                     isolated-root convention) or <repo>/.local/engine
# ---------------------------------------------------------------------------

_host_tools_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${PROJECT_ROOT:-}" ]]; then
  PROJECT_ROOT="$(cd "${_host_tools_dir}/../../../.." && pwd)"
fi
IOS_ROOT="${IOS_ROOT:-${PROJECT_ROOT}/.local/ios-engine}"

HOST_ENGINE_ROOT="${HOST_ENGINE_ROOT:-${ENGINE_WORK:-${PROJECT_ROOT}/.local/engine}}"
HOST_CMAKE="${HOST_CMAKE:-${HOST_ENGINE_ROOT}/tools/cmake/CMake.app/Contents/bin/cmake}"
HOST_DEP_SRC_ROOT="${HOST_DEP_SRC_ROOT:-${HOST_ENGINE_ROOT}/src/librime/deps}"

# Not the Tools/BuildRime macOS prefix: that one only exists after the full
# macOS librime build, while this tool must build on its own.
HOST_OPENCC_PREFIX="${HOST_OPENCC_PREFIX:-${IOS_ROOT}/prefix-mac}"
# CMake build trees for the host marisa-trie and OpenCC (marisa/, opencc/).
HOST_OPENCC_BUILD="${HOST_OPENCC_BUILD:-${IOS_ROOT}/build/host-opencc}"
HOST_OPENCC_SRC="${HOST_OPENCC_SRC:-${HOST_DEP_SRC_ROOT}/opencc}"
HOST_MARISA_SRC="${HOST_MARISA_SRC:-${HOST_DEP_SRC_ROOT}/marisa-trie}"

HOST_OPENCC_DICT="${HOST_OPENCC_DICT:-${HOST_OPENCC_PREFIX}/bin/opencc_dict}"
HOST_OPENCC_EMULATOR="${HOST_OPENCC_EMULATOR:-${HOST_OPENCC_PREFIX}/bin/opencc_dict-host}"
HOST_OPENCC_IDENTITY="${HOST_OPENCC_IDENTITY:-${HOST_OPENCC_PREFIX}/host-opencc-identity.json}"
HOST_OPENCC_EMULATOR_SOURCE="${HOST_OPENCC_EMULATOR_SOURCE:-${_host_tools_dir}/opencc-dict-emulator.sh}"

HOST_OPENCC_SCRIPT="${HOST_OPENCC_SCRIPT:-${PROJECT_ROOT}/Tools/BuildRimeIOS/scripts/14-build-host-opencc.sh}"

# Build or verify the host tool once per run; 11-build-deps.sh calls this before
# configuring OpenCC for each slice. Relies on the caller's say/die.
ensure_host_opencc_tool() {
  [[ "${_host_opencc_ensured:-0}" == "1" ]] && return 0
  if [[ -x "${HOST_OPENCC_DICT}" && -x "${HOST_OPENCC_EMULATOR}" ]] && "${HOST_OPENCC_SCRIPT}" --check; then
    say "host opencc_dict ready: ${HOST_OPENCC_DICT}"
  else
    say "building the pinned macOS host opencc_dict (once per build root)"
    "${HOST_OPENCC_SCRIPT}" || die \
      "cannot build the pinned macOS host opencc_dict; run ${HOST_OPENCC_SCRIPT} on its own to see the full output"
  fi
  _host_opencc_ensured=1
}
