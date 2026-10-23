#!/usr/bin/env python3
"""Run a pinned-model ranking pair. This is not iOS device memory acceptance."""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
MODEL_NAME = "songyan_acceptance_model"


def digest(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def validate_fixture(fixture: dict) -> list[dict]:
    if not re.fullmatch(r"[0-9a-f]{64}", fixture.get("model_sha256", "")):
        raise ValueError("fixture requires the exact real model SHA256")
    cases = fixture.get("cases", [])
    if not isinstance(cases, list) or not 1 <= len(cases) <= 64:
        raise ValueError("fixture requires 1..64 calibrated ambiguous cases")
    for case in cases:
        if not isinstance(case, dict) or not re.fullmatch(r"[a-z']{1,128}", case.get("code", "")):
            raise ValueError("invalid input fixture")
        for key in ("enabled_prefix", "disabled_prefix"):
            prefix = case.get(key)
            if not isinstance(prefix, list) or not 1 <= len(prefix) <= 5 or not all(isinstance(x, str) and x for x in prefix):
                raise ValueError("each case requires calibrated enabled/disabled candidate prefixes")
    if len({case["code"] for case in cases}) != len(cases):
        raise ValueError("duplicate input fixture")
    if not any(case["enabled_prefix"] != case["disabled_prefix"] for case in cases):
        raise ValueError("fixture must include a calibrated ranking difference")
    return cases


def verify_reports(enabled: dict, disabled: dict, fixture: dict) -> dict:
    cases = validate_fixture(fixture)
    if enabled.get("mode") != "enabled" or disabled.get("mode") != "disabled":
        raise ValueError("not an enabled/disabled control pair")
    if enabled.get("version") != disabled.get("version") or not enabled.get("version"):
        raise ValueError("engine versions differ")
    if enabled.get("schema") != "songyan_quanpin" or disabled.get("schema") != "songyan_quanpin":
        raise ValueError("unexpected replay schema")
    if enabled.get("platform") != disabled.get("platform") or not enabled.get("platform"):
        raise ValueError("platforms differ")
    if enabled.get("modelSHA256") != fixture["model_sha256"] or disabled.get("modelSHA256"):
        raise ValueError("loaded model identity/control mismatch")
    for report in (enabled, disabled):
        if not report.get("grammarRegistered") or not report.get("luaRegistered"):
            raise ValueError("missing actual runtime modules")
    grammar = enabled.get("final", {})
    if not any(load.get("success") and load.get("entries", 0) > 0 for load in grammar.get("loads", [])):
        raise ValueError("no successful native model load")
    if any(grammar.get(key, 0) <= 0 for key in ("queryCount", "lookupCount", "matchCount")):
        raise ValueError("no actual native decoder lookup/match evidence")
    control = disabled.get("final", {})
    if control.get("loads") or control.get("queryCount", 0) != 0:
        raise ValueError("control consumed a model")
    codes = [case["code"] for case in cases]
    if [row.get("code") for row in enabled.get("replay", [])] != codes or [row.get("code") for row in disabled.get("replay", [])] != codes:
        raise ValueError("replay differs from the fixed input fixture")
    changed = []
    for case, on, off in zip(cases, enabled["replay"], disabled["replay"]):
        for row, key in ((on, "enabled_prefix"), (off, "disabled_prefix")):
            prefix = case[key]
            if not row.get("commit") or row.get("candidates", [])[:len(prefix)] != prefix:
                raise ValueError("candidate/commit calibration failed for " + case["code"])
        if on["candidates"] != off["candidates"]:
            changed.append(case["code"])
    if not changed:
        raise ValueError("model loaded but no candidate ordering effect was observed")
    return {"platform": enabled["platform"], "engine_version": enabled["version"],
            "model_sha256": fixture["model_sha256"], "changed_cases": changed,
            "scope": "development ranking replay; not iOS device memory/performance acceptance"}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--harness", required=True, type=Path)
    parser.add_argument("--shared", required=True, type=Path, help="prepared built-in package + Lua/OpenCC probe resources, without songyan_quanpin.custom.yaml")
    parser.add_argument("--model", required=True, type=Path)
    parser.add_argument("--simulator", help="booted dedicated Songyan-Gram Simulator UDID")
    parser.add_argument("--fixture", required=True, type=Path, help="JSON: model_sha256 and cases[{code, enabled_prefix, disabled_prefix}]")
    args = parser.parse_args()
    transport = []
    if args.simulator:
        if not re.fullmatch(r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}", args.simulator):
            raise ValueError("invalid Simulator UDID")
        inventory = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "--json"]))
        devices = [device for group in inventory["devices"].values() for device in group
                   if device["udid"].lower() == args.simulator.lower()]
        if len(devices) != 1 or devices[0]["state"] != "Booted" or not devices[0]["name"].startswith("Songyan-Gram"):
            raise ValueError("requires one booted dedicated Songyan-Gram Simulator")
        transport = ["xcrun", "simctl", "spawn", devices[0]["udid"]]
    fixture = json.loads(args.fixture.read_text())
    cases = validate_fixture(fixture)
    if args.model.is_symlink() or not args.model.is_file() or digest(args.model) != fixture["model_sha256"]:
        raise ValueError("real model is absent or does not match the pinned fixture")
    if not args.harness.is_file() or not (args.shared / "songyan_quanpin.schema.yaml").is_file():
        raise ValueError("native harness or prepared resources are absent")
    if (args.shared / "songyan_quanpin.custom.yaml").exists():
        raise ValueError("refusing to replace an existing custom configuration in the fixture")
    scratch = ROOT / ".scratch"
    scratch.mkdir(exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="grammar-ranking-", dir=scratch))
    codes = work / "codes.json"
    codes.write_text(json.dumps({"codes": [case["code"] for case in cases]}))
    reports = {}
    for mode in ("enabled", "disabled"):
        shared = work / mode / "shared"
        shutil.copytree(args.shared, shared, ignore=shutil.ignore_patterns(".git", "build", "*.userdb"))
        shutil.copyfile(args.model, shared / (MODEL_NAME + ".gram"))
        language = MODEL_NAME if mode == "enabled" else '""'
        (shared / "songyan_quanpin.custom.yaml").write_text("patch:\n  grammar/language: " + language + "\n")
        if not (shared / "opencc").is_dir():
            shutil.copytree(ROOT / "Resources/EngineResources/opencc", shared / "opencc")
        user = work / mode / "fresh-user"
        user.mkdir()
        if (shared / "rime.lua").is_file():
            shutil.copyfile(shared / "rime.lua", user / "rime.lua")
        report = work / (mode + ".json")
        subprocess.run(transport + [str(args.harness.resolve()), str(shared), str(user), mode, str(report), str(codes)], check=True)
        reports[mode] = json.loads(report.read_text())
    result = verify_reports(reports["enabled"], reports["disabled"], fixture)
    (work / "comparison.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(result, ensure_ascii=False, indent=2))
    print("Evidence:", work)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
