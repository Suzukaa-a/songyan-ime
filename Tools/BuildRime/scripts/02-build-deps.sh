#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 02-build-deps.sh — build pinned third-party deps from source into the
# configured prefix (.local/engine/prefix, or ${ENGINE_WORK}/prefix).
# Nothing is installed system-wide.
#
#   * boost  : headers + static libboost_regex (only compiled boost lib the
#              engine references; remaining boost usage is header-only)
#   * glog, leveldb, marisa-trie, opencc, yaml-cpp : static libs
#     (recipes mirror librime's own deps.mk so behaviour matches upstream CI)
#
# marisa single-source contract: the shipped binary must contain only the
# marisa version its license notices declare. OpenCC is configured with
# USE_SYSTEM_MARISA=ON and compiles against the EXTERNAL marisa-trie 0.3.1 that
# was installed into the same prefix just above, so it neither builds nor
# installs its bundled `deps/marisa-0.2.6` archive and the prefix
# keeps exactly ONE libmarisa.a (the pinned marisa-trie 0.3.1) and librime +
# OpenCC share it at final link. OpenCC hardcodes -std=c++14; the 0.3.1
# headers compile under C++14 on Apple clang/libc++ (std::string_view is
# available as an extension; only benign "C++17 extension" warnings appear),
# so no extra -std flag is required. The prefix include dir must be added
# because OpenCC adds its marisa include path solely in the non-system branch.
#
# macOS deployment target: common.sh exports MACOSX_DEPLOYMENT_TARGET
# (=13.0 unless overridden) and every CMake/b2/clang invocation below also
# receives it explicitly.
#
# Safety: no deletions. A dependency already installed in the prefix is
# skipped. To rebuild, set ENGINE_WORK=<fresh dir> (isolated root) — or, when
# the artifact exists in the default root, FRESH=1 without ENGINE_WORK is
# refused with an error rather than overwriting existing artifacts.
# ---------------------------------------------------------------------------
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_cmake
require_librime
require_boost
ensure_dirs

# FRESH semantics: rebuilding over the default (non-isolated) root is refused
# so existing artifacts are never overwritten.
if [[ "${FRESH:-0}" == "1" && -z "${ENGINE_WORK:-}" ]]; then
  die "FRESH=1 with default engine root would overwrite existing artifacts." \
      "Set ENGINE_WORK=<fresh dir> for an isolated rebuild."
fi

cmake_build_install() { # $1 source-dir, then cmake args...
  local src="$1"; shift
  local bdir
  bdir="$(new_isolated_dir "${ENGINE_BUILD}/deps-$(basename "${src}")")"
  "${CMAKE}" -S "${src}" -B "${bdir}" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET:STRING="${MACOSX_DEPLOYMENT_TARGET}" "$@"
  "${CMAKE}" --build "${bdir}" --target install -j "${NPROC}"
}

# --- boost: headers + static regex ------------------------------------------
BOOST_REGEX_LIB="${BOOST_SRC}/stage/lib/libboost_regex.a"
if [[ -f "${BOOST_REGEX_LIB}" ]]; then
  say "boost regex already built: ${BOOST_REGEX_LIB}"
else
  say "boost: generate b2 + install headers + build static regex"
  cd "${BOOST_SRC}"
  [[ -x b2 ]] || ./bootstrap.sh --with-toolset=clang
  ./b2 -q headers || die "boost: b2 headers failed (rc=$?)"
  ./b2 -q -j "${NPROC}" --with-regex link=static \
       cxxflags="-std=c++17 -mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET}" stage \
    || die "boost: b2 regex stage failed (rc=$?)"
  [[ -f "${BOOST_REGEX_LIB}" ]] || die "boost_regex build produced no library at ${BOOST_REGEX_LIB}"
fi

# --- glog -------------------------------------------------------------------
if [[ -f "${ENGINE_PREFIX}/lib/libglog.a" ]]; then
  say "skip glog (already installed)"
else
  say "build glog"
  cmake_build_install "${LIBRIME_SRC}/deps/glog" \
    -DBUILD_SHARED_LIBS:BOOL=OFF \
    -DBUILD_TESTING:BOOL=OFF \
    -DWITH_GFLAGS:BOOL=OFF \
    -DCMAKE_BUILD_TYPE:STRING=Release \
    -DCMAKE_INSTALL_PREFIX:PATH="${ENGINE_PREFIX}"
fi

# --- leveldb -----------------------------------------------------------------
if [[ -f "${ENGINE_PREFIX}/lib/libleveldb.a" ]]; then
  say "skip leveldb (already installed)"
else
  say "build leveldb"
  cmake_build_install "${LIBRIME_SRC}/deps/leveldb" \
    -DLEVELDB_BUILD_BENCHMARKS:BOOL=OFF \
    -DLEVELDB_BUILD_TESTS:BOOL=OFF \
    -DCMAKE_BUILD_TYPE:STRING=Release \
    -DCMAKE_INSTALL_PREFIX:PATH="${ENGINE_PREFIX}"
fi

# --- marisa-trie -------------------------------------------------------------
if [[ -f "${ENGINE_PREFIX}/lib/libmarisa.a" ]]; then
  say "skip marisa-trie (already installed)"
else
  say "build marisa-trie"
  cmake_build_install "${LIBRIME_SRC}/deps/marisa-trie" \
    -DCMAKE_BUILD_TYPE:STRING=Release \
    -DCMAKE_INSTALL_PREFIX:PATH="${ENGINE_PREFIX}" \
    -DCMAKE_POSITION_INDEPENDENT_CODE:BOOL=ON \
    -DBUILD_TESTING:BOOL=OFF \
    -DENABLE_TOOLS:BOOL=OFF
fi

# --- opencc ------------------------------------------------------------------
# OpenCC must use the pinned EXTERNAL marisa-trie installed above
# (USE_SYSTEM_MARISA=ON), not its bundled deps/marisa-0.2.6: the bundled build
# installs its own libmarisa.a over the pinned 0.3.1 archive, leaving a
# "declared 0.3.1 / actual 0.2.6" mismatch in the final link that the license
# notices would not match.
# CMAKE_PREFIX_PATH makes find_library(marisa) resolve to ${ENGINE_PREFIX}/lib;
# CMAKE_CXX_FLAGS adds the 0.3.1 marisa.h include dir (system mode does not add
# any marisa include path itself). With USE_SYSTEM_MARISA=ON the install step
# emits libopencc.a only — marisa is never installed again.
if [[ -f "${ENGINE_PREFIX}/lib/libopencc.a" ]]; then
  say "skip opencc (already installed)"
else
  say "build opencc (USE_SYSTEM_MARISA -> pinned marisa-trie ${MARISA_COMMIT})"
  cmake_build_install "${LIBRIME_SRC}/deps/opencc" \
    -DBUILD_SHARED_LIBS:BOOL=OFF \
    -DCMAKE_BUILD_TYPE:STRING=Release \
    -DCMAKE_INSTALL_PREFIX:PATH="${ENGINE_PREFIX}" \
    -DCMAKE_PREFIX_PATH:PATH="${ENGINE_PREFIX}" \
    -DUSE_SYSTEM_MARISA:BOOL=ON \
    -DCMAKE_CXX_FLAGS:STRING="-I${ENGINE_PREFIX}/include"
fi

# --- yaml-cpp ----------------------------------------------------------------
if [[ -f "${ENGINE_PREFIX}/lib/libyaml-cpp.a" ]]; then
  say "skip yaml-cpp (already installed)"
else
  say "build yaml-cpp"
  cmake_build_install "${LIBRIME_SRC}/deps/yaml-cpp" \
    -DYAML_CPP_BUILD_CONTRIB:BOOL=OFF \
    -DYAML_CPP_BUILD_TESTS:BOOL=OFF \
    -DYAML_CPP_BUILD_TOOLS:BOOL=OFF \
    -DCMAKE_BUILD_TYPE:STRING=Release \
    -DCMAKE_INSTALL_PREFIX:PATH="${ENGINE_PREFIX}"
fi

say "verify installed static libs"
for lib in libglog.a libleveldb.a libmarisa.a libopencc.a libyaml-cpp.a; do
  [[ -f "${ENGINE_PREFIX}/lib/${lib}" ]] || die "missing ${ENGINE_PREFIX}/lib/${lib}"
done
for hdr in glog/logging.h leveldb/db.h marisa.h opencc/opencc.h yaml-cpp/yaml.h; do
  [[ -f "${ENGINE_PREFIX}/include/${hdr}" ]] || die "missing ${ENGINE_PREFIX}/include/${hdr}"
done
say "deps build complete"
