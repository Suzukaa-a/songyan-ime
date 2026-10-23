#!/usr/bin/env python3
"""Build (never launch) the persistent learning-backup probe.

Compiles the REAL production bridge (Packages/RimeBridge Swift sources, including
RimeLearningBackup.swift) plus its C dependency RimeLeversSupport
(same -fno-modules + original public header ABI the SPM target uses) against
the shipped Simulator RimeKit slice, together with the persistent harness main
Tools/BuildRimeIOS/harness-mac/learning-backup-main.swift.

Run the printed executable yourself (e.g. under simctl spawn with an explicit
UDID) with ONE argument: an absolute FRESH_SCRATCH_ROOT that is a brand-new
direct subdirectory of the repo's .scratch whose basename starts with
"learning-backup-". The main creates all fixtures from scratch; nothing here
prepares or inspects engine data, and no simulator is started by this script.
"""
import hashlib
import json
import os
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
frameworks = ROOT / "Packages/RimeBridge/Vendored/RimeKit.xcframework/ios-arm64-simulator"
archive = frameworks / "RimeKit.framework/RimeKit"
identity = json.loads((ROOT / "Packages/RimeBridge/RimeKitArtifact.json").read_text())
with archive.open("rb") as source:
    actual = hashlib.file_digest(source, "sha256").hexdigest()
if actual != identity["slices"]["ios-arm64-simulator"]["sha256"]:
    raise SystemExit("Simulator RimeKit does not match the checksum in RimeKitArtifact.json")
parent = ROOT / ".scratch" / "learning-backup"
parent.mkdir(parents=True, exist_ok=True)
output = Path(tempfile.mkdtemp(prefix="build-", dir=parent))
sources = sorted((ROOT / "Packages/RimeBridge/Sources/RimeBridge").glob("*.swift"))
main = ROOT / "Tools/BuildRimeIOS/harness-mac/learning-backup-main.swift"
if not main.is_file():
    raise SystemExit(f"persistent harness main missing: {main}")

environment = os.environ.copy()
if not environment.get("DEVELOPER_DIR") and environment.get("XCODE_DEV_DIR"):
    environment["DEVELOPER_DIR"] = environment["XCODE_DEV_DIR"]
sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"],
                              env=environment, text=True).strip()
# Same unified adapter step the other harnesses use (deterministic module map +
# object inside the run stage; copies only public headers into the scratch view).
support = output / "learning-support"
subprocess.run([
    "python3", str(ROOT / "Tools/BuildRimeIOS/scripts/build-learning-support.py"),
    "--sdk", sdk, "--target", "arm64-apple-ios17.0-simulator",
    "--kit-include-dir", str(frameworks / "RimeKit.framework/Headers"),
    "--output-dir", str(support),
    "--cc", "xcrun --sdk iphonesimulator clang",
], env=environment, check=True)
executable = output / "learning-backup"
subprocess.run([
    "xcrun", "--sdk", "iphonesimulator", "swiftc", "-swift-version", "5",
    "-sdk", sdk, "-target", "arm64-apple-ios17.0-simulator",
    "-F", str(frameworks), "-module-cache-path", str(output / "module-cache"),
    "-Xcc", f"-fmodule-map-file={support / 'module/module.modulemap'}",
    "-I", str(support / "module"),
    "-framework", "RimeKit", "-lc++", "-lz", "-liconv", "-lsqlite3",
    str(main),
    *map(str, sources),
    str(support / "RimeLeversSupport.o"), "-o", str(executable),
], env=environment, check=True)
subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none", str(executable)],
               check=True)
print(executable)
print(f'run: <simctl-spawn> "{executable}" <repo>/.scratch/learning-backup-<suffix>')
