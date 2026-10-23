#!/usr/bin/env bash
# Link the shipped Simulator slice. No native-engine rebuild or Simulator UI.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
FRAMEWORKS="$ROOT/Packages/RimeBridge/Vendored/RimeKit.xcframework/ios-arm64-simulator"
ARCHIVE="$FRAMEWORKS/RimeKit.framework/RimeKit"
python3 - "$ARCHIVE" "$ROOT/Packages/RimeBridge/RimeKitArtifact.json" <<'PY'
import hashlib, json, pathlib, sys
with pathlib.Path(sys.argv[1]).open('rb') as source:
    actual = hashlib.file_digest(source, 'sha256').hexdigest()
expected = json.loads(pathlib.Path(sys.argv[2]).read_text())["slices"]["ios-arm64-simulator"]["sha256"]
if actual != expected:
    raise SystemExit("Simulator RimeKit does not match the checksum in RimeKitArtifact.json")
PY
RUN="$ROOT/.scratch/grammar-simulator/$(date -u +%Y%m%dT%H%M%SZ).$$"
mkdir -p "$RUN"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
# Learning bridge C adapter, compiled against the shipped framework's own
# public headers for the simulator slice (same ABI the SPM target uses).
python3 "$ROOT/Tools/BuildRimeIOS/scripts/build-learning-support.py" \
  --sdk "$SDK" --target arm64-apple-ios17.0-simulator \
  --kit-include-dir "$FRAMEWORKS/RimeKit.framework/Headers" \
  --output-dir "$RUN/learning-support" \
  --cc "xcrun --sdk iphonesimulator clang"
xcrun --sdk iphonesimulator swiftc -O -sdk "$SDK" -target arm64-apple-ios17.0-simulator \
  -F "$FRAMEWORKS" -module-cache-path "$RUN/module-cache" \
  -Xcc -fmodule-map-file="$RUN/learning-support/module/module.modulemap" \
  -I "$RUN/learning-support/module" \
  "$ROOT/Tools/BuildRimeIOS/harness-mac/grammar-development-main.swift" \
  "$ROOT/Packages/RimeBridge/Sources/RimeBridge/"*.swift \
  "$RUN/learning-support/RimeLeversSupport.o" \
  -Xlinker "$ARCHIVE" -Xlinker -lc++ -liconv -framework Foundation -framework CoreFoundation \
  -o "$RUN/grammar-harness"
codesign --force --sign - --timestamp=none "$RUN/grammar-harness"
printf '\nSimulator grammar harness: %s\n' "$RUN/grammar-harness"
