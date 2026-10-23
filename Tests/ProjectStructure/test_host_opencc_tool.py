#!/usr/bin/env python3
"""The macOS host OpenCC dictionary tool and the iOS OpenCC data step.

OpenCC builds its .ocd2 dictionaries by running its own `opencc_dict`. In
data/CMakeLists.txt that name is an executable *target*, so CMake substitutes the
freshly cross-built binary path into the command and never consults PATH — for the
device slice that binary is an arm64 iOS Mach-O that cannot run on the build
machine. CMake does prepend CMAKE_CROSSCOMPILING_EMULATOR to exactly that command,
which is how the pinned macOS host tool is wired in. These tests cover the
generated recipe, the wrapper argv contract and, where it is built, the real tool.
"""

import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "Tools/BuildRimeIOS/scripts"
EMULATOR = SCRIPTS / "lib/opencc-dict-emulator.sh"
BUILD_SCRIPT = SCRIPTS / "14-build-host-opencc.sh"
ENGINE_ROOT = ROOT / ".local/engine"

FIXTURE_ENTRIES = "汉字\t漢字\n会议\t會議\n简化\t簡化\n"
FIXTURE_TEXT = "会议汉语简化"
FIXTURE_TRADITIONAL = "會議漢語簡化"
# OpenCC installs 16 .ocd2 dictionaries next to its 14 JSON configs.
DICTIONARY_COUNT = 16


def scratch_directory(prefix):
    """Project convention: temporary files live in the git-ignored .scratch/."""
    scratch = ROOT / ".scratch"
    scratch.mkdir(exist_ok=True)
    return tempfile.TemporaryDirectory(prefix=prefix, dir=scratch)


def engine_root():
    """The engine root the scripts resolve to, or None when it is absent."""
    for candidate in (os.environ.get("HOST_ENGINE_ROOT"), os.environ.get("ENGINE_WORK"),
                      str(ENGINE_ROOT)):
        if candidate and (pathlib.Path(candidate) / "src/librime/deps/opencc").is_dir():
            return pathlib.Path(candidate)
    return None


def cmake_path():
    """The pinned cmake, an engine root override, or any cmake on PATH."""
    candidates = []
    if os.environ.get("HOST_CMAKE"):
        candidates.append(pathlib.Path(os.environ["HOST_CMAKE"]))
    for root in (os.environ.get("HOST_ENGINE_ROOT"), os.environ.get("ENGINE_WORK"), str(ENGINE_ROOT)):
        if not root:
            continue
        for relative in ("tools/cmake/CMake.app/Contents/bin/cmake", "tools/cmake/bin/cmake"):
            candidates.append(pathlib.Path(root) / relative)
    for candidate in candidates:
        if os.access(candidate, os.X_OK):
            return str(candidate)
    return shutil.which("cmake")


def run(command, **kwargs):
    return subprocess.run(list(command), text=True, capture_output=True, **kwargs)


class EmulatorWrapperTests(unittest.TestCase):
    """The wrapper replaces the cross-built tool and refuses anything else."""

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="opencc-emulator-")
        self.addCleanup(self.directory.cleanup)
        self.work = pathlib.Path(self.directory.name)
        self.argfile = self.work / "arguments.txt"
        self.wrapper = self.work / "opencc_dict-host"
        shutil.copy2(EMULATOR, self.wrapper)
        self.wrapper.chmod(0o755)
        host_tool = self.work / "opencc_dict"
        host_tool.write_text(
            "#!" + sys.executable + "\n"
            "import os, pathlib, sys\n"
            "pathlib.Path(os.environ['OPENCC_ARGUMENTS']).write_text('\\n'.join(sys.argv[1:]) + '\\n')\n",
            encoding="utf-8")
        host_tool.chmod(0o755)

    def arguments_seen_by_host_tool(self):
        return self.argfile.read_text(encoding="utf-8").splitlines()

    def test_wrapper_runs_the_host_tool_with_the_dictionary_arguments(self):
        target = self.work / "build/src/tools/opencc_dict"
        environment = dict(os.environ, OPENCC_ARGUMENTS=str(self.argfile))
        result = run([str(self.wrapper), str(target), "--input", "in.txt",
                      "--output", "out.ocd2", "--from", "text", "--to", "ocd2"], env=environment)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.arguments_seen_by_host_tool(),
                         ["--input", "in.txt", "--output", "out.ocd2", "--from", "text", "--to", "ocd2"])

    def test_wrapper_refuses_to_replace_a_different_executable(self):
        environment = dict(os.environ, OPENCC_ARGUMENTS=str(self.argfile))
        result = run([str(self.wrapper), str(self.work / "build/src/tools/opencc_phrase_extract"),
                      "--from", "text", "--to", "ocd2"], env=environment)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("opencc_dict", result.stderr)
        self.assertFalse(self.argfile.exists())

    def test_wrapper_requires_a_target_argument(self):
        environment = dict(os.environ, OPENCC_ARGUMENTS=str(self.argfile))
        result = run([str(self.wrapper)], env=environment)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.argfile.exists())


class CrossConfigureGeneratorTests(unittest.TestCase):
    """Reproduce what CMake generates for OpenCC's data step.

    A cross target whose executable is named opencc_dict inside
    add_custom_command(COMMAND ...) is the shape OpenCC's data/CMakeLists.txt
    uses. Configured with the emulator the recipe names the emulator followed by
    the built tool, which is why the wrapper receives that path in argv[1].
    """

    def setUp(self):
        self.cmake = cmake_path()
        if not self.cmake:
            self.skipTest("no cmake available to reproduce the generated recipe")
        if not shutil.which("make"):
            self.skipTest("reproducing the recipe needs the Unix Makefiles generator")
        self.directory = tempfile.TemporaryDirectory(prefix="opencc-cross-configure-")
        self.addCleanup(self.directory.cleanup)
        self.work = pathlib.Path(self.directory.name)
        (self.work / "src/tools").mkdir(parents=True)
        (self.work / "src/data").mkdir(parents=True)
        (self.work / "src/CMakeLists.txt").write_text(
            "cmake_minimum_required(VERSION 3.20)\nproject(opencc_dict_probe C)\n"
            "add_subdirectory(tools)\nadd_subdirectory(data)\n", encoding="utf-8")
        (self.work / "src/tools/CMakeLists.txt").write_text(
            "add_executable(opencc_dict main.c)\n"
            "add_executable(opencc_phrase_extract main.c)\n", encoding="utf-8")
        (self.work / "src/tools/main.c").write_text("int main(void) { return 0; }\n", encoding="utf-8")
        (self.work / "src/data/CMakeLists.txt").write_text(
            "add_custom_target(Dictionaries ALL\n"
            "  COMMAND opencc_dict --input ${CMAKE_CURRENT_SOURCE_DIR}/STCharacters.txt"
            " --output STCharacters.ocd2 --from text --to ocd2\n"
            '  COMMENT "Building STCharacters.ocd2")\n', encoding="utf-8")

    def configure(self, build, emulator=None):
        compiler = shutil.which("cc") or shutil.which("clang")
        if not compiler:
            self.skipTest("no C compiler available for the generator reproduction")
        command = [self.cmake, "-S", str(self.work / "src"), "-B", str(build),
                   "-G", "Unix Makefiles", "-DCMAKE_SYSTEM_NAME=Generic",
                   "-DCMAKE_C_COMPILER=" + compiler, "-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY"]
        if emulator:
            command.append("-DCMAKE_CROSSCOMPILING_EMULATOR=" + emulator)
        return run(command)

    def recipe_command(self, build):
        recipe = build / "data/CMakeFiles/Dictionaries.dir/build.make"
        if not recipe.is_file():
            self.skipTest("the generator did not emit a Makefiles recipe")
        lines = [line for line in recipe.read_text(encoding="utf-8").splitlines()
                 if "opencc_dict" in line and "--input" in line]
        self.assertEqual(len(lines), 1, lines)
        return lines[0].split("&&", 1)[-1].strip()

    def test_emulator_precedes_the_cross_built_tool_in_the_generated_recipe(self):
        emulator = str(self.work / "prefix-mac/bin/opencc_dict-host")
        build = self.work / "build-emulated"
        result = self.configure(build, emulator)
        self.assertEqual(result.returncode, 0, result.stderr)
        command = self.recipe_command(build)
        self.assertTrue(command.startswith(emulator + " "), command)
        # The cross-built tool path follows the emulator, so the wrapper can drop it.
        self.assertIn(str(build / "tools/opencc_dict"), command)
        self.assertNotIn("opencc_phrase_extract", command)


class InstalledHostToolTests(unittest.TestCase):
    """Real conversion checks, skipped where the tool has not been built."""

    def setUp(self):
        self.tool = ROOT / ".local/ios-engine/prefix-mac/bin/opencc_dict"
        if not os.access(self.tool, os.X_OK):
            self.skipTest("the macOS host opencc_dict is not built here; run "
                          "Tools/BuildRimeIOS/scripts/14-build-host-opencc.sh")

    def test_text_dictionary_round_trips_through_ocd2(self):
        with tempfile.TemporaryDirectory(prefix="opencc-dict-roundtrip-") as temporary:
            work = pathlib.Path(temporary)
            source = work / "known.tsv"
            source.write_text(FIXTURE_ENTRIES, encoding="utf-8")
            compiled = work / "known.ocd2"
            result = run([str(self.tool), "--input", str(source), "--output", str(compiled),
                          "--from", "text", "--to", "ocd2"])
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertGreater(compiled.stat().st_size, 0)
            expanded = work / "known.roundtrip.tsv"
            result = run([str(self.tool), "--input", str(compiled), "--output", str(expanded),
                          "--from", "ocd2", "--to", "text"])
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(sorted(expanded.read_text(encoding="utf-8").splitlines()),
                             sorted(FIXTURE_ENTRIES.splitlines()))

    def test_installed_data_converts_known_text(self):
        prefix = self.tool.parents[1]
        config = prefix / "share/opencc/s2t.json"
        if not config.is_file():
            self.skipTest("the host prefix has no installed OpenCC data")
        self.assertEqual(len(list(config.parent.glob("*.ocd2"))), DICTIONARY_COUNT)
        with tempfile.TemporaryDirectory(prefix="opencc-s2t-") as temporary:
            work = pathlib.Path(temporary)
            source = work / "in.txt"
            target = work / "out.txt"
            source.write_text(FIXTURE_TEXT + "\n", encoding="utf-8")
            result = run([str(prefix / "bin/opencc"), "-c", str(config),
                          "-i", str(source), "-o", str(target)])
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(target.read_text(encoding="utf-8").strip(), FIXTURE_TRADITIONAL)

    def test_emulator_wrapper_reaches_the_installed_tool(self):
        wrapper = self.tool.parent / "opencc_dict-host"
        if not os.access(wrapper, os.X_OK):
            self.skipTest("the emulator wrapper is not installed next to the host tool")
        result = run([str(wrapper), str(self.tool), "--version"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("1.1.9", result.stdout + result.stderr)


class HostPrefixIntegrityTests(unittest.TestCase):
    """A reused host prefix must not be trusted on its metadata alone."""

    def setUp(self):
        self.prefix = ROOT / ".local/ios-engine/prefix-mac"
        if not os.access(self.prefix / "bin/opencc_dict", os.X_OK):
            self.skipTest("the macOS host opencc_dict is not built here; run "
                          "Tools/BuildRimeIOS/scripts/14-build-host-opencc.sh")
        if not engine_root():
            self.skipTest("the pinned sources are not fetched, so --check cannot run")
        self.temporary = scratch_directory("host-opencc-integrity-")
        self.addCleanup(self.temporary.cleanup)
        self.copy = pathlib.Path(self.temporary.name) / "prefix-mac"
        shutil.copytree(self.prefix, self.copy, symlinks=True)

    def check(self, environment=None):
        values = dict(os.environ, HOST_OPENCC_PREFIX=str(self.copy))
        values.update(environment or {})
        return run([str(BUILD_SCRIPT), "--check"], env=values)

    def test_untouched_copy_passes_its_check(self):
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("identity matches", result.stdout)

    def test_modified_executable_is_rejected_even_with_intact_metadata(self):
        tool = self.copy / "bin/opencc_dict"
        payload = bytearray(tool.read_bytes())
        payload[-1] ^= 0xFF
        tool.chmod(0o755)
        tool.write_bytes(bytes(payload))
        result = self.check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("bin/opencc_dict changed", result.stderr)

    def test_modified_library_is_rejected(self):
        library = self.copy / "lib/libopencc.a"
        with library.open("ab") as stream:
            stream.write(b"tampered")
        result = self.check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("lib/libopencc.a changed", result.stderr)

    def test_identity_without_an_artifact_entry_is_rejected(self):
        identity = self.copy / "host-opencc-identity.json"
        recorded = json.loads(identity.read_text(encoding="utf-8"))
        del recorded["artifacts"]["bin/opencc"]
        identity.write_text(json.dumps(recorded, indent=2, sort_keys=True), encoding="utf-8")
        result = self.check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("recorded artifacts are not exactly", result.stderr)

    def test_malformed_recorded_digest_is_rejected(self):
        identity = self.copy / "host-opencc-identity.json"
        recorded = json.loads(identity.read_text(encoding="utf-8"))
        recorded["artifacts"]["bin/opencc"] = {"bytes": 1, "sha256": "not-a-digest"}
        identity.write_text(json.dumps(recorded, indent=2, sort_keys=True), encoding="utf-8")
        result = self.check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("malformed", result.stderr)

    def test_check_runs_without_querying_an_ios_sdk(self):
        # A stub that fails every SDK lookup shows the host path needs no iOS SDK;
        # only `xcrun --find` for the host compiler is allowed through.
        stub_directory = pathlib.Path(self.temporary.name) / "stub-bin"
        stub_directory.mkdir()
        stub = stub_directory / "xcrun"
        stub.write_text("#!/bin/sh\n"
                        "case \"$1\" in\n"
                        "  --find) exec /usr/bin/xcrun \"$@\" ;;\n"
                        "esac\n"
                        "echo \"xcrun: SDK queries are unavailable in this test\" >&2\n"
                        "exit 1\n", encoding="utf-8")
        stub.chmod(0o755)
        result = self.check({"PATH": str(stub_directory) + os.pathsep + os.environ["PATH"]})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("identity matches", result.stdout)


if __name__ == "__main__":
    unittest.main()