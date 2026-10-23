#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 04-build-cli.sh — compile the minimal native engine driver rime_cli
# (Tools/BuildRime/cli/rime_cli.cc) against the static librime build.
#
# Output: ${ENGINE_BIN}/rime_cli   (documented as the engine test entry)
#
# macOS deployment target: passed to clang++ explicitly and exported by
# common.sh.
#
# Safety: no deletions. An existing rime_cli is skipped. Rebuilding over
# the default root requires ENGINE_WORK so existing binaries are never
# overwritten by this script.
# ---------------------------------------------------------------------------
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_librime
ensure_dirs

[[ -f "${ENGINE_PREFIX}/lib/librime.a" ]] \
  || die "librime.a missing; run scripts/02-build-deps.sh and 03-build-librime.sh first"

OUT="${ENGINE_BIN}/rime_cli"
SRC="${TOOLS_RIME_DIR}/cli/rime_cli.cc"

if [[ -x "${OUT}" ]]; then
  say "skip cli build (${OUT} present; use ENGINE_WORK for an isolated rebuild)"
  exit 0
fi

say "compile rime_cli (macOS deployment target ${MACOSX_DEPLOYMENT_TARGET})"
# Static link order matters: librime first, then its dependencies, then boost
# regex (the only compiled boost lib librime references).
clang++ -std=c++17 -O2 \
  -mmacosx-version-min="${MACOSX_DEPLOYMENT_TARGET}" \
  -I"${ENGINE_PREFIX}/include" \
  "${SRC}" \
  -o "${OUT}" \
  "${ENGINE_PREFIX}/lib/librime.a" \
  "${ENGINE_PREFIX}/lib/libglog.a" \
  "${ENGINE_PREFIX}/lib/libleveldb.a" \
  "${ENGINE_PREFIX}/lib/libmarisa.a" \
  "${ENGINE_PREFIX}/lib/libopencc.a" \
  "${ENGINE_PREFIX}/lib/libyaml-cpp.a" \
  "${BOOST_SRC}/stage/lib/libboost_regex.a" \
  -liconv \
  -lpthread

say "done: ${OUT}"
"${OUT}" --help >/dev/null 2>&1 || true
