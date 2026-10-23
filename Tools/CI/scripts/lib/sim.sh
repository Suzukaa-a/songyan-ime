#!/usr/bin/env bash
# Resolve the dev simulator UDID by name (never from a shared file: several sessions
# share this checkout and a file would let one silently retarget another's simulator).
# Precedence: $UDID, else the available simulator named $SIM_NAME (default Songyan-Dev).
# Parallel runs should each use their own SIM_NAME.
resolve_sim_udid() {
  if [[ -n "${UDID:-}" ]]; then printf '%s' "${UDID}"; return; fi
  local name="${SIM_NAME:-Songyan-Dev}"
  xcrun simctl list devices available \
    | awk -v n="${name}" '$0 ~ "^ +"n" \\(" {match($0,/[0-9A-F-]{36}/); print substr($0,RSTART,RLENGTH); exit}'
}

# Bundle id and App Group of the staged host app, read from its built Info.plist so
# Config/Local.xcconfig overrides apply. Sets HOST_ID and GROUP_ID.
resolve_sim_identity() {
  local products="${CI_ROOT}/.local/dev-derived/Build/Products" config plist=""
  for config in "${CONFIGURATION:-Debug}" Debug Release; do
    plist="${products}/${config}-iphonesimulator/HostApp.app/Info.plist"
    [[ -f "${plist}" ]] && break
  done
  [[ -f "${plist}" ]] || { echo "no staged HostApp under ${products}; run make sim-stage first" >&2; return 1; }
  HOST_ID="$(plutil -extract CFBundleIdentifier raw -o - "${plist}")"
  GROUP_ID="$(plutil -extract SongyanAppGroup raw -o - "${plist}")"
}

# App Group container of the staged host app on simulator $1.
sim_group_container() {
  xcrun simctl get_app_container "$1" "${HOST_ID}" "${GROUP_ID}" 2>/dev/null
}
