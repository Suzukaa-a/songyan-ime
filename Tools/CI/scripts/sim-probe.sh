#!/usr/bin/env bash
# Toggle a Debug-only keyboard probe on the dev simulator and restart the extension.
# Usage: sim-probe.sh <touch> <on|off>
#   touch  log every touch's hit routing (point, hit view type, nearby key frames, routed key)
#          as `debugProbe touch …` lines; read with `make sim-log CATEGORY=DebugProbe`.
# Probes are read once at extension launch, so the key path pays nothing when off.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/xcode.sh"
source "${SCRIPT_DIR}/lib/sim.sh"
[[ $# -eq 2 ]] || { echo "usage: sim-probe.sh <touch> <on|off>" >&2; exit 64; }
case "$1" in
  touch) KEY=debug.touchProbe ;;
  *) echo "unknown probe: $1 (known: touch)" >&2; exit 64 ;;
esac
require_xcode >/dev/null
UDID="$(resolve_sim_udid)"
[[ -n "${UDID}" ]] || { echo "no simulator named ${SIM_NAME:-Songyan-Dev}; run make sim-stage first" >&2; exit 1; }
resolve_sim_identity
GROUP="$(sim_group_container "${UDID}")"
[[ -n "${GROUP}" ]] || { echo "App Group container unavailable" >&2; exit 1; }
PLIST="${GROUP}/Library/Preferences/${GROUP_ID}.plist"
mkdir -p "$(dirname "${PLIST}")"
# Write through the simulator's own cfprefsd (a host-side `defaults write` edits the file
# behind a cached copy, so the extension would keep reading the old value).
case "$2" in
  on) xcrun simctl spawn "${UDID}" defaults write "${PLIST%.plist}" "${KEY}" -bool YES ;;
  off) xcrun simctl spawn "${UDID}" defaults delete "${PLIST%.plist}" "${KEY}" 2>/dev/null || true ;;
  *) echo "state must be on|off" >&2; exit 64 ;;
esac
xcrun simctl spawn "${UDID}" killall -u "$(id -u)" cfprefsd 2>/dev/null || true
# The extension ignores SIGTERM; only SIGKILL reliably restarts it.
pkill -9 -f "CoreSimulator/Devices/${UDID}/.*KeyboardExtension.appex" 2>/dev/null || true
echo "[probe] $1 $2 (extension restarts on next keyboard appearance)"
