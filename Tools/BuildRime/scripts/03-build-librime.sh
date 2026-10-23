#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 03-build-librime.sh — configure + build librime (static) into the configured
# prefix, pinned at LIBRIME_COMMIT, against the local static deps.
#
# Static build mirrors how the engine is expected to be embedded later
# (single archive, no dylib chasing); BUILD_SHARED_LIBS=ON is a documented
# alternative for dylib consumers.
#
# macOS deployment target is exported by common.sh and also passed to
# CMake explicitly.
#
# Safety: no deletions. Rebuilds always use a fresh, isolated build
# directory. An existing librime.a is skipped; rebuilding over the default
# root requires ENGINE_WORK (never overwrite existing artifacts).
# ---------------------------------------------------------------------------
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_cmake
require_librime
require_boost
ensure_dirs

if [[ "${FRESH:-0}" == "1" && -z "${ENGINE_WORK:-}" ]]; then
  die "FRESH=1 with default engine root would overwrite existing artifacts." \
      "Set ENGINE_WORK=<fresh dir> for an isolated rebuild."
fi

RIME_BUILD_DIR="$(new_isolated_dir "${ENGINE_BUILD}/librime-static")"

if [[ -f "${ENGINE_PREFIX}/lib/librime.a" ]]; then
  say "skip librime build (${ENGINE_PREFIX}/lib/librime.a present; use ENGINE_WORK for an isolated rebuild)"
  exit 0
fi

say "configure librime (static) @ ${LIBRIME_COMMIT}"
"${CMAKE}" -S "${LIBRIME_SRC}" -B "${RIME_BUILD_DIR}" \
  -DCMAKE_BUILD_TYPE:STRING=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET:STRING="${MACOSX_DEPLOYMENT_TARGET}" \
  -DCMAKE_INSTALL_PREFIX:PATH="${ENGINE_PREFIX}" \
  -DCMAKE_PREFIX_PATH:PATH="${ENGINE_PREFIX}" \
  -DBOOST_ROOT:PATH="${BOOST_SRC}" \
  -DBoost_INCLUDE_DIR:PATH="${BOOST_SRC}" \
  -DBUILD_SHARED_LIBS:BOOL=OFF \
  -DBUILD_STATIC:BOOL=ON \
  -DBUILD_TEST:BOOL=OFF \
  -DBUILD_SAMPLE:BOOL=OFF \
  -DBUILD_DATA:BOOL=OFF \
  -DBUILD_MERGED_PLUGINS:BOOL=OFF \
  -DENABLE_EXTERNAL_PLUGINS:BOOL=OFF \
  -DENABLE_LOGGING:BOOL=ON

say "build + install librime"
"${CMAKE}" --build "${RIME_BUILD_DIR}" --target install -j "${NPROC}"

[[ -f "${ENGINE_PREFIX}/lib/librime.a" ]] || die "librime.a not produced"
[[ -f "${ENGINE_PREFIX}/include/rime_api.h" ]] || die "rime_api.h not installed"
say "librime installed:"
printf '  lib     %s\n' "${ENGINE_PREFIX}/lib/librime.a"
printf '  headers %s/include/rime_api.h\n' "${ENGINE_PREFIX}"
