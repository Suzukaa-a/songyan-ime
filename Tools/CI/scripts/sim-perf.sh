#!/usr/bin/env bash
# Measure the real keyboard extension on the dev simulator (see DEBUG.md).
#
# Usage: sim-perf.sh typing [label]   Time Profiler + os_signpost while typing a fixed pinyin
#                                     fixture; prints ms/key on the main thread and UIKit
#                                     update-cycle p50/p95 (lib/perf_trace.py).
#        sim-perf.sh cold [runs]      Relaunch Host -> 试打 -> focus the field N times and print
#                                     the extension's launch/appearance/engineReady timeline.
#
# Preconditions: a signed stage (`make sim-stage`, `CONFIGURATION=Release` for numbers that
# matter), Songyan selected as the current keyboard in 试打, offline built-in 26-key full pinyin, iPhone 17 Pro
# geometry (402pt wide; key coordinates below are that fixture only). Typing uses one
# `axe touch --down --up` per key; output goes to .scratch/perf-<mode>-<stamp>/.
# The fixture text is fixed pinyin, never user input.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/xcode.sh"
source "${SCRIPT_DIR}/lib/sim.sh"
MODE="${1:-typing}"
require_xcode >/dev/null
UDID="$(resolve_sim_udid)"
[[ -n "${UDID}" ]] || { echo "no simulator named ${SIM_NAME:-Songyan-Dev}; run make sim-stage first" >&2; exit 1; }
command -v axe >/dev/null || { echo "axe is required (see DEBUG.md, Setup)" >&2; exit 1; }
resolve_sim_identity
OUT="${CI_ROOT}/.scratch/perf-${MODE}-$(date +%Y%m%dT%H%M%S)"
mkdir -p "${OUT}"

ext_pid() { pgrep -f "${UDID}.*KeyboardExtension.appex/KeyboardExtension" | head -1 || true; }

key_point() {
  case "$1" in
    q) echo "21 594";; w) echo "62 594";; e) echo "101 594";; r) echo "141 594";; t) echo "181 594";;
    y) echo "221 594";; u) echo "261 594";; i) echo "300 594";; o) echo "340 594";; p) echo "380 594";;
    a) echo "40 652";; s) echo "81 652";; d) echo "121 652";; f) echo "161 652";; g) echo "201 652";;
    h) echo "241 652";; j) echo "281 652";; k) echo "321 652";; l) echo "362 652";;
    z) echo "90 710";; x) echo "127 710";; c) echo "164 710";; v) echo "201 710";; b) echo "238 710";;
    n) echo "275 710";; m) echo "312 710";; _) echo "201 768";;
    *) echo "unsupported fixture key: $1" >&2; return 1;;
  esac
}

type_words() {  # "_" is the space bar
  local word ch x y i
  for word in "$@"; do
    for ((i = 0; i < ${#word}; i++)); do
      ch="${word:i:1}"
      read -r x y < <(key_point "${ch}")
      axe touch --udid "${UDID}" -x "${x}" -y "${y}" --down --up --delay 0.05 >/dev/null 2>&1
      sleep "${KEY_GAP:-0.25}"
    done
  done
}

case "${MODE}" in
  typing)
    LABEL="${2:-run}"
    [[ -n "$(ext_pid)" ]] || { echo "keyboard extension not running; open 试打 with Songyan first" >&2; exit 1; }
    WORDS=(nihao_ zhongguo_ women_ henhao_ xiexie_ pengyou_ nihao_ zhongguo_)
    KEYS=0; for w in "${WORDS[@]}"; do KEYS=$((KEYS + ${#w})); done
    type_words nihao_ women_   # warm-up: first-use costs are a separate (cold) question
    sleep 1
    TRACE="${OUT}/${LABEL}.trace"
    xcrun xctrace record --device "${UDID}" --template "Time Profiler" --instrument os_signpost \
      --attach KeyboardExtension --time-limit "${TRACE_SECONDS:-65}s" --output "${TRACE}" \
      > "${OUT}/xctrace.log" 2>&1 &
    RECORDER=$!
    sleep 8
    type_words "${WORDS[@]}"
    wait "${RECORDER}" || true
    [[ -d "${TRACE}" ]] || { cat "${OUT}/xctrace.log" >&2; exit 1; }
    xcrun xctrace export --input "${TRACE}" --xpath \
      '/trace-toc/run[@number="1"]/data/table[@schema="os-signpost" and @target-pid="SINGLE" and not(@category) and not(@subsystem)]' \
      > "${OUT}/signposts.xml"
    xcrun xctrace export --input "${TRACE}" --xpath \
      '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' > "${OUT}/profile.xml"
    python3 -I "${SCRIPT_DIR}/lib/perf_trace.py" "${OUT}/signposts.xml" "${OUT}/profile.xml" "${KEYS}" \
      | tee "${OUT}/summary.txt"
    ;;
  cold)
    RUNS="${2:-3}"
    # Release builds only emit lifecycle lines with the shared diagnostics switch on.
    GROUP="$(sim_group_container "${UDID}")"
    [[ -n "${GROUP}" ]] && xcrun simctl spawn "${UDID}" defaults write \
      "${GROUP}/Library/Preferences/${GROUP_ID}" keyboard.lifecycleDiagnosticsEnabled -bool YES
    for ((run = 1; run <= RUNS; run++)); do
      xcrun simctl terminate "${UDID}" "${HOST_ID}" >/dev/null 2>&1 || true
      pid="$(ext_pid)"; [[ -n "${pid}" ]] && kill "${pid}" 2>/dev/null || true
      sleep 1.5
      xcrun simctl launch "${UDID}" "${HOST_ID}" >/dev/null; sleep 3
      axe tap --udid "${UDID}" --label 试打 --tap-style physical >/dev/null; sleep 2
      axe tap --udid "${UDID}" -x 201 -y 400 --tap-style physical >/dev/null; sleep 4
      pid="$(ext_pid)"
      echo "run ${run} pid ${pid:-none}" | tee -a "${OUT}/cold.txt"
      [[ -n "${pid}" ]] || continue
      xcrun simctl spawn "${UDID}" log show --last 15s --style compact --info --predicate "processID == ${pid}" \
        2>/dev/null | grep -E "Hello, I'm launching|Prepare received|event=(viewWillAppear|viewDidAppear|engineReady)|slowEngineOp" \
        | sed -E 's/^[0-9-]+ //; s/KeyboardExtension\[[^]]*\] //' | cut -c1-220 | tee -a "${OUT}/cold.txt"
    done
    ;;
  *) echo "usage: sim-perf.sh typing [label] | cold [runs]" >&2; exit 64 ;;
esac
echo "[perf] artifacts: ${OUT}"
