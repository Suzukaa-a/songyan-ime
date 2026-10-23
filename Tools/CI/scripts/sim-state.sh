#!/usr/bin/env bash
# Print the Debug state snapshots (debug-state-*.json) written by the app / keyboard
# extension into the App Group container of the dev simulator. See DebugProbe.
# Usage: sim-state.sh   (simulator: $UDID, else $SIM_NAME, default Songyan-Dev)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/xcode.sh"
source "${SCRIPT_DIR}/lib/sim.sh"
require_xcode >/dev/null
UDID="$(resolve_sim_udid)"
[[ -n "${UDID}" ]] || { echo "no simulator named ${SIM_NAME:-Songyan-Dev}; run make sim-stage first" >&2; exit 1; }
resolve_sim_identity
GROUP="$(sim_group_container "${UDID}")"
[[ -n "${GROUP}" ]] || { echo "App Group container unavailable (not a sim-stage build?)" >&2; exit 1; }
shopt -s nullglob
files=("${GROUP}"/Library/Caches/debug-state-*.json)
((${#files[@]})) || { echo "no snapshot yet; open the keyboard in a text field first" >&2; exit 2; }
for f in "${files[@]}"; do echo "== $(basename "$f")"; cat "$f"; echo; done
