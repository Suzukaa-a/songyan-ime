#!/usr/bin/env bash
# Build a Debug HostApp+KeyboardExtension that is actually runnable on a Simulator
# (ad-hoc signed so App Group entitlements are embedded), install it on a dedicated
# Simulator, enable the keyboard, and skip onboarding.
#
# Why not the CI "unsigned" build: with CODE_SIGNING_ALLOWED=NO no entitlements are
# embedded, so containerURL(forSecurityApplicationGroupIdentifier:) is nil and the
# app/extension cannot share data. That is a packaging artifact, not a product bug.
#
# Usage: sim-stage.sh [--no-build] [--no-launch]
# Env:   SIM_NAME (default Songyan-Dev; give parallel runs distinct names), SIM_RUNTIME (default: newest iOS),
#        SIM_DEVICE_TYPE (default iPhone-17-Pro), DEVELOPER_DIR, SOURCE_PACKAGES_DIR (optional cache),
#        CONFIGURATION (default Debug; Release for performance measurement, no Debug probes).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/xcode.sh
source "${SCRIPT_DIR}/lib/xcode.sh"
# shellcheck source=lib/sim.sh
source "${SCRIPT_DIR}/lib/sim.sh"

BUILD=1 LAUNCH=1
for arg in "$@"; do
  case "${arg}" in
    --no-build) BUILD=0 ;;
    --no-launch) LAUNCH=0 ;;
    *) echo "usage: sim-stage.sh [--no-build] [--no-launch]" >&2; exit 64 ;;
  esac
done

SIM_NAME="${SIM_NAME:-Songyan-Dev}"
CONFIGURATION="${CONFIGURATION:-Debug}"
case "${CONFIGURATION}" in Debug|Release) ;; *) echo "CONFIGURATION must be Debug|Release" >&2; exit 64 ;; esac
DERIVED="${CI_ROOT}/.local/dev-derived"
APP="${DERIVED}/Build/Products/${CONFIGURATION}-iphonesimulator/HostApp.app"

require_xcode >/dev/null
XCRUN=(xcrun)
SIMCTL=("${XCRUN[@]}" simctl)

if ((BUILD)); then
  echo "[stage] building (ad-hoc signed, entitlements embedded)"
  mkdir -p "${DERIVED}"
  BUILD_HOME="${CI_ROOT}/.local/xcode-build-home"
  SWIFT_SANDBOX_OPTIONS=()
  mkdir -p "${BUILD_HOME}/Library/Preferences"
  if [[ "${CI_SWIFTPM_DISABLE_SANDBOX:-0}" == 1 ]]; then
    defaults write "${BUILD_HOME}/Library/Preferences/.GlobalPreferences" IDEPackageSupportDisableManifestSandbox -bool YES
    # shellcheck disable=SC2016  # $(inherited) is an Xcode build setting, not a shell expansion
    SWIFT_SANDBOX_OPTIONS=('OTHER_SWIFT_FLAGS=$(inherited) -disable-sandbox')
  else
    defaults write "${BUILD_HOME}/Library/Preferences/.GlobalPreferences" IDEPackageSupportDisableManifestSandbox -bool NO
  fi
  CFFIXED_USER_HOME="${BUILD_HOME}" \
  "${DEVELOPER_DIR}/usr/bin/xcodebuild" \
    -project "${CI_ROOT}/Songyan.xcodeproj" -scheme HostApp -configuration "${CONFIGURATION}" \
    -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "${DERIVED}" -jobs "${XCODE_BUILD_JOBS:-4}" \
    -packageCachePath "${CI_ROOT}/.local/xcode-package-cache" \
    -skipPackageUpdates -onlyUsePackageVersionsFromResolvedFile \
    -clonedSourcePackagesDirPath "${SOURCE_PACKAGES_DIR:-${DERIVED}/SourcePackages}" \
    CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO \
    ${SWIFT_SANDBOX_OPTIONS[@]+"${SWIFT_SANDBOX_OPTIONS[@]}"} \
    DEVELOPMENT_TEAM='' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build \
    > "${DERIVED}/xcodebuild.log" 2>&1 || { tail -40 "${DERIVED}/xcodebuild.log" >&2; exit 1; }
fi
[[ -d "${APP}" ]] || { echo "[stage] missing ${APP}; run without --no-build" >&2; exit 1; }
resolve_sim_identity
EXT_ID="$(plutil -extract CFBundleIdentifier raw -o - "${APP}/PlugIns/KeyboardExtension.appex/Info.plist")"

# Xcode puts Simulator entitlements in the Mach-O section, not the ad-hoc
# codesign blob. Decode that section as a plist; a group string elsewhere in
# the binary (for example RimePaths.swift) is not entitlement evidence.
for bundle in "${APP}/HostApp" "${APP}/PlugIns/KeyboardExtension.appex/KeyboardExtension"; do
  if ! otool -s __TEXT __entitlements "${bundle}" |
    awk '/^Contents of \(__TEXT,__entitlements\) section/ {found=1; next} found {for (i=2; i<=NF; i++) {w=$i; for (j=length(w)-1; j>=1; j-=2) printf "%s", substr(w,j,2)}}' |
    xxd -r -p | plutil -convert json -o - - |
    python3 -c 'import json,sys; groups=json.load(sys.stdin).get("com.apple.security.application-groups", []); sys.exit(0 if isinstance(groups,list) and sys.argv[1] in groups else 1)' "${GROUP_ID}"; then
    echo "[stage] ERROR: ${bundle} lacks embedded Simulator entitlement ${GROUP_ID}." >&2
    exit 1
  fi
done
echo "[stage] embedded entitlements verified for app and extension"

# Dedicated simulator only; never touch other sessions' simulators.
UDID="$("${SIMCTL[@]}" list devices available | awk -v n="${SIM_NAME}" '$0 ~ "^ +"n" \\(" {match($0,/[0-9A-F-]{36}/); print substr($0,RSTART,RLENGTH); exit}')"
if [[ -z "${UDID}" ]]; then
  RUNTIME="${SIM_RUNTIME:-$("${SIMCTL[@]}" list runtimes available | awk '/^iOS / {r=$NF} END{print r}')}"
  echo "[stage] creating simulator ${SIM_NAME} (${RUNTIME})"
  UDID="$("${SIMCTL[@]}" create "${SIM_NAME}" \
    "com.apple.CoreSimulator.SimDeviceType.${SIM_DEVICE_TYPE:-iPhone-17-Pro}" "${RUNTIME}")"
fi
echo "[stage] simulator ${SIM_NAME} ${UDID}"

state="$("${SIMCTL[@]}" list devices | grep "${UDID}" | sed -E 's/.*\(([A-Za-z]+)\)[[:space:]]*$/\1/')"
[[ "${state}" == Booted ]] || "${SIMCTL[@]}" boot "${UDID}"
"${SIMCTL[@]}" bootstatus "${UDID}" -b >/dev/null

"${SIMCTL[@]}" install "${UDID}" "${APP}"
if ! GROUP_PATH="$("${SIMCTL[@]}" get_app_container "${UDID}" "${HOST_ID}" "${GROUP_ID}")" ||
   [[ ! -d "${GROUP_PATH}" ]]; then
  echo "[stage] ERROR: installed HostApp has no ${GROUP_ID} container." >&2
  exit 1
fi
echo "[stage] installed App Group container verified"

# Enable the keyboard once; a reboot is required for AppleKeyboards to take effect.
if ! "${SIMCTL[@]}" spawn "${UDID}" defaults read -g AppleKeyboards 2>/dev/null | grep -q "${EXT_ID}"; then
  # Write the full list plus AppleKeyboardsExpanded: -array-add on a fresh simulator leaves
  # ours as the only entry and the globe picker then never lists it.
  "${SIMCTL[@]}" spawn "${UDID}" defaults write -g AppleKeyboards -array \
    "zh_Hans-Pinyin@sw=Pinyin-Simplified;hw=Automatic" "emoji@sw=Emoji" \
    "en_US@sw=QWERTY;hw=Automatic" "${EXT_ID}"
  "${SIMCTL[@]}" spawn "${UDID}" defaults write -g AppleKeyboardsExpanded -int 1
  echo "[stage] keyboard enabled; rebooting simulator"
  "${SIMCTL[@]}" shutdown "${UDID}"
  "${SIMCTL[@]}" boot "${UDID}"
  "${SIMCTL[@]}" bootstatus "${UDID}" -b >/dev/null
fi
"${SIMCTL[@]}" spawn "${UDID}" defaults write "${HOST_ID}" app.songyan.settings.onboardingCompleted -bool YES

if ((LAUNCH)); then
  "${SIMCTL[@]}" terminate "${UDID}" "${HOST_ID}" >/dev/null 2>&1 || true
  "${SIMCTL[@]}" launch "${UDID}" "${HOST_ID}" >/dev/null
  sleep 2
  if [[ "${CONFIGURATION}" == Release ]]; then
    echo "[stage] Release build: Debug runtime probe not available; skipped"
  elif "${XCRUN[@]}" simctl spawn "${UDID}" log show --last 30s --style compact \
      --predicate 'category == "DebugProbe"' 2>/dev/null | grep -q "role=hostApp.*appGroup=ok"; then
    echo "[stage] runtime probe: appGroup=ok"
  else
    echo "[stage] WARNING: runtime probe did not report appGroup=ok (see: make sim-log)" >&2
  fi
fi

echo "[stage] ready. UDID=${UDID}  logs: make sim-log"
