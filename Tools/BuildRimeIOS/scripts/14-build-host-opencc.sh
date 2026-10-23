#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 14-build-host-opencc.sh — build the pinned macOS (host) OpenCC dictionary
# tool opencc_dict that the iOS dependency build needs on the build machine.
#
# OpenCC builds its .ocd2 dictionaries by running its own `opencc_dict`
# target, which under the iOS cross-configuration is an iOS binary the build
# machine cannot execute. 11-build-deps.sh passes the wrapper installed here
# (bin/opencc_dict-host) as CMAKE_CROSSCOMPILING_EMULATOR so the step runs this
# pinned host build instead; .ocd2 data is platform-independent.
#
# Builds only from the pinned Tools/BuildRime fetch (OpenCC, marisa-trie,
# cmake), needs no iOS SDK and no network, and never deletes: an existing
# prefix is reused only after it matches its recorded identity and passes a
# real conversion. 11-build-deps.sh runs it through ensure_host_opencc_tool.
#
# Environment (see scripts/lib/host-tools.sh)
#   IOS_ROOT                  output root, default <repo>/.local/ios-engine
#   ENGINE_WORK / HOST_ENGINE_ROOT
#                             pinned source root, default <repo>/.local/engine
#   HOST_OPENCC_PREFIX        host tool prefix override
# ---------------------------------------------------------------------------
set -euo pipefail

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/host-tools.sh
source "${_script_dir}/lib/host-tools.sh"
# shellcheck source=../../BuildRime/VERSIONS.env
source "${PROJECT_ROOT}/Tools/BuildRime/VERSIONS.env"

MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
export MACOSX_DEPLOYMENT_TARGET

say()  { printf '\n\033[1;36m[host-opencc] %s\033[0m\n' "$*"; }
die()  {
  local line
  for line in "$@"; do printf '\033[1;31m[host-opencc:error] %s\033[0m\n' "${line}" >&2; done
  exit 1
}
note() { printf '  %s\n' "$*"; }

usage() {
  cat <<'EOF'
14-build-host-opencc.sh — build the pinned macOS host OpenCC dictionary tool.

  (no arguments)     build into $HOST_OPENCC_PREFIX, then verify
  --check            verify an existing prefix, build nothing
  --help             this text

Environment:
  IOS_ROOT                  output root        (default <repo>/.local/ios-engine)
  ENGINE_WORK               pinned source root (default <repo>/.local/engine)
  HOST_ENGINE_ROOT          pinned source root override
  HOST_OPENCC_PREFIX        host tool prefix override
  MACOSX_DEPLOYMENT_TARGET  default 13.0
EOF
}

MODE=build
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) MODE=check ;;
    --help | -h) usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done

LOGS="${IOS_ROOT}/logs"

# --- pinned inputs ----------------------------------------------------------

pinned_opencc_version() {
  local file="${HOST_OPENCC_SRC}/CMakeLists.txt" major minor revision
  [[ -f "${file}" ]] || die "missing ${file}"
  major="$(sed -nE 's/^set *\(OPENCC_VERSION_MAJOR ([0-9]+)\).*/\1/p' "${file}" | head -1)"
  minor="$(sed -nE 's/^set *\(OPENCC_VERSION_MINOR ([0-9]+)\).*/\1/p' "${file}" | head -1)"
  revision="$(sed -nE 's/^set *\(OPENCC_VERSION_REVISION ([0-9]+)\).*/\1/p' "${file}" | head -1)"
  [[ -n "${major}" && -n "${minor}" && -n "${revision}" ]] \
    || die "cannot read the OpenCC version from ${file}"
  printf '%s.%s.%s' "${major}" "${minor}" "${revision}"
}

require_pinned_sources() {
  [[ -x "${HOST_CMAKE}" ]] || die "pinned cmake missing at ${HOST_CMAKE}" \
    "Run Tools/BuildRime/scripts/01-fetch.sh first, or point ENGINE_WORK/HOST_ENGINE_ROOT at an existing engine root."
  local cmake_version
  cmake_version="$("${HOST_CMAKE}" --version | head -1 | awk '{print $3}')"
  [[ "${cmake_version}" == "${CMAKE_VERSION}" ]] \
    || die "cmake ${cmake_version} != pinned ${CMAKE_VERSION}"
  local pair name want dir got
  for pair in "opencc:${OPENCC_COMMIT}" "marisa-trie:${MARISA_COMMIT}"; do
    name="${pair%%:*}"; want="${pair#*:}"; dir="${HOST_DEP_SRC_ROOT}/${name}"
    # Submodule checkouts carry a .git file, not a directory.
    [[ -e "${dir}/.git" ]] || die "pinned ${name} checkout missing at ${dir}" \
      "Run Tools/BuildRime/scripts/01-fetch.sh first, or point ENGINE_WORK/HOST_ENGINE_ROOT at an existing engine root."
    got="$(git -C "${dir}" rev-parse HEAD 2>/dev/null || true)"
    [[ "${got}" == "${want}" ]] || die "${name} HEAD ${got:-<none>} != pinned ${want}"
    [[ -z "$(git -C "${dir}" status --porcelain)" ]] \
      || die "${name} has local changes; the host data would not match the pinned sources"
  done
  HOST_OPENCC_VERSION_TEXT="$(pinned_opencc_version)"
  HOST_OPENCC_TREE="$(git -C "${HOST_OPENCC_SRC}" rev-parse 'HEAD^{tree}')"
  HOST_MARISA_TREE="$(git -C "${HOST_MARISA_SRC}" rev-parse 'HEAD^{tree}')"
  HOST_MARISA_VERSION="$(tr -d '[:space:]' < "${HOST_MARISA_SRC}/VERSION")"
  say "pinned inputs verified"
  note "opencc ${HOST_OPENCC_VERSION_TEXT} @ ${OPENCC_COMMIT} (tree ${HOST_OPENCC_TREE})"
  note "marisa-trie ${HOST_MARISA_VERSION} @ ${MARISA_COMMIT} (tree ${HOST_MARISA_TREE})"
  note "cmake ${CMAKE_VERSION}   sources ${HOST_DEP_SRC_ROOT}"
}

require_host_toolchain() {
  HOST_ARCH="$(uname -m)"
  HOST_CC="$(xcrun --find clang 2>/dev/null || true)"
  HOST_CXX="$(xcrun --find clang++ 2>/dev/null || true)"
  [[ -x "${HOST_CC}" && -x "${HOST_CXX}" ]] \
    || die "no macOS clang/clang++ found (xcrun --find clang); a host C++ compiler is required"
  HOST_OS_VERSION="$(sw_vers -productVersion)"
  HOST_OS_BUILD="$(sw_vers -buildVersion)"
  say "host toolchain"
  note "architecture ${HOST_ARCH}   macOS ${HOST_OS_VERSION} (${HOST_OS_BUILD})   deployment target ${MACOSX_DEPLOYMENT_TARGET}"
}

# --- binary inspection ------------------------------------------------------

binary_arches() { lipo -archs "$1" 2>/dev/null | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//'; }

# LC_BUILD_VERSION platform: 1 = macOS, 2 = iOS, 7 = iOS Simulator.
binary_platform() {
  local value
  value="$(otool -l "$1" 2>/dev/null | awk '/LC_BUILD_VERSION/{found=1} found && $1=="platform"{print $2; exit}')"
  [[ -n "${value}" ]] || return 1
  printf '%s' "${value}"
}

# --- recorded identity ------------------------------------------------------

shasum_of() { shasum -a 256 "$1" | awk '{print $1}'; }

collect_identity_facts() {
  ID_DICT_PLATFORM="$(binary_platform "${HOST_OPENCC_DICT}")" \
    || die "cannot read the Mach-O platform of ${HOST_OPENCC_DICT}"
  ID_DICT_ARCHS="$(binary_arches "${HOST_OPENCC_DICT}")"
}

# $1 = write | verify. The emulator wrapper is not recorded: verify_tool
# compares it with its repo source directly.
identity_tool() {
  export HOST_OPENCC_PREFIX HOST_OPENCC_IDENTITY HOST_OPENCC_VERSION_TEXT OPENCC_COMMIT \
    HOST_OPENCC_TREE HOST_MARISA_TREE HOST_MARISA_VERSION MARISA_COMMIT CMAKE_VERSION \
    HOST_ARCH MACOSX_DEPLOYMENT_TARGET \
    ID_DICT_PLATFORM ID_DICT_ARCHS
  python3 - "$1" <<'PY'
import hashlib, json, os, pathlib, re, sys

mode = sys.argv[1]
prefix = pathlib.Path(os.environ["HOST_OPENCC_PREFIX"])
identity_path = pathlib.Path(os.environ["HOST_OPENCC_IDENTITY"])


def env(name):
    value = os.environ.get(name)
    if not value:
        sys.exit("[host-opencc:error] internal: missing " + name)
    return value


def digest(path):
    return {"bytes": path.stat().st_size,
            "sha256": hashlib.file_digest(path.open("rb"), "sha256").hexdigest()}


ARTIFACTS = ("bin/opencc_dict", "bin/opencc",
             "lib/libopencc.a", "lib/libmarisa.a")
DIGEST_KEYS = {"bytes", "sha256"}

# Facts re-derived from the pinned sources and the host right now, so a reused
# prefix is rejected when the sources or the host architecture changed.
facts = {
    "formatVersion": 1,
    "kind": "macos-host-opencc-dictionary-tool",
    "pins": {
        "opencc": {"version": env("HOST_OPENCC_VERSION_TEXT"),
                   "commit": env("OPENCC_COMMIT"),
                   "tree": env("HOST_OPENCC_TREE")},
        "marisa": {"version": env("HOST_MARISA_VERSION"),
                   "commit": env("MARISA_COMMIT"),
                   "tree": env("HOST_MARISA_TREE")},
        "cmake": env("CMAKE_VERSION"),
    },
    # The OS and compiler versions are not pinned: .ocd2 output does not depend
    # on them, and pinning them would invalidate the prefix on every Xcode update.
    "host": {
        "arch": env("HOST_ARCH"),
        "deploymentTarget": env("MACOSX_DEPLOYMENT_TARGET"),
    },
    "openccDict": {"platform": int(env("ID_DICT_PLATFORM")), "arches": env("ID_DICT_ARCHS")},
}


def write_identity():
    payload = dict(facts)
    payload["artifacts"] = {name: digest(prefix / name) for name in ARTIFACTS}
    # Rename into place so an interrupted run never leaves a half-written identity.
    temporary = identity_path.with_name(identity_path.name + ".partial")
    temporary.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, identity_path)
    print("wrote " + str(identity_path))


def verify_identity():
    if not identity_path.is_file():
        sys.exit("[host-opencc:error] no recorded identity at " + str(identity_path))
    recorded = json.loads(identity_path.read_text(encoding="utf-8"))
    problems = []
    missing = sorted((set(facts) | {"artifacts"}) - set(recorded))
    unknown = sorted(set(recorded) - set(facts) - {"artifacts"})
    if missing:
        problems.append("recorded identity lacks " + ", ".join(missing))
    if unknown:
        problems.append("recorded identity has unexpected entries: " + ", ".join(unknown))
    for key in facts:
        if key in recorded and recorded[key] != facts[key]:
            problems.append("recorded " + key + " differs: " + repr(recorded[key]) + " != " + repr(facts[key]))
    # Recorded digests are compared with the files on disk, so a modified tool
    # or library is caught even when its platform and architecture look right.
    recorded_artifacts = recorded.get("artifacts")
    if not isinstance(recorded_artifacts, dict) or sorted(recorded_artifacts) != sorted(ARTIFACTS):
        problems.append("recorded artifacts are not exactly " + ", ".join(ARTIFACTS) +
                        " but " + repr(recorded_artifacts))
    else:
        for name in ARTIFACTS:
            want = recorded_artifacts[name]
            if (not isinstance(want, dict) or set(want) != DIGEST_KEYS
                    or not isinstance(want.get("bytes"), int) or want["bytes"] <= 0
                    or not isinstance(want.get("sha256"), str)
                    or not re.fullmatch(r"[0-9a-f]{64}", want["sha256"])):
                problems.append("recorded digest for " + name + " is malformed: " + repr(want))
                continue
            path = prefix / name
            if not path.is_file():
                problems.append("missing artifact " + name)
                continue
            got = digest(path)
            if got != want:
                problems.append("artifact " + name + " changed on disk (recorded " + str(want["bytes"]) +
                                " bytes/" + want["sha256"][:16] + "…, now " + str(got["bytes"]) +
                                " bytes/" + got["sha256"][:16] + "…)")
    if problems:
        for line in problems:
            print("[host-opencc:error] " + line, file=sys.stderr)
        raise SystemExit(1)
    print("identity matches: " + str(identity_path))


if mode == "write":
    write_identity()
    raise SystemExit(0)
verify_identity()
PY
}

# --- behavioural verification ----------------------------------------------

# Converts a text dictionary through the emulator wrapper (the command shape the
# CMake data step runs), round-trips it back to text with the tool directly, and
# converts sample text through the installed data set. Fixtures go to .scratch/.
verify_fixture_conversion() {
  local work fixture text_out
  mkdir -p "${PROJECT_ROOT}/.scratch"
  work="$(mktemp -d "${PROJECT_ROOT}/.scratch/host-opencc-verify.XXXXXX")"
  fixture="${work}/known.tsv"
  printf '汉字\t漢字\n会议\t會議\n简化\t簡化\n' > "${fixture}"

  "${HOST_OPENCC_EMULATOR}" "${HOST_OPENCC_DICT}" --input "${fixture}" \
    --output "${work}/known.ocd2" --from text --to ocd2
  [[ -s "${work}/known.ocd2" ]] || die "opencc_dict text->ocd2 produced no dictionary"
  "${HOST_OPENCC_DICT}" --input "${work}/known.ocd2" --output "${work}/roundtrip.tsv" --from ocd2 --to text
  cmp -s <(LC_ALL=C sort "${fixture}") <(LC_ALL=C sort "${work}/roundtrip.tsv") \
    || die "text->ocd2->text round trip changed the dictionary entries"

  printf '会议汉语简化\n' > "${work}/s2t-in.txt"
  "${HOST_OPENCC_PREFIX}/bin/opencc" -c "${HOST_OPENCC_PREFIX}/share/opencc/s2t.json" \
    -i "${work}/s2t-in.txt" -o "${work}/s2t-out.txt"
  text_out="$(cat "${work}/s2t-out.txt")"
  [[ "${text_out}" == "會議漢語簡化" ]] \
    || die "installed OpenCC data converted '会议汉语简化' to '${text_out}' instead of '會議漢語簡化'"
  note "fixture: dictionary round trip intact; s2t converted 会议汉语简化 -> ${text_out}"
}

verify_tool() {
  local version platform arches
  [[ -x "${HOST_OPENCC_DICT}" ]] || return 1
  arches="$(binary_arches "${HOST_OPENCC_DICT}")"
  [[ "${arches}" == *"${HOST_ARCH}"* ]] \
    || die "${HOST_OPENCC_DICT} is built for '${arches}', not host architecture '${HOST_ARCH}'"
  platform="$(binary_platform "${HOST_OPENCC_DICT}")" \
    || die "cannot read the Mach-O platform of ${HOST_OPENCC_DICT}"
  [[ "${platform}" == "1" ]] \
    || die "${HOST_OPENCC_DICT} targets platform ${platform} (2 = iOS, 7 = iOS Simulator); it must be a macOS binary"

  # Capture first, then match: under `set -o pipefail` a reader that exits early
  # would fail the pipeline with SIGPIPE and look like a tool defect.
  version="$("${HOST_OPENCC_DICT}" --version 2>&1 || true)"
  [[ "${version}" == *"${HOST_OPENCC_VERSION_TEXT}"* ]] \
    || die "opencc_dict --version reported '${version}', expected OpenCC ${HOST_OPENCC_VERSION_TEXT}"

  [[ -x "${HOST_OPENCC_EMULATOR}" ]] || die "emulator wrapper missing at ${HOST_OPENCC_EMULATOR}"
  cmp -s "${HOST_OPENCC_EMULATOR}" "${HOST_OPENCC_EMULATOR_SOURCE}" \
    || die "${HOST_OPENCC_EMULATOR} differs from ${HOST_OPENCC_EMULATOR_SOURCE}" \
      "Run ${HOST_OPENCC_SCRIPT} without --check to reinstall the wrapper."

  note "opencc_dict --version: ${version}"
  note "architecture: ${arches}   Mach-O platform 1 (macOS)"
  verify_fixture_conversion
}

# --- build ------------------------------------------------------------------

verify_no_bundled_marisa() {
  local matches
  matches="$(strings "${HOST_OPENCC_PREFIX}/lib/libopencc.a" "${HOST_OPENCC_PREFIX}/lib/libmarisa.a" 2>/dev/null \
    | grep -c 'marisa-0\.2\.6' || true)"
  [[ "${matches}" -eq 0 ]] || die "bundled marisa 0.2.6 leaked into the host prefix"
}

build_marisa_for_host() {
  if [[ -f "${HOST_OPENCC_PREFIX}/lib/libmarisa.a" ]]; then
    note "reuse ${HOST_OPENCC_PREFIX}/lib/libmarisa.a"
    return
  fi
  local log="${LOGS}/host-opencc-marisa.log" jobs
  jobs="${NPROC:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
  say "build marisa-trie ${HOST_MARISA_VERSION} for the host (static, no tools/tests)"
  "${HOST_CMAKE}" -S "${HOST_MARISA_SRC}" -B "${HOST_OPENCC_BUILD}/marisa" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="${HOST_OPENCC_PREFIX}" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET}" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_C_COMPILER="${HOST_CC}" -DCMAKE_CXX_COMPILER="${HOST_CXX}" \
    -DBUILD_TESTING=OFF -DENABLE_TOOLS=OFF -DENABLE_NATIVE_CODE=OFF \
    >"${log}" 2>&1 || { tail -30 "${log}" >&2; die "marisa-trie configure failed (log ${log})"; }
  "${HOST_CMAKE}" --build "${HOST_OPENCC_BUILD}/marisa" --target install -j "${jobs}" \
    >>"${log}" 2>&1 || { tail -30 "${log}" >&2; die "marisa-trie build failed (log ${log})"; }
  note "ok ${HOST_OPENCC_PREFIX}/lib/libmarisa.a"
}

build_opencc_for_host() {
  if [[ -x "${HOST_OPENCC_DICT}" && -f "${HOST_OPENCC_PREFIX}/lib/libopencc.a" ]]; then
    note "reuse ${HOST_OPENCC_DICT}"
    return
  fi
  local log="${LOGS}/host-opencc-opencc.log" jobs
  jobs="${NPROC:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
  say "build OpenCC ${HOST_OPENCC_VERSION_TEXT} tool for the host"
  "${HOST_CMAKE}" -S "${HOST_OPENCC_SRC}" -B "${HOST_OPENCC_BUILD}/opencc" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="${HOST_OPENCC_PREFIX}" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET}" \
    -DCMAKE_C_COMPILER="${HOST_CC}" -DCMAKE_CXX_COMPILER="${HOST_CXX}" \
    -DBUILD_SHARED_LIBS=OFF \
    -DUSE_SYSTEM_MARISA=ON \
    -DCMAKE_PREFIX_PATH="${HOST_OPENCC_PREFIX}" \
    -DLIBMARISA:FILEPATH="${HOST_OPENCC_PREFIX}/lib/libmarisa.a" \
    -DCMAKE_CXX_FLAGS:STRING="-I${HOST_OPENCC_PREFIX}/include" \
    -DBUILD_DOCUMENTATION=OFF -DENABLE_GTEST=OFF -DENABLE_BENCHMARK=OFF \
    -DBUILD_PYTHON=OFF -DBUILD_TESTING=OFF \
    >"${log}" 2>&1 || { tail -30 "${log}" >&2; die "OpenCC configure failed (log ${log})"; }
  "${HOST_CMAKE}" --build "${HOST_OPENCC_BUILD}/opencc" --target install -j "${jobs}" \
    >>"${log}" 2>&1 || { tail -40 "${log}" >&2; die "OpenCC build failed (log ${log})"; }
  verify_no_bundled_marisa
  note "ok ${HOST_OPENCC_DICT}"
}

install_emulator() {
  mkdir -p "${HOST_OPENCC_PREFIX}/bin"
  cp "${HOST_OPENCC_EMULATOR_SOURCE}" "${HOST_OPENCC_EMULATOR}"
  chmod 755 "${HOST_OPENCC_EMULATOR}"
  note "ok ${HOST_OPENCC_EMULATOR} (from ${HOST_OPENCC_EMULATOR_SOURCE})"
}

# --- main -------------------------------------------------------------------

mkdir -p "${LOGS}"

say "host OpenCC dictionary tool"
note "prefix ${HOST_OPENCC_PREFIX}"
note "build  ${HOST_OPENCC_BUILD}"
require_pinned_sources
require_host_toolchain

# A prefix that no longer matches its identity is never overwritten.
die_stale_identity() {
  die "${HOST_OPENCC_PREFIX} does not match its recorded identity (details above)" \
    "Rebuild into fresh directories: set HOST_OPENCC_PREFIX and HOST_OPENCC_BUILD to new paths (or IOS_ROOT to a new root), or remove ${HOST_OPENCC_PREFIX} and ${HOST_OPENCC_BUILD} yourself, then run ${HOST_OPENCC_SCRIPT} again."
}

if [[ "${MODE}" == "check" ]]; then
  [[ -x "${HOST_OPENCC_DICT}" ]] || die "no host opencc_dict at ${HOST_OPENCC_DICT}" \
    "Build it with ${HOST_OPENCC_SCRIPT}"
  verify_tool
  collect_identity_facts
  identity_tool verify || die_stale_identity
  say "ok (check only): ${HOST_OPENCC_DICT}"
  exit 0
fi

# A CMake cache under our own build root means this prefix came from an earlier
# run of this script (possibly interrupted before it recorded its identity).
own_build_tree() { [[ -f "${HOST_OPENCC_BUILD}/opencc/CMakeCache.txt" ]]; }

if [[ -x "${HOST_OPENCC_DICT}" && -f "${HOST_OPENCC_IDENTITY}" ]]; then
  say "existing host tool found; verifying instead of rebuilding"
  # The wrapper is copied from the repo, not built, so refresh it every run.
  install_emulator
  verify_tool
  collect_identity_facts
  identity_tool verify || die_stale_identity
  say "ok (reused): ${HOST_OPENCC_DICT}"
  note "sha256 $(shasum_of "${HOST_OPENCC_DICT}")"
  exit 0
fi

# Artifacts this script cannot account for are a conflict: never overwrite them.
if [[ -e "${HOST_OPENCC_DICT}" || -e "${HOST_OPENCC_PREFIX}/lib/libopencc.a" ]] && ! own_build_tree; then
  die "${HOST_OPENCC_PREFIX} holds OpenCC artifacts with no recorded identity and no build tree from this script" \
    "Point IOS_ROOT at a fresh directory (or remove that prefix deliberately) and run this script again."
fi
if [[ -x "${HOST_OPENCC_DICT}" ]]; then
  say "completing a host tool left by an interrupted run"
fi

# Each step reuses what an interrupted run already installed; the identity is
# recorded only after the tool passes its behavioural checks.
mkdir -p "${HOST_OPENCC_PREFIX}/lib" "${HOST_OPENCC_PREFIX}/bin" "${HOST_OPENCC_BUILD}"
build_marisa_for_host
build_opencc_for_host
install_emulator
verify_tool
collect_identity_facts
identity_tool write

say "ok ${HOST_OPENCC_DICT}"
note "sha256 $(shasum_of "${HOST_OPENCC_DICT}")"
note "identity ${HOST_OPENCC_IDENTITY}"
note "emulator ${HOST_OPENCC_EMULATOR}"
