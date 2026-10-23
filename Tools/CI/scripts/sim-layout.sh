#!/usr/bin/env bash
# Force the keyboard extension's startup layout on the dev simulator (Debug builds only).
# Usage: sim-layout.sh <qwerty26|merged14|merged18|phone9|clear>
# Writes debug.layoutOverride into the App Group defaults and restarts the extension.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/xcode.sh"
source "${SCRIPT_DIR}/lib/sim.sh"
[[ $# -eq 1 ]] || { echo "usage: sim-layout.sh <layout|clear>" >&2; exit 64; }
require_xcode >/dev/null
UDID="$(resolve_sim_udid)"
[[ -n "${UDID}" ]] || { echo "no simulator named ${SIM_NAME:-Songyan-Dev}; run make sim-stage first" >&2; exit 1; }
resolve_sim_identity
GROUP="$(sim_group_container "${UDID}")"
[[ -n "${GROUP}" ]] || { echo "App Group container unavailable" >&2; exit 1; }
PLIST="${GROUP}/Library/Preferences/${GROUP_ID}.plist"
mkdir -p "$(dirname "${PLIST}")"
# Write through the simulator's own cfprefsd (see sim-probe.sh): a host-side write is hidden by its cache.
if [[ "$1" == clear ]]; then
  xcrun simctl spawn "${UDID}" defaults delete "${PLIST%.plist}" debug.layoutOverride 2>/dev/null || true
else
  xcrun simctl spawn "${UDID}" defaults write "${PLIST%.plist}" debug.layoutOverride -string "$1"
fi
# cfprefsd caches; restart only this simulator's extension process.
xcrun simctl spawn "${UDID}" killall -u "$(id -u)" cfprefsd 2>/dev/null || true
# Host-side and scoped to this simulator's path so other simulators are never touched.
# The extension ignores SIGTERM; only SIGKILL reliably restarts it.
pkill -9 -f "CoreSimulator/Devices/${UDID}/.*KeyboardExtension.appex" 2>/dev/null || true
echo "[layout] $1 (extension restarts on next keyboard appearance)"
