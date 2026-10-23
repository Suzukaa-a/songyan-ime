#!/usr/bin/env bash
# Stream (or dump) app + keyboard-extension logs from the dev simulator.
# Usage: sim-log.sh [--last <duration>] [category]   e.g. sim-log.sh --last 2m DebugProbe
# Default streams live. Simulator: $UDID, else the one named $SIM_NAME (default Songyan-Dev).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/xcode.sh"
source "${SCRIPT_DIR}/lib/sim.sh"
require_xcode >/dev/null
UDID="$(resolve_sim_udid)"
[[ -n "${UDID}" ]] || { echo "no simulator named ${SIM_NAME:-Songyan-Dev}; run make sim-stage first" >&2; exit 1; }
MODE=stream LAST=5m
if [[ "${1:-}" == --last ]]; then MODE=show; LAST="${2:?duration}"; shift 2; fi
PRED='subsystem == "app.songyan.ime"'
[[ -z "${1:-}" ]] || PRED="${PRED} AND category == \"$1\""
if [[ ${MODE} == show ]]; then
  exec xcrun simctl spawn "${UDID}" log show --last "${LAST}" --style compact --info --debug --predicate "${PRED}"
fi
exec xcrun simctl spawn "${UDID}" log stream --style compact --level debug --predicate "${PRED}"
