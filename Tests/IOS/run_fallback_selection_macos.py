"""Real-engine macOS probe for KeyboardRecipeStore.saveSelection runtime identity.

Compiles the production store (Apps/SharedKeyboard/KeyboardRecipeStore.swift) together with
the KeyboardCore and RimeBridge sources, against the pinned macOS librime prefix
(.local/engine/prefix) and the C/C++ bridges in Tools/BuildRimeIOS/src, then runs
Tests/IOS/fallback-selection-main.swift. No iOS install, signing or GUI; all
generated files stay in a fresh run dir under .local/.

Run: python3 Tests/IOS/run_fallback_selection_macos.py
"""
import os
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PREFIX = ROOT / ".local/engine/prefix"
BRIDGE = ROOT / "Tools/BuildRimeIOS/src"
BOOST = ROOT / ".local/engine/src" / os.environ.get("BOOST_DIRNAME", "boost-1.89.0")
LIBRIME_SRC = ROOT / ".local/engine/src/librime"


def find_build_config():
    for candidate in sorted((ROOT / ".local/engine/build").glob("*/src/rime/build_config.h")):
        return candidate.parents[1]
    for candidate in sorted((ROOT / ".local/engine/work-*").glob("*/build/*/src/rime/build_config.h")):
        return candidate.parents[1]
    raise SystemExit("generated rime/build_config.h not found under .local/engine")


def main():
    run = Path(tempfile.mkdtemp(prefix="fallback-selection-", dir=ROOT / ".local"))
    obj = run / "obj"
    module = run / "RimeKitModule"
    obj.mkdir()
    module.mkdir()
    gen_include = find_build_config()

    env = dict(os.environ, DEVELOPER_DIR=(os.environ.get("DEVELOPER_DIR") or subprocess.check_output(["xcode-select", "-p"], text=True).strip()))
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], env=env, text=True).strip()

    (module / "module.modulemap").write_text(
        'module RimeKit {\n    header "rime_api.h"\n    header "rime_bridge.h"\n    export *\n}\n')
    for header in ["rime_api.h"]:
        subprocess.run(["cp", str(PREFIX / "include" / header), str(module / header)], check=True)
    for header in ["rime_bridge.h"]:
        subprocess.run(["cp", str(BRIDGE / header), str(module / header)], check=True)

    subprocess.run(["clang", "-std=c11", "-O2", "-c",
                    "-I", str(BRIDGE), "-I", str(PREFIX / "include"),
                    "-mmacosx-version-min=13.0",
                    str(BRIDGE / "rime_bridge.c"), "-o", str(obj / "rime_bridge.o")],
                   env=env, check=True)
    cxx_flags = ["-std=c++17", "-O2", "-fapplication-extension", "-c",
                 "-DBOOST_DLL_USE_STD_FS", '-DGLOG_DEPRECATED=__attribute__((deprecated))',
                 "-DGLOG_EXPORT=", "-DGLOG_NO_EXPORT=", "-DOpencc_BUILT_AS_STATIC",
                 "-DYAML_CPP_STATIC_DEFINE", '-DRIME_VERSION="1.17.0"',
                 "-I", str(BRIDGE), "-I", str(PREFIX / "include"),
                 "-I", str(LIBRIME_SRC / "src"), "-I", str(LIBRIME_SRC / "include"),
                 "-I", str(BOOST), "-I", str(gen_include),
                 "-mmacosx-version-min=13.0"]
    for name in ["rime_spelling", "rime_display_map"]:
        subprocess.run(["clang++", *cxx_flags, str(BRIDGE / f"{name}.cc"), "-o", str(obj / f"{name}.o")],
                       env=env, check=True)

    sources = sorted((ROOT / "Packages/KeyboardCore/Sources/KeyboardCore").rglob("*.swift"))
    sources += sorted((ROOT / "Packages/RimeBridge/Sources/RimeBridge").glob("*.swift"))
    sources += [ROOT / "Apps/SharedKeyboard" / x for x in [
        "RimePaths.swift", "KeyboardCompositionPreferences.swift", "KeyboardRecipeStore.swift",
        "KeyboardRecipeStore+Publication.swift", "GrammarRuntimeReceiptStore.swift", "EngineOpQueue.swift",
        "KeyboardPresenceStamp.swift", "KeyboardResourceReadQueue.swift", "OptionStore.swift", "KeyboardLog.swift"]]
    staged = []
    for i, source in enumerate(sources):
        dest = run / f"source{i}.swift"
        dest.write_text(source.read_text().replace("import KeyboardCore\n", "").replace("import RimeBridge\n", ""))
        staged.append(str(dest))

    # The learning bridge C target (RimeLeversSupport) is a real SPM dependency
    # of RimeBridge (RimeLearningBackup.swift imports its Clang module).
    support = run / "learning-support"
    subprocess.run(["python3", str(ROOT / "Tools/BuildRimeIOS/scripts/build-learning-support.py"),
                    "--sdk", sdk, "--target", "arm64-apple-macos13.0",
                    "--kit-include-dir", str(PREFIX / "include"),
                    "--output-dir", str(support),
                    "--cc", "xcrun clang"], env=env, check=True)

    command = ["xcrun", "swiftc", "-swift-version", "5", "-sdk", sdk, "-target", "arm64-apple-macos13.0",
               "-Xcc", f"-fmodule-map-file={module}/module.modulemap", "-I", str(module),
               "-Xcc", f"-fmodule-map-file={support / 'module/module.modulemap'}",
               "-I", str(PREFIX / "include"), "-I", str(support / "module"), *staged,
               str(ROOT / "Tests/IOS/fallback-selection-main.swift")]
    command += [str(obj / x) for x in ["rime_bridge.o", "rime_spelling.o", "rime_display_map.o"]]
    command += [str(support / "RimeLeversSupport.o")]
    for lib in ["rime", "glog", "leveldb", "marisa", "opencc", "yaml-cpp"]:
        command += ["-Xlinker", str(PREFIX / f"lib/lib{lib}.a")]
    command += ["-Xlinker", str(BOOST / "stage/lib/libboost_regex.a"),
                "-Xlinker", "-lc++", "-Xlinker", "-lc++abi", "-liconv", "-lpthread",
                "-o", str(run / "probe")]
    subprocess.run(command, env=env, check=True)
    subprocess.run([str(run / "probe"), str(run)], env=env, check=True)
    print("Probe run dir:", run)


if __name__ == "__main__":
    main()
