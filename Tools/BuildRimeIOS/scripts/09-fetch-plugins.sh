#!/usr/bin/env bash
# Fetch the pinned plugin sources (librime-lua + Lua, librime-octagram,
# librime-predict) into the directory 43-build-rimekit.py reads them from.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/00-common.sh"
# shellcheck source=../LUA-VERSIONS.env
source "${IOS_TOOLS_DIR}/LUA-VERSIONS.env"
# shellcheck source=../GRAMMAR-VERSIONS.env
source "${IOS_TOOLS_DIR}/GRAMMAR-VERSIONS.env"
# shellcheck source=../PREDICT-VERSIONS.env
source "${IOS_TOOLS_DIR}/PREDICT-VERSIONS.env"
SOURCES="${PLUGIN_SOURCES_ROOT:-${IOS_ROOT}/plugin-sources}"
mkdir -p "${SOURCES}/src" "${SOURCES}/downloads"

fetch_pinned() { # $1 repository, $2 commit, $3 destination
  if [[ ! -e "$3" ]]; then
    git init "$3"
    git -C "$3" fetch --depth 1 "$1" "$2"
    git -C "$3" checkout --detach FETCH_HEAD
  fi
  [[ "$(git -C "$3" rev-parse HEAD)" == "$2" ]] || die "$(basename "$3") pin mismatch"
}

fetch_pinned https://github.com/hchunhui/librime-lua.git "$RIME_LUA_COMMIT" "${SOURCES}/src/librime-lua"
fetch_pinned "$OCTAGRAM_REPOSITORY" "$OCTAGRAM_COMMIT" "${SOURCES}/src/librime-octagram"
fetch_pinned "$PREDICT_REPOSITORY" "$PREDICT_COMMIT" "${SOURCES}/src/librime-predict"

ARCHIVE="${SOURCES}/downloads/lua-${LUA_VERSION}.tar.gz"
if [[ ! -e "$ARCHIVE" ]]; then
  curl --fail --location "https://www.lua.org/ftp/lua-${LUA_VERSION}.tar.gz" -o "$ARCHIVE"
fi
[[ "$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)" == "$LUA_SHA256" ]] || die "Lua checksum mismatch"
if [[ ! -e "${SOURCES}/src/lua-${LUA_VERSION}" ]]; then
  tar -xzf "$ARCHIVE" -C "${SOURCES}/src"
fi
say "plugin sources ready in ${SOURCES}/src"
