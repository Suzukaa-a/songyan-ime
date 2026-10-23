#!/usr/bin/env bash
# Package the Release device build from build-app.sh into an ad-hoc signed IPA.
# Ad-hoc signing carries the entitlements, so AltStore or Sideloadly can re-sign
# it under the installer's own team and keep the shared App Group.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

[[ $# -eq 1 ]] || { echo "usage: package-ipa.sh <output.ipa>" >&2; exit 64; }
OUTPUT="$1"
[[ ! -e "${OUTPUT}" ]] || { echo "refusing to overwrite ${OUTPUT}" >&2; exit 1; }

PRODUCT="${CI_OUTPUT_ROOT}/app-builds/Release-device/DerivedData/Build/Products/Release-iphoneos/HostApp.app"
[[ -x "${PRODUCT}/HostApp" && -x "${PRODUCT}/PlugIns/KeyboardExtension.appex/KeyboardExtension" ]] \
  || { echo "no Release device build; run build-app.sh Release device first" >&2; exit 1; }
# A local override would ship someone else's identity.
[[ ! -e "${CI_ROOT}/Config/Local.xcconfig" ]] \
  || { echo "Config/Local.xcconfig overrides the shipped identity" >&2; exit 1; }

STAGE="$(new_run_dir package-ipa)"
mkdir -p "${STAGE}/Payload"
ditto "${PRODUCT}" "${STAGE}/Payload/HostApp.app"
APP="${STAGE}/Payload/HostApp.app"

# codesign does not expand build settings, so resolve $(SONGYAN_APP_GROUP) first.
APP_GROUP_ID="$(sed -n 's/^SONGYAN_APP_GROUP *= *\([^ ]*\) *$/\1/p' "${CI_ROOT}/Config/Identity.xcconfig")"
[[ -n "${APP_GROUP_ID}" ]] || { echo "SONGYAN_APP_GROUP missing from Config/Identity.xcconfig" >&2; exit 1; }
for target in HostApp KeyboardExtension; do
  sed "s/\$(SONGYAN_APP_GROUP)/${APP_GROUP_ID}/g" \
    "${CI_ROOT}/Apps/${target}/${target}.entitlements" >"${STAGE}/${target}.entitlements"
done

# Inside out: nested frameworks, then the extension, then the app.
while IFS= read -r framework; do
  codesign --force --sign - --timestamp=none "${framework}"
done < <(find "${APP}" -type d -name '*.framework' -prune | sort)
codesign --force --sign - --timestamp=none \
  --entitlements "${STAGE}/KeyboardExtension.entitlements" "${APP}/PlugIns/KeyboardExtension.appex"
codesign --force --sign - --timestamp=none --entitlements "${STAGE}/HostApp.entitlements" "${APP}"
codesign --verify --deep --strict "${APP}"

mkdir -p "$(dirname "${OUTPUT}")"
ditto -c -k --sequesterRsrc --keepParent "${STAGE}/Payload" "${OUTPUT}"
printf '[CI] IPA: %s\n' "${OUTPUT}"
