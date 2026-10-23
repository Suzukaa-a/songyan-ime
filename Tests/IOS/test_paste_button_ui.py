"""Signed simulator check of production paste button geometry and clipboard state.

Explicit entry only: DEVELOPER_DIR="$(xcode-select -p)"
python3 Tests/IOS/test_paste_button_ui.py --simulator <dedicated UDID>
Uses fixed app-owned contents; does not prove extension rich-media delivery.
"""
import argparse
import json
import os
import plistlib
import subprocess
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def run(command, **kwargs):
    return subprocess.run(command, check=True, text=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator", required=True)
    options = parser.parse_args()
    nonce = uuid.uuid4().hex
    directory = ROOT / ".scratch" / f"paste-button-ui-{nonce}"
    directory.mkdir(parents=True)
    bundle = f"app.songyan.audit.PasteButtonProbe.r{nonce}"
    app = directory / "PasteButtonProbe.app"
    app.mkdir()
    source = directory / "Probe.swift"
    source.write_text((ROOT / "Apps/SharedKeyboard/QuickPasteView.swift").read_text()
                      + "\n" + (ROOT / "Tests/IOS/Fixtures/PasteButtonUI.swift").read_text())
    with (app / "Info.plist").open("wb") as stream:
        plistlib.dump({"CFBundleIdentifier": bundle, "CFBundleName": "PasteButtonProbe",
                      "CFBundleExecutable": "PasteButtonProbe", "CFBundleVersion": "1",
                      "CFBundleShortVersionString": "1.0", "CFBundlePackageType": "APPL",
                      "MinimumOSVersion": "17.0", "UIDeviceFamily": [1, 2], "UILaunchScreen": {}}, stream)
    sdk = run(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], capture_output=True).stdout.strip()
    run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-sdk", sdk,
         "-target", "arm64-apple-ios17.0-simulator", str(source), "-o", str(app / "PasteButtonProbe")],
        env={**os.environ, "SDKROOT": sdk})
    run(["codesign", "--force", "--sign", "-", str(app)])
    run(["xcrun", "simctl", "install", options.simulator, str(app)])
    container = Path(run(["xcrun", "simctl", "get_app_container", options.simulator, bundle, "data"],
                         capture_output=True).stdout.strip())
    report = container / "Documents/paste-button-report.json"
    run(["xcrun", "simctl", "launch", options.simulator, bundle])
    deadline = time.monotonic() + 20
    while not report.exists() and time.monotonic() < deadline:
        time.sleep(0.2)
    if not report.exists():
        raise RuntimeError("signed UIKit probe did not publish its report")
    result = json.loads(report.read_text())
    (directory / "report.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(result, ensure_ascii=False, indent=2))
    print(f"Report: {directory / 'report.json'}")
    if not result["passed"]:
        raise RuntimeError("native paste button checks failed")


if __name__ == "__main__":
    main()
