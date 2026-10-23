#!/usr/bin/env python3
"""Reproduce the pinned writer defect and test a review-only candidate patch.

Never changes the source checkout, delivered XCFramework, or artifact identity.
Only native components are compiled; this does not produce an App engine slice.
"""
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
TOOLS = ROOT / "Tools/BuildRimeIOS"
SOURCE = ROOT / ".local/engine/src/librime"
PATCH = TOOLS / "patches/librime-tsv-write-failures.patch"
HARNESS = TOOLS / "harness-mac/learning-backup-write-failure.cc"


def invoke(command, environment, *, cwd=None):
    result = subprocess.run(list(map(str, command)), cwd=cwd, env=environment,
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            timeout=180)
    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}): {command}\n{result.stdout}")
    return result.stdout


def digest(file):
    with file.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def main():
    if sys.platform != "darwin":
        raise SystemExit("requires macOS clang and dyld controlled fault injection")
    environment = dict(os.environ)
    if not environment.get("DEVELOPER_DIR") and environment.get("XCODE_DEV_DIR"):
        environment["DEVELOPER_DIR"] = environment["XCODE_DEV_DIR"]
    versions = (ROOT / "Tools/BuildRime/VERSIONS.env").read_text()
    pinned = re.search(r"^LIBRIME_COMMIT=([0-9a-f]{40})$", versions, re.MULTILINE).group(1)
    boost_version = re.search(r"^BOOST_VERSION=([0-9.]+)$", versions, re.MULTILINE).group(1)
    boost = ROOT / ".local/engine/src" / ("boost-" + boost_version)
    if invoke(["git", "-C", SOURCE, "rev-parse", "HEAD"], environment).strip() != pinned:
        raise SystemExit("source checkout differs from the pinned librime commit")
    invoke(["git", "-C", SOURCE, "diff", "--exit-code", "--", "src", "include"], environment)
    if not boost.is_dir():
        raise SystemExit("pinned Boost headers missing; run the existing source fetch workflow")
    if environment.get("LIBRIME_BUILD_CONFIG"):
        config = Path(environment["LIBRIME_BUILD_CONFIG"])
    else:
        configs = sorted((ROOT / ".local/engine/build").glob("librime-static*/src/rime/build_config.h"))
        configs += sorted((ROOT / ".local/ios-engine/build/sim").glob("librime.*/src/rime/build_config.h"))
        if not configs:
            raise SystemExit("set LIBRIME_BUILD_CONFIG to an existing generated build_config.h")
        config = configs[0]
    if not config.is_file():
        raise SystemExit("generated build_config.h missing")
    parent = ROOT / ".scratch/learning-backup-io-candidate"
    parent.mkdir(parents=True, exist_ok=True)
    if parent.resolve() != parent.absolute():
        raise SystemExit("candidate parent contains a symlink; refusing to write")
    run = Path(tempfile.mkdtemp(prefix="run-", dir=parent))
    baseline = run / "baseline-source"
    candidate = run / "candidate-source"
    for tree in (baseline, candidate):
        for name in ("src", "include"):
            shutil.copytree(SOURCE / name, tree / name, symlinks=True)
    invoke(["git", "init", "--quiet", candidate], environment)
    invoke(["git", "apply", "--check", PATCH], environment, cwd=candidate)
    invoke(["git", "apply", PATCH], environment, cwd=candidate)
    invoke(["git", "apply", "--reverse", "--check", PATCH], environment, cwd=candidate)
    changed_paths = re.findall(r"^\+\+\+ b/(.+)$", PATCH.read_text(), re.MULTILINE)
    if not changed_paths or any(digest(baseline / path) == digest(candidate / path) for path in changed_paths):
        raise RuntimeError("patch did not change every declared candidate input")
    # Use the real generated config and upstream logging-disabled profile for this
    # isolated component link. No glog implementation or native engine is mocked.
    guard = run / "component-profile.h"
    guard.write_text("#include <rime/build_config.h>\n#undef RIME_ENABLE_LOGGING\n", encoding="utf-8")
    sdk = invoke(["xcrun", "--sdk", "macosx", "--show-sdk-path"], environment).strip()
    common = ["xcrun", "--sdk", "macosx", "clang++", "-std=c++17", "-O1", "-Wall", "-Wextra",
              "-ffunction-sections", "-fdata-sections", "-mmacosx-version-min=13.0",
              "-isysroot", sdk, "-DBOOST_DLL_USE_STD_FS", '-DRIME_VERSION="1.17.0"',
              "-include", guard, "-I", config.parent.parent, "-I", boost]
    interposer = run / "libwriter-faults.dylib"
    invoke([*common, "-I", baseline / "src", "-I", baseline / "include",
            "-DLEARNING_IO_INTERPOSER=1", "-dynamiclib", HARNESS, "-o", interposer], environment)
    runtime_environment = dict(environment, DYLD_INSERT_LIBRARIES=str(interposer))
    components = ["db.cc", "db_utils.cc", "tsv.cc", "user_db.cc", "text_db.cc", "table_db.cc"]
    results = {}
    for mode, tree in (("baseline", baseline), ("candidate", candidate)):
        executable = run / ("writer-" + mode)
        options = [*common, "-I", tree / "src", "-I", tree / "include"]
        if mode == "candidate":
            options.append("-DLEARNING_IO_CANDIDATE=1")
        compile_output = invoke([*options, HARNESS,
                                 *[tree / "src/rime/dict" / name for name in components],
                                 "-Wl,-dead_strip", interposer, "-o", executable], environment)
        (run / (mode + "-compile.log")).write_text(compile_output)
        output = invoke([executable, mode, run / (mode + "-output")], runtime_environment)
        (run / (mode + "-run.log")).write_text(output)
        if "ALL PASS " not in output:
            raise RuntimeError("native component did not complete all assertions\n" + output)
        results[mode] = {"executableSha256": digest(executable), "output": output}
        print(output, end="")
    # Compile the actual new LevelDbAccessor/iterator status path against pinned
    # LevelDB headers. The injected EOF tests above exercise its Source contract;
    # a full candidate engine build and real DB-I/O tests remain a release gate.
    output = invoke([*common, "-I", candidate / "src", "-I", candidate / "include",
                     "-I", SOURCE / "deps/leveldb/include", "-c",
                     candidate / "src/rime/dict/level_db.cc", "-o", run / "level_db-candidate.o"], environment)
    (run / "level-db-compile.log").write_text(output)
    (run / "evidence.json").write_text(json.dumps({
        "librimeCommit": pinned, "patchSha256": digest(PATCH),
        "results": results,
        "scope": "native component candidate only; no delivered engine changes",
    }, indent=2) + "\n")
    print(f"PASS review-only writer candidate: {run}")


if __name__ == "__main__":
    main()
