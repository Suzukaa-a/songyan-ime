#!/usr/bin/env python3
"""Compile the RimeLeversSupport C adapter for the hand-built harness scripts.

The learning bridge ships as a real C target (Sources/RimeLeversSupport) that
SPM compiles with `-fno-modules` against the ORIGINAL public librime headers
(`Bool` stays `int`; the adapter static-asserts that ABI). Every manual swiftc
harness must reproduce those exact conditions. This helper is the single
implementation shared by all of them: it compiles the adapter once into a
deterministic stage so each script only adds the emitted module map, include
path and object to its own swiftc/link invocation.

Deterministic outputs, all inside --output-dir:
  RimeLeversSupport.o            adapter object; link it before librime/RimeKit
  module/RimeLeversSupport.h     copied public adapter header
  module/module.modulemap        `module RimeLeversSupport`
  rimekit-view/RimeKit/*.h       scratch include view for the `<RimeKit/...>`
                                 includes (the macOS prefix keeps the public
                                 headers flat; the framework nests them)

The view only ever COPIES public headers already present in --kit-include-dir;
nothing under a prefix, the Vendored framework or this package is modified.
A missing header or adapter source fails loudly instead of fabricating a stage.
"""
import shlex
import shutil
import subprocess
from argparse import ArgumentParser
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SOURCE_DIR = ROOT / "Packages/RimeBridge/Sources/RimeLeversSupport"
# The adapter includes rime_api.h and rime_levers_api.h directly; the two
# rime_api*.h companions are copied too so the original umbrella set stays
# self-consistent inside the scratch view.
KIT_HEADERS = [
    "rime_api.h",
    "rime_api_deprecated.h",
    "rime_api_stdbool.h",
    "rime_levers_api.h",
]


def main():
    parser = ArgumentParser(description=__doc__)
    parser.add_argument("--sdk", required=True, help="SDK path passed as -isysroot")
    parser.add_argument("--target", required=True, help="Clang target triple")
    parser.add_argument("--kit-include-dir", required=True, type=Path,
                        help="directory holding the original public librime headers (flat)")
    parser.add_argument("--output-dir", required=True, type=Path,
                        help="fresh stage directory for module map + object")
    parser.add_argument("--cc", default="clang",
                        help="C compiler command, whitespace-split (default: clang); "
                             "e.g. --cc \"xcrun --sdk iphonesimulator clang\"")
    args = parser.parse_args()
    cc = shlex.split(args.cc)

    c_file = SOURCE_DIR / "RimeLeversSupport.c"
    adapter_header = SOURCE_DIR / "include/RimeLeversSupport.h"
    for required in (c_file, adapter_header):
        if not required.is_file():
            raise SystemExit(f"missing adapter source: {required}")
    kit_dir = args.kit_include_dir
    for name in KIT_HEADERS:
        if not (kit_dir / name).is_file():
            raise SystemExit(f"public librime header missing in {kit_dir}: {name}")

    out = args.output_dir
    module_dir = out / "module"
    view = out / "rimekit-view" / "RimeKit"
    module_dir.mkdir(parents=True, exist_ok=True)
    view.mkdir(parents=True, exist_ok=True)
    for name in KIT_HEADERS:
        shutil.copyfile(kit_dir / name, view / name)
    shutil.copyfile(adapter_header, module_dir / "RimeLeversSupport.h")
    (module_dir / "module.modulemap").write_text(
        "module RimeLeversSupport {\n"
        "    header \"RimeLeversSupport.h\"\n"
        "    export *\n"
        "}\n")

    output_object = out / "RimeLeversSupport.o"
    subprocess.run([
        *cc, "-std=c11", "-O2", "-fno-modules",
        "-target", args.target, "-isysroot", args.sdk,
        # The adapter's own header (quoted include) plus the scratch view that
        # maps <RimeKit/rime_api.h> etc. onto the flat public headers.
        "-I", str(SOURCE_DIR / "include"),
        "-I", str(out / "rimekit-view"),
        "-c", str(c_file), "-o", str(output_object),
    ], check=True)
    print(f"RimeLeversSupport ready: {output_object}")
    print(f"Swift import flags: -Xcc -fmodule-map-file={module_dir / 'module.modulemap'} -I {module_dir}")


if __name__ == "__main__":
    main()
