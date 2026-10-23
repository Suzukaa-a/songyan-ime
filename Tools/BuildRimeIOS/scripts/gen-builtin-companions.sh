#!/usr/bin/env bash
# Regenerates the 14-, 18- and 9-key companions of the built-in schemes in
# Resources/BuiltinPackages/Basic with the app's own companion generator, from the
# real-engine source projections in Packages/PackageManager/Tests/PackageManagerTests/Fixtures.
# `swift test` in PackageManager fails while the bundled files are stale.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SONGYAN_WRITE_BUILTIN_COMPANIONS=1 swift test --package-path "${ROOT}/Packages/PackageManager" \
  --cache-path "${ROOT}/.local/swiftpm-cache" --filter BuiltinCompanionTests "$@"
