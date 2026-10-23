#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# opencc-dict-emulator.sh — CMAKE_CROSSCOMPILING_EMULATOR shim for OpenCC.
#
# 14-build-host-opencc.sh installs this file as
# <host prefix>/bin/opencc_dict-host, and 11-build-deps.sh passes that path as
# -DCMAKE_CROSSCOMPILING_EMULATOR while cross-building OpenCC for iOS.
#
# OpenCC's data step names the `opencc_dict` executable target, so CMake runs
#   <this wrapper> <cross-built opencc_dict> --input <dict.txt> --output <x.ocd2> ...
# The cross-built iOS binary cannot run here; drop it and run the host build
# next to this file, which produces identical .ocd2 data. Any other target is a
# wiring mistake and fails.
# ---------------------------------------------------------------------------
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "opencc_dict-host: expected <target path> then opencc_dict arguments, got $# argument(s)" >&2
  exit 64
fi

target="$1"
shift

case "$(basename "${target}")" in
  opencc_dict | opencc_dict.exe) ;;
  *)
    echo "opencc_dict-host: refusing to run for target '${target}': only opencc_dict may be replaced by the host tool" >&2
    exit 65
    ;;
esac

host_tool="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/opencc_dict"

if [[ ! -x "${host_tool}" ]]; then
  echo "opencc_dict-host: no host dictionary tool at ${host_tool}" >&2
  echo "opencc_dict-host: build it with Tools/BuildRimeIOS/scripts/14-build-host-opencc.sh" >&2
  exit 66
fi

exec "${host_tool}" "$@"
