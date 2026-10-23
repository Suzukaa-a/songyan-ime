#!/usr/bin/env python3
"""Check a built RimeKit.xcframework and install it into Packages/RimeBridge.

  export-rimekit.py <built>/out/RimeKit.xcframework   check, copy to Vendored, rewrite the manifest
  export-rimekit.py --check                           check the installed copy against the manifest

The check requires the engine entry points in both slices and no absolute
build-machine paths in the archives.
"""
import hashlib
import json
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PACKAGE = ROOT / "Packages/RimeBridge"
INSTALLED = PACKAGE / "Vendored/RimeKit.xcframework"
MANIFEST = PACKAGE / "RimeKitArtifact.json"
SLICES = ("ios-arm64", "ios-arm64-simulator")
REQUIRED_SYMBOLS = ("_rb_require_lua", "_rb_require_grammar", "_rb_require_t9", "_rb_require_predict",
                    "_rb_predict_components_registered")
FORBIDDEN_PATHS = (str(ROOT).encode(), b"/Users/")


def archive_path(framework, name):
    return framework / name / "RimeKit.framework/RimeKit"


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def check_archive(archive):
    if not archive.is_file():
        raise SystemExit("missing archive: " + str(archive))
    symbols = subprocess.check_output(["nm", "-g", str(archive)], text=True)
    for name in REQUIRED_SYMBOLS:
        if name not in symbols:
            raise SystemExit(f"{archive}: missing symbol {name}")
    data = archive.read_bytes()
    for needle in FORBIDDEN_PATHS:
        if needle in data:
            raise SystemExit(f"{archive}: contains absolute build path {needle.decode()}")


def manifest_for(framework):
    return {
        "formatVersion": 1,
        "module": "RimeKit",
        "artifactPath": "Vendored/RimeKit.xcframework",
        "generator": "Tools/BuildRimeIOS/scripts/43-build-rimekit.py",
        "export": "Tools/BuildRimeIOS/scripts/export-rimekit.py",
        "pins": ["Tools/BuildRime/VERSIONS.env", "Tools/BuildRimeIOS/LUA-VERSIONS.env",
                 "Tools/BuildRimeIOS/GRAMMAR-VERSIONS.env", "Tools/BuildRimeIOS/PREDICT-VERSIONS.env"],
        "slices": {name: {"archive": name + "/RimeKit.framework/RimeKit",
                          "sha256": sha256(archive_path(framework, name))} for name in SLICES},
    }


def main():
    if sys.argv[1:] == ["--check"]:
        manifest = json.loads(MANIFEST.read_text())
        for name in SLICES:
            archive = INSTALLED / manifest["slices"][name]["archive"]
            check_archive(archive)
            if sha256(archive) != manifest["slices"][name]["sha256"]:
                raise SystemExit(f"{name}: archive does not match RimeKitArtifact.json")
        print("PASS installed RimeKit matches RimeKitArtifact.json")
        return
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    source = Path(sys.argv[1]).resolve()
    for name in SLICES:
        check_archive(archive_path(source, name))
    if INSTALLED.exists():
        shutil.rmtree(INSTALLED)
    shutil.copytree(source, INSTALLED)
    MANIFEST.write_text(json.dumps(manifest_for(INSTALLED), indent=2) + "\n")
    print("PASS exported to " + str(INSTALLED))


if __name__ == "__main__":
    main()
