#!/usr/bin/env python3
"""Build RimeKit.xcframework (both iOS slices) from the pinned sources.

Inputs: pinned librime + patch, the dependency archives from 11-build-deps.sh
(<deps-root>/prefix, default .local/ios-engine), and the plugin sources under
.local/ios-engine/plugin-sources (fetched by 09-fetch-plugins.sh). Output goes to a fresh directory
under .local/ios-engine; export-rimekit.py then installs it into the package.
"""
import argparse
import os
import plistlib
import re
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
TOOLS = ROOT / "Tools/BuildRimeIOS"
ENGINE = ROOT / ".local/ios-engine"
SOURCE = ROOT / ".local/engine/src/librime"
PATCH = TOOLS / "patches/librime-tsv-write-failures.patch"
CMAKE = ROOT / ".local/engine/tools/cmake/CMake.app/Contents/bin/cmake"
BUNDLE_ID = "app.songyan.RimeKit"
PUBLIC_HEADERS = ("rime_api.h", "rime_api_deprecated.h", "rime_api_stdbool.h", "rime_levers_api.h")
UMBRELLA = """#ifndef RIMEKIT_H_
#define RIMEKIT_H_

// Public umbrella for the static librime API and the reviewed iOS bridge.
// List every shipped public header so Clang does not infer accidental private
// submodules or warn differently between Debug and whole-module Release builds.
""" + "".join(f'#include "{name}"\n' for name in (*PUBLIC_HEADERS, "rime_bridge.h")) + """
#endif
"""
MODULE_MAP = """framework module RimeKit {
  umbrella header "RimeKit.h"
  export *
  module * { export * }
}
"""
# Rewrites the checkout root in __FILE__ strings and debug info so the shipped
# archive carries no absolute build-machine paths.
PATH_MAP = "-ffile-prefix-map=" + str(ROOT) + "=."
DEPENDENCIES = ["libglog.a", "libleveldb.a", "libmarisa.a", "libopencc.a", "libyaml-cpp.a", "libboost_regex.a"]
SLICES = (("sim", "sim-arm64", "iphonesimulator", "ios-arm64-simulator"),
          ("dev", "device-arm64", "iphoneos", "ios-arm64"))


def run(command, env, log=None, cwd=None):
    print("RUN " + " ".join(map(str, command)), flush=True)
    if log is None:
        return subprocess.check_output(list(map(str, command)), env=env, cwd=cwd, text=True).strip()
    with log.open("a") as stream:
        subprocess.run(list(map(str, command)), env=env, cwd=cwd, stdout=stream,
                       stderr=subprocess.STDOUT, check=True)


def pin(name, file):
    return re.search(rf"^{name}=([^\n]+)$", file.read_text(), re.MULTILINE).group(1)


def write_framework_metadata(framework):
    """Writes the xcframework wrapper and per-slice bundle files from scratch."""
    libraries = []
    for label, _, _, slice_name in sorted(SLICES, key=lambda slice_: slice_[3]):
        library = {"BinaryPath": "RimeKit.framework/RimeKit", "LibraryIdentifier": slice_name,
                   "LibraryPath": "RimeKit.framework", "SupportedArchitectures": ["arm64"],
                   "SupportedPlatform": "ios"}
        if label == "sim":
            library["SupportedPlatformVariant"] = "simulator"
        libraries.append(library)
    with (framework / "Info.plist").open("wb") as stream:
        plistlib.dump({"AvailableLibraries": libraries, "CFBundlePackageType": "XFWK",
                       "XCFrameworkFormatVersion": "1.0"}, stream)


def write_slice_metadata(destination, prefix, label):
    (destination / "Headers").mkdir(parents=True)
    (destination / "Modules").mkdir()
    for name in PUBLIC_HEADERS:
        shutil.copy2(prefix / "include" / name, destination / "Headers" / name)
    shutil.copy2(TOOLS / "src/rime_bridge.h", destination / "Headers/rime_bridge.h")
    (destination / "Headers/RimeKit.h").write_text(UMBRELLA)
    (destination / "Modules/module.modulemap").write_text(MODULE_MAP)
    with (destination / "Info.plist").open("wb") as stream:
        plistlib.dump({"CFBundleDevelopmentRegion": "en", "CFBundleExecutable": "RimeKit",
                       "CFBundleIdentifier": BUNDLE_ID, "CFBundleInfoDictionaryVersion": "6.0",
                       "CFBundleName": "RimeKit", "CFBundlePackageType": "FMWK",
                       "CFBundleShortVersionString": "1.17.0", "CFBundleVersion": "1.17.0",
                       "CFBundleSupportedPlatforms": ["iPhoneSimulator" if label == "sim" else "iPhoneOS"]},
                      stream, sort_keys=False)


def build_core(out, env, boost, jobs, deps_root):
    """Patched librime for each slice, linked against the prebuilt dependencies."""
    native = out / "src/librime"

    def one(label, folder, sdk_name):
        prefix = out / "prefix" / folder
        original = deps_root / "prefix" / folder
        (prefix / "lib").mkdir(parents=True)
        shutil.copytree(original / "include", prefix / "include")
        if (original / "share").is_dir():
            shutil.copytree(original / "share", prefix / "share")
        for name in DEPENDENCIES:
            shutil.copy2(original / "lib" / name, prefix / "lib" / name)
        for name in ("cmake", "pkgconfig"):
            if (original / "lib" / name).is_dir():
                shutil.copytree(original / "lib" / name, prefix / "lib" / name)
        sdk = run(["xcrun", "--sdk", sdk_name, "--show-sdk-path"], env)
        build = out / "build" / label / "librime"
        log = out / "logs" / ("librime-" + label + ".log")
        flags = f"-fapplication-extension {PATH_MAP}"
        options = ["-DCMAKE_SYSTEM_NAME=iOS", f"-DCMAKE_OSX_SYSROOT={sdk}", "-DCMAKE_OSX_ARCHITECTURES=arm64",
                   "-DCMAKE_OSX_DEPLOYMENT_TARGET=17.0", "-DCMAKE_BUILD_TYPE=Release",
                   f"-DCMAKE_INSTALL_PREFIX={prefix}", f"-DCMAKE_PREFIX_PATH={prefix}",
                   f"-DBOOST_ROOT={boost}", f"-DBoost_INCLUDE_DIR={boost}",
                   "-DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=NEVER", "-DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=NEVER",
                   "-DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=NEVER", "-DBUILD_SHARED_LIBS=OFF", "-DBUILD_STATIC=ON",
                   "-DBUILD_TEST=OFF", "-DBUILD_SAMPLE=OFF", "-DBUILD_DATA=OFF", "-DBUILD_MERGED_PLUGINS=OFF",
                   "-DENABLE_EXTERNAL_PLUGINS=OFF", "-DENABLE_LOGGING=ON", "-DINSTALL_PRIVATE_HEADERS=ON",
                   f"-DCMAKE_C_FLAGS={flags}", f"-DCMAKE_CXX_FLAGS={flags}"]
        run([CMAKE, "-S", native, "-B", build, *options], env, log)
        run([CMAKE, "--build", build, "--target", "install", "-j", str(jobs)], env, log)
        if not (prefix / "lib/librime.a").is_file():
            raise RuntimeError("librime build produced no archive")

    with ThreadPoolExecutor(max_workers=2) as executor:
        for job in [executor.submit(one, label, folder, sdk) for label, folder, sdk, _ in SLICES]:
            job.result()


def build_plugins_and_link(out, env, boost, jobs):
    cache = ENGINE / "plugin-sources"
    native = out / "src/librime"
    lua_source, lua_plugin = cache / "src/lua-5.4.9", cache / "src/librime-lua"
    grammar_source, predict_source = cache / "src/librime-octagram", cache / "src/librime-predict"
    for source in (lua_source, lua_plugin, grammar_source, predict_source):
        if not source.is_dir():
            raise RuntimeError("plugin source missing: " + str(source))
    if (lua_plugin / ".git").exists() and \
            run(["git", "-C", lua_plugin, "rev-parse", "HEAD"], env) != pin("RIME_LUA_COMMIT", TOOLS / "LUA-VERSIONS.env"):
        raise RuntimeError("librime-lua source does not match RIME_LUA_COMMIT")
    instrumented = out / "src/librime-octagram-instrumented"
    run([sys.executable, TOOLS / "scripts/instrument-grammar.py", grammar_source, instrumented], env)
    toolchain = Path(env["DEVELOPER_DIR"]) / "Toolchains/XcodeDefault.xctoolchain/usr/bin"
    clang, clangxx = toolchain / "clang", toolchain / "clang++"
    framework = out / "out/RimeKit.xcframework"
    framework.mkdir(parents=True)
    write_framework_metadata(framework)

    def one(label, folder, sdk_name, slice_name):
        prefix = out / "prefix" / folder
        generated = out / "build" / label / "librime/src"
        sdk = run(["xcrun", "--sdk", sdk_name, "--show-sdk-path"], env)
        target = "arm64-apple-ios17.0" + ("-simulator" if label == "sim" else "")
        log = out / "logs" / ("plugins-" + label + ".log")
        common = ["-DCMAKE_SYSTEM_NAME=iOS", f"-DCMAKE_OSX_SYSROOT={sdk}", "-DCMAKE_OSX_ARCHITECTURES=arm64",
                  "-DCMAKE_OSX_DEPLOYMENT_TARGET=17.0", "-DCMAKE_BUILD_TYPE=Release",
                  f"-DCMAKE_INSTALL_PREFIX={prefix}", f"-DCMAKE_C_FLAGS={PATH_MAP}", f"-DCMAKE_CXX_FLAGS={PATH_MAP}"]
        lua_build = out / "build" / label / "lua"
        run([CMAKE, "-S", TOOLS / "lua", "-B", lua_build, *common, f"-DLUA_SOURCE={lua_source}",
             f"-DPLUGIN_SOURCE={lua_plugin}", f"-DRIME_SOURCE={native}", f"-DBOOST_SOURCE={boost}",
             f"-DRIME_GENERATED_INCLUDE={generated}"], env, log)
        run([CMAKE, "--build", lua_build, "--target", "install", "-j", str(jobs)], env, log)
        grammar_build = out / "build" / label / "grammar"
        run([CMAKE, "-S", TOOLS / "grammar", "-B", grammar_build, *common, f"-DPLUGIN_SOURCE={instrumented}",
             f"-DRIME_SOURCE={native}", f"-DBOOST_SOURCE={boost}", f"-DDEPENDENCY_PREFIX={prefix}",
             f"-DRIME_GENERATED_INCLUDE={generated}"], env, log)
        run([CMAKE, "--build", grammar_build, "--target", "install", "-j", str(jobs)], env, log)
        objects = out / "objects" / label
        objects.mkdir(parents=True)
        cxx = [clangxx, "-std=c++17", "-O2", "-DNDEBUG", "-fapplication-extension", PATH_MAP, "-c",
               "-DBOOST_DLL_USE_STD_FS", '-DGLOG_DEPRECATED=__attribute__((deprecated))',
               "-DGLOG_EXPORT=", "-DGLOG_NO_EXPORT=", "-DOpencc_BUILT_AS_STATIC", "-DYAML_CPP_STATIC_DEFINE",
               '-DRIME_VERSION="1.17.0"', "-I", native / "src", "-I", native / "include",
               "-I", generated, "-I", prefix / "include", "-I", boost, "-I", TOOLS / "src",
               "-target", target, "-isysroot", sdk]
        objs = []
        for name in ("predict_db", "predict_engine", "predict_module", "predict_translator", "predictor"):
            obj = objects / (name + ".cc.o")
            run([*cxx, "-I", predict_source / "src", predict_source / "src" / (name + ".cc"), "-o", obj], env, log)
            objs.append(obj)
        for name in ("rime_spelling", "rime_display_map", "rime_t9_processor",
                     "rime_lua_link", "rime_grammar_link", "rime_predict_link"):
            obj = objects / (name + ".o")
            run([*cxx, TOOLS / "src" / (name + ".cc"), "-o", obj], env, log)
            objs.append(obj)
        bridge = objects / "rime_bridge.o"
        run([clang, "-std=c11", "-O2", "-fapplication-extension", PATH_MAP, "-c", "-DRB_WITH_LUA=1",
             "-DRB_WITH_GRAMMAR=1", "-DRB_WITH_T9=1", "-DRB_WITH_PREDICT=1", "-I", TOOLS / "src",
             "-I", prefix / "include", "-target", target, "-isysroot", sdk,
             TOOLS / "src/rime_bridge.c", "-o", bridge], env, log)
        objs.append(bridge)
        archives = [prefix / "lib/librime.a", *[prefix / "lib" / name for name in DEPENDENCIES],
                    prefix / "lib/librime-lua.a", prefix / "lib/liblua.a", prefix / "lib/librime-octagram.a"]
        destination = framework / slice_name / "RimeKit.framework"
        write_slice_metadata(destination, prefix, label)
        run([toolchain / "libtool", "-static", "-o", destination / "RimeKit", *archives, *objs], env, log)

    with ThreadPoolExecutor(max_workers=2) as executor:
        for job in [executor.submit(one, *slice_) for slice_ in SLICES]:
            job.result()
    print(f"PASS candidate: {framework}", flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-root", type=Path, required=True,
                        help="fresh directory directly under .local/ios-engine")
    parser.add_argument("--jobs-per-slice", type=int, default=4)
    parser.add_argument("--deps-root", type=Path, default=ENGINE,
                        help="IOS_ROOT that 11-build-deps.sh installed the dependencies under")
    args = parser.parse_args()
    out = args.output_root.absolute()
    if out.parent != ENGINE or out.exists():
        raise SystemExit("output must be a new directory directly under .local/ios-engine")
    if not CMAKE.is_file():
        raise SystemExit("pinned CMake is missing; run Tools/BuildRime first")
    env = dict(os.environ)
    env["DEVELOPER_DIR"] = env.get("DEVELOPER_DIR") or subprocess.check_output(["xcode-select", "-p"], text=True).strip()
    toolchain = Path(env["DEVELOPER_DIR"]) / "Toolchains/XcodeDefault.xctoolchain/usr/bin"
    env.update(CC=str(toolchain / "clang"), CXX=str(toolchain / "clang++"))
    versions = ROOT / "Tools/BuildRime/VERSIONS.env"
    if run(["git", "-C", SOURCE, "rev-parse", "HEAD"], env) != pin("LIBRIME_COMMIT", versions):
        raise SystemExit("librime source does not match LIBRIME_COMMIT")
    run(["git", "-C", SOURCE, "diff", "--exit-code", "--", "src", "include"], env)
    boost = ROOT / ".local/engine/src" / ("boost-" + pin("BOOST_VERSION", versions))
    if not boost.is_dir():
        raise SystemExit("pinned Boost headers missing")
    out.mkdir(mode=0o700)
    (out / "logs").mkdir()
    native = out / "src/librime"
    shutil.copytree(SOURCE, native, ignore=shutil.ignore_patterns(".git", "deps", "build"))
    run(["git", "init", "--quiet", native], env)
    run(["git", "apply", PATCH], env, cwd=native)
    build_core(out, env, boost, args.jobs_per_slice, args.deps_root.absolute())
    build_plugins_and_link(out, env, boost, args.jobs_per_slice)


if __name__ == "__main__":
    main()
