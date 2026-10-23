#!/usr/bin/env python3
"""Compile, never launch, the real full-framework public levers IO probe."""
import argparse
import hashlib
import json
import os
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]


def sha(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--candidate-root", type=Path, required=True)
    args = parser.parse_args()
    candidate = args.candidate_root.absolute()
    allowed = ROOT / ".local/ios-engine"
    if candidate.parent != allowed or candidate.resolve() != candidate:
        raise SystemExit("candidate must be a build directory directly under .local/ios-engine")
    slice_name = "ios-arm64-simulator"
    framework = candidate / "out/RimeKit.xcframework" / slice_name
    archive = framework / "RimeKit.framework/RimeKit"
    identity = sha(archive)
    include = candidate / "prefix/sim-arm64/include"
    for name in ("rime_api.h", "rime_levers_api.h"):
        if not (include / name).is_file():
            raise SystemExit("candidate original public header missing: " + name)
    source = ROOT / "Tools/BuildRimeIOS/harness-mac/learning-engine-io-main.cc"
    environment = os.environ.copy()
    environment.setdefault("DEVELOPER_DIR", environment.get("XCODE_DEV_DIR") or (os.environ.get("DEVELOPER_DIR") or subprocess.check_output(["xcode-select", "-p"], text=True).strip()))
    sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"],
                                  env=environment, text=True).strip()
    parent = ROOT / ".scratch/learning-engine-io"
    parent.mkdir(parents=True, exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix="build-", dir=parent))
    executable = output / "learning-engine-io"
    command = ["xcrun", "--sdk", "iphonesimulator", "clang++", "-std=c++17", "-O2", "-fno-modules",
               "-fapplication-extension", "-target", "arm64-apple-ios17.0-simulator", "-isysroot", sdk,
               "-I", str(include), "-F", str(framework), str(source), "-framework", "RimeKit",
               "-lc++", "-lz", "-liconv", "-lsqlite3", "-o", str(executable)]
    subprocess.run(command, env=environment, check=True)
    if sha(archive) != identity:
        raise SystemExit("candidate changed while linking; discard this build and use final frozen identity")
    subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none", str(executable)], check=True)
    record = {"archive": str(archive), "archiveSha256": identity, "sourceSha256": sha(source), "publicHeaderSha256": {name: sha(include / name) for name in ("rime_api.h", "rime_levers_api.h")},
              "command": command, "executableSha256": sha(executable)}
    (output / "build-identity.json").write_text(json.dumps(record, indent=2) + "\n")
    print("ARCHIVE_SHA256=" + identity)
    print(executable)
    print(f'run: <simctl-spawn> "{executable}" <repo>/.scratch/learning-engine-io-<unique-suffix>')


if __name__ == "__main__":
    main()
