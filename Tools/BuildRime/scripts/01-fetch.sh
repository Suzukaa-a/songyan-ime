#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 01-fetch.sh — download / check out every pinned artifact.
#
#   * cmake        : official prebuilt macOS universal tarball  (downloads + tools/)
#   * librime      : pinned commit LIBRIME_COMMIT (release 1.17.0)
#   * librime deps : the five third-party deps recorded as submodules of
#                    librime at that commit (glog, leveldb, marisa-trie,
#                    opencc, yaml-cpp) — checked out into librime/deps/
#   * boost 1.89.0 : source tarball (downloads + src/)
#
# Safety: this script never deletes anything. Present, checksum-valid /
# pinned-commit artifacts are reused. A present-but-wrong artifact stops the
# run with a conflict error instead of being removed. To build from scratch in
# a fresh location set ENGINE_WORK=<new empty-or-absent dir>.
# ---------------------------------------------------------------------------
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

ensure_dirs

fetch_url() { # $1 url, $2 dest file, $3 sha256
  local url="$1" dest="$2" sha="$3"
  if [[ -f "${dest}" ]]; then
    echo "${sha}  ${dest}" | shasum -a 256 -c - >/dev/null 2>&1 \
      && { say "already downloaded: ${dest}"; return; }
    warn "checksum mismatch / incomplete file, downloading to ${dest}.bad-$$ and retrying"
    # never overwrite the existing file: write a fresh sibling only when the
    # existing copy is corrupt; keep the corrupt file for inspection.
    mv "${dest}" "${dest}.bad-$$"
  fi
  curl -fL --retry 3 -o "${dest}" "${url}"
  echo "${sha}  ${dest}" | shasum -a 256 -c -
}

checkout_pinned() { # $1 repo-url, $2 dest-dir, $3 commit
  local url="$1" dest="$2" commit="$3"
  if [[ -d "${dest}" ]]; then
    local head
    head="$(git -C "${dest}" rev-parse HEAD 2>/dev/null || true)"
    if [[ "${head}" == "${commit}" ]]; then
      say "already at pinned commit: ${dest}"
      return
    fi
    die "conflict: ${dest} exists at ${head:-<no commit>}, expected ${commit}." \
        "Nothing was deleted. Use ENGINE_WORK=<new dir> for an isolated fetch."
  fi
  local parent stage
  parent="$(dirname "${dest}")"
  mkdir -p "${parent}"
  stage="$(new_isolated_dir "${parent}/.stage-$(basename "${dest}")")"
  git init -q "${stage}"
  git -C "${stage}" remote add origin "${url}"
  git -C "${stage}" fetch -q --depth 1 origin "${commit}"
  git -C "${stage}" checkout -q FETCH_HEAD
  local got
  got="$(git -C "${stage}" rev-parse HEAD)"
  [[ "${got}" == "${commit}" ]] || die "checkout mismatch for ${dest}: ${got}"
  mv "${stage}" "${dest}"   # dest is guaranteed absent here
  say "checked out ${dest} @ ${commit}"
}

# --- cmake ------------------------------------------------------------------
say "fetch cmake ${CMAKE_VERSION}"
fetch_url "${CMAKE_URL}" \
          "${ENGINE_DOWNLOADS}/${CMAKE_TARBALL}" \
          "${CMAKE_SHA256}"
if [[ -x "${ENGINE_TOOLS}/cmake/CMake.app/Contents/bin/cmake" ]]; then
  localver="$("${ENGINE_TOOLS}/cmake/CMake.app/Contents/bin/cmake" --version | head -1)"
  case "${localver}" in
    *"${CMAKE_VERSION}"*) say "cmake already installed: ${localver}" ;;
    *) die "conflict: ${ENGINE_TOOLS}/cmake exists (${localver}), expected ${CMAKE_VERSION}." \
           "Nothing was deleted. Use ENGINE_WORK=<new dir> for an isolated fetch." ;;
  esac
else
  if [[ -e "${ENGINE_TOOLS}/cmake" ]]; then
    die "conflict: ${ENGINE_TOOLS}/cmake exists but is not a usable cmake ${CMAKE_VERSION}." \
        "Nothing was deleted. Use ENGINE_WORK=<new dir> for an isolated fetch."
  fi
  stage="$(new_isolated_dir "${ENGINE_TOOLS}/cmake-stage")"
  tar -xzf "${ENGINE_DOWNLOADS}/${CMAKE_TARBALL}" -C "${stage}"
  mv "${stage}/cmake-${CMAKE_VERSION}-macos-universal" "${ENGINE_TOOLS}/cmake"
fi
say "cmake ready: $("${ENGINE_TOOLS}/cmake/CMake.app/Contents/bin/cmake" --version | head -1)"

# --- librime ----------------------------------------------------------------
say "checkout librime @ ${LIBRIME_COMMIT}"
checkout_pinned "${LIBRIME_REPO}" "${LIBRIME_SRC}" "${LIBRIME_COMMIT}"

# --- librime third-party deps (as librime submodules, pinned) ---------------
say "checkout librime deps (glog leveldb marisa-trie opencc yaml-cpp)"
for spec in \
    "glog ${GLOG_COMMIT}" "leveldb ${LEVELDB_COMMIT}" \
    "marisa-trie ${MARISA_COMMIT}" "opencc ${OPENCC_COMMIT}" \
    "yaml-cpp ${YAMLCPP_COMMIT}"; do
  name="${spec%% *}"; want="${spec##* }"
  dep_dir="${LIBRIME_SRC}/deps/${name}"
  if [[ ! -d "${dep_dir}/.git" ]]; then
    say "initializing dep ${name}"
    git -C "${LIBRIME_SRC}" submodule update --init --depth 1 "deps/${name}"
  fi
  got="$(git -C "${dep_dir}" rev-parse HEAD 2>/dev/null || true)"
  [[ "${got}" == "${want}" ]] \
    || die "conflict: dep ${name} @ ${got:-<none>} != pinned ${want}. Nothing was deleted." \
           "Use ENGINE_WORK=<new dir> for an isolated fetch."
done
say "deps checkouts verified"

# --- boost ------------------------------------------------------------------
say "fetch boost ${BOOST_VERSION}"
# shellcheck disable=SC2153  # BOOST_URL is defined in VERSIONS.env
fetch_url "${BOOST_URL}" \
          "${ENGINE_DOWNLOADS}/${BOOST_TARBALL}" \
          "${BOOST_SHA256}"
if [[ -x "${BOOST_SRC}/bootstrap.sh" ]]; then
  say "boost source already present: ${BOOST_SRC}"
else
  if [[ -e "${BOOST_SRC}" ]]; then
    die "conflict: ${BOOST_SRC} exists but is not a usable boost source." \
        "Nothing was deleted. Use ENGINE_WORK=<new dir> for an isolated fetch."
  fi
  mkdir -p "${ENGINE_SRC}"
  stage="$(new_isolated_dir "${ENGINE_SRC}/boost-stage")"
  tar -xzf "${ENGINE_DOWNLOADS}/${BOOST_TARBALL}" -C "${stage}"
  mv "${stage}/boost_${BOOST_VERSION//./_}" "${BOOST_SRC}"
fi
say "boost source ready at ${BOOST_SRC}"

say "fetch phase complete"
say "artifacts:"
printf '  cmake     %s\n' "${ENGINE_TOOLS}/cmake"
printf '  librime   %s\n' "${LIBRIME_SRC}"
printf '  boost     %s\n' "${BOOST_SRC}"
