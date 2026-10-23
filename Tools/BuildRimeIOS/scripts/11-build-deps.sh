#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 11-build-deps.sh — build the five pinned third-party deps plus the only
# compiled boost library (boost_regex) for BOTH iOS slices:
#   arm64 iOS Simulator -> prefix/sim-arm64
#   arm64 iOS device    -> prefix/device-arm64
#
# Sources are reused read-only from .local/engine/src/librime/deps/* (pinned
# commits verified by 10-verify-sources.sh). Everything is installed into the
# per-slice prefixes under .local/ios-engine/.
#
# Safety: no deletions. If a library already exists in the target prefix the
# dep is skipped. To rebuild, point IOS_ROOT at a fresh directory.
# ---------------------------------------------------------------------------
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/00-common.sh"

verify_pins

# Rewrite the checkout root in __FILE__ strings and debug info so the shipped
# archives carry no absolute build-machine paths.
PATH_MAP_FLAG="-ffile-prefix-map=${PROJECT_ROOT}=."

cmake_ios_dep() { # $1 name  $2 prefix  $3 sdk  $4 slice-label ... extra cmake args
  local name="$1" prefix="$2" sdk="$3" label="$4"; shift 4
  local lib=""
  case "${name}" in
    glog) lib="lib/libglog.a" ;;
    leveldb) lib="lib/libleveldb.a" ;;
    marisa-trie) lib="lib/libmarisa.a" ;;
    opencc) lib="lib/libopencc.a" ;;
    yaml-cpp) lib="lib/libyaml-cpp.a" ;;
    *) die "unknown dep ${name}" ;;
  esac
  if [[ -f "${prefix}/${lib}" ]]; then
    say "skip ${name} (${prefix}/${lib} present)"
    return
  fi
  local src="${DEP_SRC_ROOT}/${name}"
  local bdir
  bdir="$(new_isolated_dir "${BUILD_DIR_ROOT}/${label}/${name}")"
  local log
  log="$(logfile "deps-${name}" "${label}")"
  say "configure ${name} [${label}] -> ${prefix}"
  # OpenCC builds its .ocd2 data by running its own `opencc_dict` target, which
  # here is an iOS binary the build machine cannot execute. CMake prefixes that
  # command with CMAKE_CROSSCOMPILING_EMULATOR, which runs the pinned macOS host
  # tool instead (14-build-host-opencc.sh); the data is platform-independent.
  if [[ "${name}" == "opencc" ]]; then
    ensure_host_opencc_tool
    # OpenCC's bundled marisa-0.2.6 otherwise overwrites our pinned 0.3.1.
    # Configure against this slice's prefix from the outset: OpenCC freezes
    # DIR_PREFIX during configure, so an install-time --prefix is insufficient.
    # OpenCC bakes its install data dir into PKGDATADIR, which no prefix map
    # rewrites. A relative share dir keeps the install layout but drops the
    # absolute path; librime always passes OpenCC an absolute config path.
    set -- "$@" -DUSE_SYSTEM_MARISA:BOOL=ON \
      -DCMAKE_PREFIX_PATH:PATH="${prefix}" \
      -DLIBMARISA:FILEPATH="${prefix}/lib/libmarisa.a" \
      -DSHARE_INSTALL_PREFIX:STRING=share \
      -DCMAKE_CROSSCOMPILING_EMULATOR:FILEPATH="${HOST_OPENCC_EMULATOR}" \
      -DCMAKE_CXX_FLAGS:STRING="-I${prefix}/include ${PATH_MAP_FLAG}"
  else
    set -- "$@" -DCMAKE_CXX_FLAGS:STRING="${PATH_MAP_FLAG}"
  fi
  set -- "$@" -DCMAKE_C_FLAGS:STRING="${PATH_MAP_FLAG}"
  local marisa_before=""
  if [[ "${name}" == "opencc" ]]; then
    marisa_before="$(shasum -a 256 "${prefix}/lib/libmarisa.a")"
  fi
  local common
  read -ra common <<<"$(ios_cmake_common "${prefix}" "${sdk}")"
  "${CMAKE}" -S "${src}" -B "${bdir}" \
    "${common[@]}" "$@" >"${log}" 2>&1 \
    || { tail -40 "${log}" >&2; die "configure ${name} [${label}] failed (log ${log})"; }
  "${CMAKE}" --build "${bdir}" --target install -j "${NPROC}" >>"${log}" 2>&1 \
    || { tail -60 "${log}" >&2; die "build ${name} [${label}] failed (log ${log})"; }
  [[ -f "${prefix}/${lib}" ]] || die "${name} [${label}] produced no ${lib}"
  if [[ "${name}" == "opencc" ]]; then
    [[ "$(shasum -a 256 "${prefix}/lib/libmarisa.a")" == "${marisa_before}" ]] \
      || die "OpenCC replaced pinned marisa [${label}]"
    say "OpenCC preserved external marisa SHA-256 [${label}]: ${marisa_before}"
  fi
  say "ok ${name} [${label}]"
}

build_boost_regex_for() { # $1 prefix  $2 sdk  $3 target  $4 label
  local prefix="$1" sdk="$2" target="$3" label="$4"
  local out="${prefix}/lib/libboost_regex.a"
  [[ -f "${out}" ]] && { say "skip boost_regex (${out} present)"; return; }
  local log bdir
  log="$(logfile "boost-regex" "${label}")"
  bdir="$(new_isolated_dir "${BUILD_DIR_ROOT}/${label}/boost")"
  say "build boost_regex [${label}] (headers from ${BOOST_SRC})"
  "${CXX}" -std=c++17 -O2 -c "${PATH_MAP_FLAG}" \
    -I"${BOOST_SRC}" \
    -target "${target}" -isysroot "${sdk}" \
    "${BOOST_SRC}/libs/regex/src/posix_api.cpp" \
    -o "${bdir}/posix_api.o" >"${log}" 2>&1 \
    || { tail -40 "${log}" >&2; die "boost posix_api [${label}] failed"; }
  "${CXX}" -std=c++17 -O2 -c "${PATH_MAP_FLAG}" \
    -I"${BOOST_SRC}" \
    -target "${target}" -isysroot "${sdk}" \
    "${BOOST_SRC}/libs/regex/src/wide_posix_api.cpp" \
    -o "${bdir}/wide_posix_api.o" >>"${log}" 2>&1 \
    || { tail -40 "${log}" >&2; die "boost wide_posix_api [${label}] failed"; }
  "${AR}" crs "${out}" "${bdir}/posix_api.o" "${bdir}/wide_posix_api.o"
  "${RANLIB}" "${out}"
  say "ok boost_regex [${label}] -> ${out}"
}

# --- simulator slice ---------------------------------------------------------
say "building deps for iOS Simulator (arm64)"
for dep in "${RIME_DEPS[@]}"; do
  case "${dep}" in
    glog) cmake_ios_dep "${dep}" "${PREFIX_SIM}" "${SIM_SDK}" sim \
            -DBUILD_SHARED_LIBS:BOOL=OFF -DBUILD_TESTING:BOOL=OFF -DWITH_GFLAGS:BOOL=OFF ;;
    leveldb) cmake_ios_dep "${dep}" "${PREFIX_SIM}" "${SIM_SDK}" sim \
            -DLEVELDB_BUILD_BENCHMARKS:BOOL=OFF -DLEVELDB_BUILD_TESTS:BOOL=OFF ;;
    marisa-trie) cmake_ios_dep "${dep}" "${PREFIX_SIM}" "${SIM_SDK}" sim \
            -DCMAKE_POSITION_INDEPENDENT_CODE:BOOL=ON -DBUILD_TESTING:BOOL=OFF -DENABLE_TOOLS:BOOL=OFF ;;
    opencc) cmake_ios_dep "${dep}" "${PREFIX_SIM}" "${SIM_SDK}" sim \
            -DBUILD_SHARED_LIBS:BOOL=OFF -DCMAKE_MACOSX_BUNDLE:BOOL=OFF ;;
    yaml-cpp) cmake_ios_dep "${dep}" "${PREFIX_SIM}" "${SIM_SDK}" sim \
            -DYAML_CPP_BUILD_CONTRIB:BOOL=OFF -DYAML_CPP_BUILD_TESTS:BOOL=OFF -DYAML_CPP_BUILD_TOOLS:BOOL=OFF ;;
  esac
done
build_boost_regex_for "${PREFIX_SIM}" "${SIM_SDK}" "${SIM_TARGET}" sim

# --- device slice ------------------------------------------------------------
say "building deps for iOS device (arm64)"
for dep in "${RIME_DEPS[@]}"; do
  case "${dep}" in
    glog) cmake_ios_dep "${dep}" "${PREFIX_DEV}" "${DEV_SDK}" dev \
            -DBUILD_SHARED_LIBS:BOOL=OFF -DBUILD_TESTING:BOOL=OFF -DWITH_GFLAGS:BOOL=OFF ;;
    leveldb) cmake_ios_dep "${dep}" "${PREFIX_DEV}" "${DEV_SDK}" dev \
            -DLEVELDB_BUILD_BENCHMARKS:BOOL=OFF -DLEVELDB_BUILD_TESTS:BOOL=OFF ;;
    marisa-trie) cmake_ios_dep "${dep}" "${PREFIX_DEV}" "${DEV_SDK}" dev \
            -DCMAKE_POSITION_INDEPENDENT_CODE:BOOL=ON -DBUILD_TESTING:BOOL=OFF -DENABLE_TOOLS:BOOL=OFF ;;
    opencc) cmake_ios_dep "${dep}" "${PREFIX_DEV}" "${DEV_SDK}" dev \
            -DBUILD_SHARED_LIBS:BOOL=OFF -DCMAKE_MACOSX_BUNDLE:BOOL=OFF ;;
    yaml-cpp) cmake_ios_dep "${dep}" "${PREFIX_DEV}" "${DEV_SDK}" dev \
            -DYAML_CPP_BUILD_CONTRIB:BOOL=OFF -DYAML_CPP_BUILD_TESTS:BOOL=OFF -DYAML_CPP_BUILD_TOOLS:BOOL=OFF ;;
  esac
done
build_boost_regex_for "${PREFIX_DEV}" "${DEV_SDK}" "${DEV_TARGET}" dev

# --- verification ------------------------------------------------------------
for prefix in "${PREFIX_SIM}" "${PREFIX_DEV}"; do
  for lib in libglog.a libleveldb.a libmarisa.a libopencc.a libyaml-cpp.a libboost_regex.a; do
    [[ -f "${prefix}/lib/${lib}" ]] || die "missing ${prefix}/lib/${lib}"
  done
  verify_marisa_prefix "${prefix}"
done
for hdr in glog/logging.h leveldb/db.h marisa.h opencc/opencc.h yaml-cpp/yaml.h; do
  for prefix in "${PREFIX_SIM}" "${PREFIX_DEV}"; do
    [[ -f "${prefix}/include/${hdr}" ]] || die "missing header ${prefix}/include/${hdr}"
  done
done
say "iOS deps complete (sim + device)"
