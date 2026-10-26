"""Signed-simulator native touch probe for the one-handed restore gutter.

Explicit entry only; select a full Xcode with xcode-select or DEVELOPER_DIR:

    python3 Tests/IOS/test_one_hand_touch.py --simulator <dedicated UDID>

Compiles the production router (FeedbackInputView.hitTest/keyForGap), KeyboardRoutedTouch and
OneHandGutterControl into a small signed probe app and runs the hit tests against a real UIKit
view tree on the simulator. The checked cases are listed in Fixtures/OneHandTouchProbe.swift.
"""
import argparse
import json
import os
import plistlib
import subprocess
import sys
import time
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from swift_probe import section

ROOT = Path(__file__).resolve().parents[2]

def run(command, **kwargs):
    return subprocess.run(command, check=True, text=True, **kwargs)


def strip_imports(text):
    """One compilation unit: every import is hoisted into the generated header."""
    return "\n".join(line for line in text.splitlines() if not line.startswith("import "))


def production_sources():
    appearance = (ROOT / "Apps/SharedKeyboard/KeyboardAppearance.swift").read_text()
    host = (ROOT / "Apps/SharedKeyboard/KeyboardPanelHost.swift").read_text()
    feedback = (ROOT / "Apps/SharedKeyboard/FeedbackInputView.swift").read_text()
    policy = (ROOT / "Packages/CandidateKit/Sources/CandidateKit/OneHandLayoutPolicy.swift").read_text()
    split = (ROOT / "Packages/LayoutKit/Sources/LayoutKit/LayoutSplitConfiguration.swift").read_text()
    # The policy's phone-width bound lives in LayoutKit, which the probe does not link.
    surface = section(split, "public enum KeyboardSurfaceWidth {", "/// A saved split")

    routed = section(appearance, "protocol KeyboardKeyHitTarget", "class SkinnedButton")
    # The restore control is the last declaration of KeyboardPanelHost.swift.
    gutter = host[host.index("final class OneHandGutterControl: UIControl {"):]
    router = strip_imports(feedback)

    return strip_imports(routed), gutter, router, surface + strip_imports(policy)


def assemble():
    routed, gutter, router, policy = production_sources()
    fixture = (ROOT / "Tests/IOS/Fixtures/OneHandTouchProbe.swift").read_text()
    header = "import Foundation\nimport UIKit\n"
    return "\n\n".join([header, routed, gutter, router, policy, strip_imports(fixture)])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator", required=True, help="dedicated simulator UDID")
    options = parser.parse_args()

    developer = os.environ.get("DEVELOPER_DIR") or run(["xcode-select", "-p"], capture_output=True).stdout.strip()
    env = {**os.environ, "DEVELOPER_DIR": developer}

    nonce = uuid.uuid4().hex
    directory = ROOT / ".scratch" / f"one-hand-touch-{nonce}"
    directory.mkdir(parents=True)
    bundle = f"app.songyan.audit.OneHandTouchProbe.r{nonce}"
    app = directory / "OneHandTouchProbe.app"
    app.mkdir()

    source = directory / "Probe.swift"
    source.write_text(assemble())

    with (app / "Info.plist").open("wb") as stream:
        plistlib.dump({"CFBundleIdentifier": bundle, "CFBundleName": "OneHandTouchProbe",
                       "CFBundleExecutable": "OneHandTouchProbe", "CFBundleVersion": "1",
                       "CFBundleShortVersionString": "1.0", "CFBundlePackageType": "APPL",
                       "MinimumOSVersion": "17.0", "UIDeviceFamily": [1, 2],
                       "UILaunchScreen": {}}, stream)

    sdk = run(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"],
              capture_output=True, env=env).stdout.strip()
    run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-sdk", sdk,
         "-target", "arm64-apple-ios17.0-simulator", str(source),
         "-o", str(app / "OneHandTouchProbe")], env={**env, "SDKROOT": sdk})
    run(["codesign", "--force", "--sign", "-", str(app)])
    run(["xcrun", "simctl", "install", options.simulator, str(app)], env=env)
    container = Path(run(["xcrun", "simctl", "get_app_container", options.simulator, bundle, "data"],
                         capture_output=True, env=env).stdout.strip())
    report = container / "Documents/one-hand-touch-report.json"
    run(["xcrun", "simctl", "launch", options.simulator, bundle], env=env)
    deadline = time.monotonic() + 30
    while not report.exists() and time.monotonic() < deadline:
        time.sleep(0.2)
    if not report.exists():
        raise RuntimeError("signed one-hand touch probe did not publish its report")
    result = json.loads(report.read_text())
    (directory / "report.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(result, ensure_ascii=False, indent=2))
    print(f"Report: {directory / 'report.json'}")
    if not result["passed"]:
        raise RuntimeError("one-hand touch routing checks failed")


if __name__ == "__main__":
    main()
