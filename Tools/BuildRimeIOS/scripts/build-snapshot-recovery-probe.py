#!/usr/bin/env python3
"""Build (never launch) a production real-engine simulator probe.

Without arguments it builds the snapshot-failure probe: run the printed executable
with simctl spawn <explicit-UDID> and arguments <built-in package>
<fresh-user-directory> <deployed-build-or-dash>. A dash deploys the built-in package
into the fresh user directory. `exact-letter` builds the merged-key exact-pick probe
instead, run with <built-in package> <fresh-user-directory>. All outputs are scratch;
Xcode selection uses DEVELOPER_DIR, then XCODE_DEV_DIR, then the system xcode-select
setting.
"""
import hashlib
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PROBE = sys.argv[1] if len(sys.argv) > 1 else "snapshot-recovery"
if PROBE not in ("snapshot-recovery", "exact-letter"):
    raise SystemExit(f"unknown probe: {PROBE}")
frameworks = ROOT / "Packages/RimeBridge/Vendored/RimeKit.xcframework/ios-arm64-simulator"
archive = frameworks / "RimeKit.framework/RimeKit"
identity = json.loads((ROOT / "Packages/RimeBridge/RimeKitArtifact.json").read_text())
with archive.open("rb") as source:
    actual = hashlib.file_digest(source, "sha256").hexdigest()
if actual != identity["slices"]["ios-arm64-simulator"]["sha256"]:
    raise SystemExit("Simulator RimeKit does not match the checksum in RimeKitArtifact.json")
parent = ROOT / ".scratch" / PROBE
parent.mkdir(parents=True, exist_ok=True)
output = Path(tempfile.mkdtemp(prefix="build-", dir=parent))
stage = output / "swift"
stage.mkdir()
sources = [
    *sorted((ROOT / "Packages/KeyboardCore/Sources/KeyboardCore").rglob("*.swift")),
    *sorted((ROOT / "Packages/RimeBridge/Sources/RimeBridge").glob("*.swift")),
    ROOT / "Apps/SharedKeyboard/RimeBackend.swift",
    ROOT / "Apps/SharedKeyboard/OptionStore.swift",
]
for source in sources:
    text = source.read_text().replace("import KeyboardCore\n", "").replace("import RimeBridge\n", "")
    (stage / source.name).write_text(text)
(stage / "HarnessStubs.swift").write_text("""import Foundation
public enum EngineOpQueue {
    public static func sync<T>(_ body: () throws -> T) throws -> T { try body() }
    public static func async<T>(_ body: @escaping () throws -> T) async throws -> T { try body() }
}
public enum GrammarRuntimeReceiptStore {
    public struct Context {}
    public static func record(context: Context, sourceSchemaID: String,
                              runtimeSchemaID: String, loadedLanguage: String?) throws {}
}
""")
environment = os.environ.copy()
if not environment.get("DEVELOPER_DIR") and environment.get("XCODE_DEV_DIR"):
    environment["DEVELOPER_DIR"] = environment["XCODE_DEV_DIR"]
sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], env=environment, text=True).strip()
# The learning bridge C target (RimeLeversSupport) is a real SPM dependency of
# RimeBridge; compile it for the simulator slice like the package would.
support = output / "learning-support"
subprocess.run([
    "python3", str(ROOT / "Tools/BuildRimeIOS/scripts/build-learning-support.py"),
    "--sdk", sdk, "--target", "arm64-apple-ios17.0-simulator",
    "--kit-include-dir", str(frameworks / "RimeKit.framework/Headers"),
    "--output-dir", str(support),
    "--cc", "xcrun --sdk iphonesimulator clang",
], env=environment, check=True)
executable = output / PROBE
subprocess.run([
    "xcrun", "--sdk", "iphonesimulator", "swiftc", "-swift-version", "5",
    "-D", "SONGYAN_TEST_FAILPOINTS", "-sdk", sdk, "-target", "arm64-apple-ios17.0-simulator",
    "-F", str(frameworks), "-module-cache-path", str(output / "module-cache"),
    "-Xcc", f"-fmodule-map-file={support}/module/module.modulemap",
    "-I", str(support / "module"),
    "-framework", "RimeKit", "-lc++", "-lz", "-liconv", "-lsqlite3",
    str(ROOT / f"Tools/BuildRimeIOS/harness-mac/{PROBE}-main.swift"),
    *map(str, sorted(stage.glob("*.swift"))),
    str(support / "RimeLeversSupport.o"), "-o", str(executable),
], env=environment, check=True)
subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none", str(executable)], check=True)
print(executable)
