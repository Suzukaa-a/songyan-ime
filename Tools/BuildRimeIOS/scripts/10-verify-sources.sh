#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 10-verify-sources.sh — verify the read-only pinned sources exist and are at
# the pinned commits. No downloads, no writes outside logs.
# ---------------------------------------------------------------------------
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/00-common.sh"

verify_pins

say "iOS build environment"
printf '  Xcode          %s\n' "$(xcodebuild -version | head -1)"
printf '  sim SDK        %s (%s)\n' "${SIM_SDK_VERSION}" "${SIM_SDK}"
printf '  device SDK     %s (%s)\n' "${DEV_SDK_VERSION}" "${DEV_SDK}"
printf '  deployment     iOS %s\n' "${IOS_DEPLOYMENT_TARGET}"
printf '  output root    %s\n' "${IOS_ROOT}"
printf '  cmake          %s\n' "$("${CMAKE}" --version | head -1)"
say "ok"
