#!/usr/bin/env python3
"""Verify arm64 Simulator signing; install only to a named disposable device without replacing HostApp."""
import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
import subprocess
import tempfile
from pathlib import Path
from urllib.parse import unquote, urlparse

ROOT = Path(__file__).resolve().parents[3]
GROUPS = "com.apple.security.application-groups"


def resolve_developer_dir() -> str:
    """Resolve a full Xcode without changing the global xcode-select setting."""
    current = os.environ.get("DEVELOPER_DIR")
    if current and (Path(current) / "usr" / "bin" / "xcodebuild").exists():
        return current
    selected = subprocess.run(
        ["xcode-select", "-p"], check=False, capture_output=True, text=True
    ).stdout.strip()
    if selected and (Path(selected) / "usr" / "bin" / "xcodebuild").exists():
        os.environ["DEVELOPER_DIR"] = selected
        return selected
    for candidate in ("/Applications/Xcode.app/Contents/Developer",
                      "/Applications/Xcode-beta.app/Contents/Developer"):
        if (Path(candidate) / "usr" / "bin" / "xcodebuild").exists():
            os.environ["DEVELOPER_DIR"] = candidate
            return candidate
    if current:
        raise RuntimeError(f"DEVELOPER_DIR={current} has no xcodebuild; "
                           "point it at a real Xcode Developer directory")
    raise RuntimeError("No full Xcode found; set DEVELOPER_DIR explicitly")


os.environ["DEVELOPER_DIR"] = resolve_developer_dir()


def run(*args):
    return subprocess.check_output([str(a) for a in args], stderr=subprocess.STDOUT)


def plist(path):
    return plistlib.loads(path.read_bytes())


def identity_settings():
    """Reads Config/Identity.xcconfig plus the optional git-ignored Local.xcconfig."""
    settings = {}
    for path in (ROOT / "Config/Identity.xcconfig", ROOT / "Config/Local.xcconfig"):
        if not path.exists():
            continue
        for line in path.read_text(encoding="utf-8").splitlines():
            match = re.fullmatch(r"\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*?)\s*", line)
            if match:
                settings[match.group(1)] = match.group(2)
    return settings


def expand(value, settings):
    if isinstance(value, str):
        return re.sub(r"\$\(([A-Z_][A-Z0-9_]*)\)", lambda m: settings.get(m.group(1), m.group(0)), value)
    if isinstance(value, list):
        return [expand(item, settings) for item in value]
    if isinstance(value, dict):
        return {key: expand(item, settings) for key, item in value.items()}
    return value


def entitlements_plist(path):
    return expand(plist(path), identity_settings())


def entitlement_sources():
    sources = {name: ROOT / f"Apps/{name}/{name}.entitlements"
               for name in ("HostApp", "KeyboardExtension")}
    groups = [entitlements_plist(p).get(GROUPS) for p in sources.values()]
    if not groups[0] or groups[0] != groups[1] or not all(
        isinstance(g, str) and g.startswith("group.") for g in groups[0]
    ):
        raise RuntimeError("Host/Extension source App Groups must be nonempty and identical")
    return sources


def simulated_entitlements(source, bundle_id, team_id):
    if not isinstance(team_id, str) or not re.fullmatch(r"[A-Z0-9]{10}", team_id):
        raise RuntimeError("Simulator Team ID must be ten uppercase letters/digits")
    result = dict(entitlements_plist(source))
    if "application-identifier" in result or "com.apple.developer.team-identifier" in result:
        raise RuntimeError("Source entitlements must not override the Simulator Team identity")
    result["application-identifier"] = f"{team_id}.{bundle_id}"
    return result


def entitlement_team(actual, source, bundle_id):
    app_id = actual.get("application-identifier")
    suffix = "." + bundle_id
    if not isinstance(app_id, str) or not app_id.endswith(suffix):
        raise RuntimeError(f"Missing exact Simulator application-identifier for {bundle_id}")
    team_id = app_id[:-len(suffix)]
    expected = simulated_entitlements(source, bundle_id, team_id)
    normalized = dict(actual)
    declared_team = normalized.pop("com.apple.developer.team-identifier", team_id)
    if declared_team != team_id or normalized != expected:
        raise RuntimeError(f"Signed Simulator entitlements differ from the verified source: {bundle_id}")
    return team_id


def require_matching_signing_team(signature, team_id):
    signed_team = re.search(r"^TeamIdentifier=([A-Z0-9]{10})$", signature, re.MULTILINE)
    if "Authority=Apple Development:" not in signature or signed_team is None \
            or signed_team.group(1) != team_id or "linker-signed" in signature:
        raise RuntimeError(f"Apple Development signature Team does not match App ID: {team_id}")


def bundles(app):
    extension = app / "PlugIns/KeyboardExtension.appex"
    if sorted(app.glob("PlugIns/*.appex")) != [extension]:
        raise RuntimeError("Unexpected extensions; configure explicit entitlements before delivery")
    return [("KeyboardExtension", extension), ("HostApp", app)]


def verify(app, evidence, expected_team=None):
    sources = entitlement_sources()
    evidence.mkdir(parents=True, exist_ok=True)
    # Debug builds execute .debug.dylib; checking only the small launcher is insufficient.
    nested_platforms = {}
    nested = list(app.rglob("*.dylib")) + [p / p.stem for p in app.rglob("*.framework")]
    for binary in sorted(nested):
        arch = run("xcrun", "lipo", "-archs", binary).decode().strip()
        platform = run("xcrun", "vtool", "-show-build", binary).decode()
        if arch != "arm64" or "platform IOSSIMULATOR" not in platform:
            raise RuntimeError(f"Not an arm64-only iOS simulator binary: {binary}")
        nested_platforms[str(binary.relative_to(app))] = platform
    (evidence / "nested-platforms.json").write_text(json.dumps(nested_platforms, indent=2) + "\n")
    summary = {}
    for name, bundle in bundles(app):
        info = plist(bundle / "Info.plist")
        binary = bundle / info["CFBundleExecutable"]
        arch = run("xcrun", "lipo", "-archs", binary).decode().strip()
        platform = run("xcrun", "vtool", "-show-build", binary).decode()
        if arch != "arm64" or "platform IOSSIMULATOR" not in platform:
            raise RuntimeError(f"Not an arm64-only iOS simulator binary: {binary}")
        (evidence / f"{name}.platform.txt").write_text(platform)
        signature = run("codesign", "-dvvv", bundle).decode()
        (evidence / f"{name}.codesign.txt").write_text(signature)
        # codesign diagnostics on stderr are not plist data.
        actual = subprocess.check_output(
            ["codesign", "-d", "--entitlements", ":-", str(bundle)], stderr=subprocess.PIPE)
        entitlements = plistlib.loads(actual)
        team_id = entitlement_team(entitlements, sources[name], info["CFBundleIdentifier"])
        require_matching_signing_team(signature, team_id)
        if expected_team is not None and team_id != expected_team:
            raise RuntimeError(f"Unexpected Simulator Team ID for {bundle}: {team_id}")
        (evidence / f"{name}.entitlements.plist").write_bytes(actual)
        validity = run("codesign", "--verify", "--deep", "--strict", "--verbose=4", bundle)
        (evidence / f"{name}.verify.txt").write_bytes(validity)
        summary[name] = {"bundleID": info["CFBundleIdentifier"], "arch": arch,
                         "teamID": team_id, "appGroups": entitlements[GROUPS]}
    if summary["KeyboardExtension"]["teamID"] != summary["HostApp"]["teamID"]:
        raise RuntimeError("Host and Extension Simulator Team IDs differ")
    if not summary["KeyboardExtension"]["bundleID"].startswith(summary["HostApp"]["bundleID"] + "."):
        raise RuntimeError("Extension bundle ID must be prefixed by Host bundle ID")
    hashes = {str(p.relative_to(app)): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in sorted(app.rglob("*")) if p.is_file()}
    (evidence / "sha256.json").write_text(json.dumps(hashes, indent=2) + "\n")
    (evidence / "verified.json").write_text(json.dumps(summary, indent=2) + "\n")
    return summary, hashes


def sign(app, sources, evidence, identity, team_id):
    # Inside out, without --deep signing (which can give children Host entitlements).
    nested = list(app.rglob("*.dylib")) + list(app.rglob("*.framework"))
    log = bytearray()
    for path in sorted(nested, key=lambda p: (-len(p.parts), str(p))):
        log.extend(run("codesign", "--force", "--sign", identity, "--timestamp=none",
                       "--generate-entitlement-der", path))
    for name, bundle in bundles(app):
        source = evidence / f"{name}.source.entitlements.plist"
        shutil.copy2(sources[name], source)
        info = plist(bundle / "Info.plist")
        simulated = evidence / f"{name}.simulated.entitlements.plist"
        simulated.write_bytes(plistlib.dumps(
            simulated_entitlements(source, info["CFBundleIdentifier"], team_id)))
        log.extend(run("codesign", "--force", "--sign", identity, "--timestamp=none",
                       "--generate-entitlement-der", "--entitlements", simulated, bundle))
    (evidence / "sign.log").write_bytes(log)


def require_isolated_device(device):
    name = device.get("name")
    if not isinstance(name, str) or not name.endswith("-Isolated"):
        raise RuntimeError("Refusing installation outside an explicitly named -Isolated "
                           "Simulator; use a disposable device and preserve existing data")


def refuse_existing_install(udid, bundle_id):
    probe = subprocess.run(["xcrun", "simctl", "appinfo", udid, bundle_id],
                           check=False, capture_output=True, text=True)
    if probe.returncode == 0:
        raise RuntimeError("Refusing to replace an installed HostApp: an App Group grant "
                           "may disappear during installation and delete the existing "
                           "publication. Use a fresh isolated Simulator; plan and verify "
                           "a full data backup before any manual update.")
    if probe.returncode != 3 or "No application record found for that bundle identifier" \
            not in probe.stdout + probe.stderr:
        raise RuntimeError("Cannot prove the target HostApp is absent; refusing install: "
                           + (probe.stdout + probe.stderr).strip())


def registered_group_path(udid, bundle_id, group_id):
    raw = run("xcrun", "simctl", "appinfo", udid, bundle_id)
    converted = subprocess.run(["plutil", "-convert", "json", "-o", "-", "-"], input=raw,
                               capture_output=True, check=True).stdout
    appinfo = json.loads(converted)
    groups = appinfo.get("GroupContainers")
    mapped = groups.get(group_id) if isinstance(groups, dict) else None
    parsed = urlparse(mapped) if isinstance(mapped, str) else None
    if parsed is None or parsed.scheme != "file" or parsed.netloc not in ("", "localhost"):
        raise RuntimeError(f"No install-time App Group mapping for {group_id}")
    path = Path(unquote(parsed.path))
    if not path.is_dir():
        raise RuntimeError(f"Registered App Group directory is missing: {group_id}")
    return path.resolve()


def install_on_device(app, evidence, udid):
    # Explicit device only; no uninstall/erase. Restore the initial boot state.
    summary, hashes = verify(app, evidence / "pre-install")
    devices = json.loads(run("xcrun", "simctl", "list", "devices", "--json"))
    matches = [d for ds in devices["devices"].values() for d in ds if d["udid"] == udid]
    if len(matches) != 1:
        raise RuntimeError(f"Simulator UDID not found exactly once: {udid}")
    device = matches[0]
    require_isolated_device(device)
    initial_state = device["state"]
    if initial_state not in ("Booted", "Shutdown"):
        raise RuntimeError(f"Simulator {udid} is not installable from state {initial_state}")
    started_here = initial_state == "Shutdown"
    (evidence / "device-initial-state.json").write_text(
        json.dumps({"udid": udid, "name": device.get("name"), "state": initial_state}, indent=2) + "\n"
    )
    try:
        if started_here:
            run("xcrun", "simctl", "boot", udid)
        run("xcrun", "simctl", "bootstatus", udid, "-b")
        refuse_existing_install(udid, summary["HostApp"]["bundleID"])
        run("xcrun", "simctl", "install", udid, app)
        installed = Path(run("xcrun", "simctl", "get_app_container", udid,
                              summary["HostApp"]["bundleID"], "app").decode().strip())
        _, installed_hashes = verify(installed, evidence / "installed")
        if hashes != installed_hashes:
            raise RuntimeError("Installed app differs from verified delivery")
        group_id = summary["HostApp"]["appGroups"][0]
        mapped_group = registered_group_path(udid, summary["HostApp"]["bundleID"], group_id)
        try:
            group = Path(run("xcrun", "simctl", "get_app_container", udid,
                             summary["HostApp"]["bundleID"], group_id).decode().strip())
        except subprocess.CalledProcessError as error:
            raise RuntimeError(f"Installed app has no runtime App Group grant for {group_id}") from error
        if not group.is_dir() or group.resolve() != mapped_group:
            raise RuntimeError(f"Runtime App Group differs from install-time mapping: {group_id}")
        (evidence / "registered-group.txt").write_text(f"{group_id}\n{mapped_group}\n")
        launch = run("xcrun", "simctl", "launch", udid, summary["HostApp"]["bundleID"])
        (evidence / "launch.txt").write_bytes(launch)
        (evidence / "installed-device.txt").write_text(f"{udid}\n{installed}\n")
    finally:
        if started_here:
            run("xcrun", "simctl", "shutdown", udid)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify", type=Path, metavar="APP", help="verify existing package without resigning")
    parser.add_argument("--from-build", type=Path, metavar="APP", help="sign an already-built unsigned HostApp.app")
    parser.add_argument("--signing-identity", metavar="IDENTITY",
                        help="Apple Development identity whose actual TeamIdentifier matches --simulator-team-id; required when signing")
    parser.add_argument("--simulator-team-id", metavar="TEAM_ID",
                        help="ten-character Team prefix for complete simulated application identifiers; required when signing")
    parser.add_argument("--install", action="store_true", help="install only on a named -Isolated simulator")
    parser.add_argument("--device-udid", default=os.environ.get("SONGYAN_SIMULATOR_UDID"),
                        help="simulator UDID (or SONGYAN_SIMULATOR_UDID); never auto-selects a booted device")
    parser.add_argument("--output-parent", type=Path, default=ROOT / ".local/simulator-deliveries")
    args = parser.parse_args()
    if args.verify and args.from_build:
        parser.error("--verify and --from-build are mutually exclusive")
    if args.install != bool(args.device_udid):
        parser.error("--install and --device-udid/SONGYAN_SIMULATOR_UDID must be provided together")
    if not args.verify and not args.simulator_team_id:
        parser.error("--simulator-team-id is required when signing a Simulator app")
    if not args.verify and (not args.signing_identity or args.signing_identity == "-"):
        parser.error("--signing-identity must be an Apple Development certificate when signing")
    if args.simulator_team_id and not re.fullmatch(r"[A-Z0-9]{10}", args.simulator_team_id):
        parser.error("--simulator-team-id must be ten uppercase letters/digits")
    args.output_parent.mkdir(parents=True, exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix="delivery-", dir=args.output_parent.resolve()))
    evidence = output / "evidence"
    evidence.mkdir()
    print(f"Delivery directory: {output}", flush=True)
    if args.verify:
        app = args.verify.resolve()
    else:
        sources = entitlement_sources()
        if args.from_build:
            product = args.from_build.resolve()
            if not product.is_dir() or product.name != "HostApp.app":
                parser.error("--from-build must name an existing HostApp.app directory")
        else:
            command = ["xcodebuild", "-project", str(ROOT / "Songyan.xcodeproj"),
                       "-scheme", "HostApp", "-configuration", "Debug", "-sdk", "iphonesimulator",
                       "-destination", "generic/platform=iOS Simulator", "-jobs", "4",
                       "-derivedDataPath", str(output / "DerivedData"), "ARCHS=arm64",
                       "ONLY_ACTIVE_ARCH=YES", "CODE_SIGNING_ALLOWED=NO", "build"]
            (evidence / "build-command.json").write_text(json.dumps(command, indent=2) + "\n")
            with (evidence / "build.log").open("wb") as log:
                subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
            product = output / "DerivedData/Build/Products/Debug-iphonesimulator/HostApp.app"
        app = output / "HostApp.app"
        shutil.copytree(product, app, symlinks=True)
        sign(app, sources, evidence, args.signing_identity, args.simulator_team_id)
    verify(app, evidence, args.simulator_team_id)
    if args.install:
        install_on_device(app, evidence, args.device_udid)
    print(f"VERIFIED_SIMULATOR_APP={app}\nSIGNATURE_EVIDENCE={evidence}")
    print("Static delivery checks passed. Recipe application and shared layout runtime QA are separate.")


if __name__ == "__main__":
    main()
