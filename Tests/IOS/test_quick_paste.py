"""System-authorized quick paste: extension SDK check and real-file production probes."""
import sys
import unittest

from swift_probe import ROOT, controller_sources, production_modules, run, scratch_directory

SOURCE = ROOT / "Apps/SharedKeyboard/QuickPasteView.swift"
FIXTURE = ROOT / "Tests/IOS/Fixtures/QuickPaste.swift"


@unittest.skipUnless(sys.platform == "darwin", "requires the macOS Swift toolchain")
class QuickPasteProductionTests(unittest.TestCase):
    def test_production_system_control_typechecks_for_an_extension(self):
        sdk = run(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"]).strip()
        with scratch_directory("quick-paste-sdk") as directory:
            run(["xcrun", "swiftc", "-swift-version", "5", "-typecheck", "-parse-as-library",
                 "-application-extension", "-target", "arm64-apple-ios17.0-simulator",
                 "-sdk", sdk, "-module-cache-path", str(directory / "module-cache"), str(SOURCE)])

    def test_real_file_reader_model_and_production_literal_outlet(self):
        with scratch_directory("quick-paste") as directory:
            modules = production_modules()
            # Reuse the existing platform/backend seam, never rewrite controller logic.
            existing = (ROOT / "Tests/IOS/Fixtures/ControllerInputRegressions.swift").read_text(encoding="utf-8")
            platform = directory / "PlatformSeam.swift"
            platform.write_text(existing.split("@main struct ControllerInputChecks", 1)[0], encoding="utf-8")
            controller = controller_sources(directory)
            queue = directory / "EngineOpQueue.swift"
            queue.write_text((ROOT / "Apps/SharedKeyboard/EngineOpQueue.swift").read_text(encoding="utf-8"), encoding="utf-8")
            binary = directory / "probe"
            run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
                 "-I", str(modules), "-L", str(modules),
                 "-module-cache-path", str(directory / "module-cache"),
                 "-lKeyboardCore", "-lLayoutKit", "-lCandidateKit",
                 "-Xlinker", "-rpath", "-Xlinker", str(modules),
                 str(SOURCE), *map(str, controller), str(queue), str(platform), str(FIXTURE), "-o", str(binary)])
            runtime = directory / "runtime"
            runtime.mkdir()
            print(run([str(binary), str(runtime)]), end="")


if __name__ == "__main__":
    unittest.main()
