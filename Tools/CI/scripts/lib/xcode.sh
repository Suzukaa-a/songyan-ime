#!/usr/bin/env bash
set -euo pipefail

require_xcode() {
  if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    DEVELOPER_DIR="$(xcode-select -p 2>/dev/null || true)"
  fi
  # xcode-select often points at CommandLineTools; fall back to an installed Xcode.
  if [[ ! -x "${DEVELOPER_DIR:-}/usr/bin/xcodebuild" ]]; then
    local app
    for app in /Applications/Xcode.app /Applications/Xcode-beta.app /Applications/Xcode*.app; do
      if [[ -x "${app}/Contents/Developer/usr/bin/xcodebuild" ]]; then
        DEVELOPER_DIR="${app}/Contents/Developer"
        break
      fi
    done
  fi
  if [[ ! -x "${DEVELOPER_DIR:-}/usr/bin/xcodebuild" ]]; then
    printf 'A full Xcode is required. Set DEVELOPER_DIR explicitly.\n' >&2
    return 1
  fi
  export DEVELOPER_DIR
  export XCODE_DEV_DIR="${DEVELOPER_DIR}"
  "${DEVELOPER_DIR}/usr/bin/xcodebuild" -version
  xcrun --sdk iphoneos --show-sdk-version
  xcrun --sdk iphonesimulator --show-sdk-version
}
