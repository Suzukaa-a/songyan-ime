"""External literal privacy boundary on the full production controller and session."""
import sys
import unittest

from swift_probe import ROOT, controller_sources, production_modules, run, scratch_directory

FIXTURE = ROOT / "Tests/IOS/Fixtures/ExternalLiteral.swift"


@unittest.skipUnless(sys.platform == "darwin", "requires macOS Swift")
class ExternalLiteralProductionTests(unittest.TestCase):
    def test_real_controller_privacy_reentrancy_learning_and_failures(self):
        with scratch_directory("external-literal") as directory:
            modules = production_modules()
            platform = directory / "PlatformSeam.swift"
            existing = (ROOT / "Tests/IOS/Fixtures/ControllerInputRegressions.swift").read_text(encoding="utf-8")
            platform.write_text(existing.split("@main struct ControllerInputChecks", 1)[0], encoding="utf-8")
            production = controller_sources(directory)
            queue = directory / "EngineOpQueue.swift"
            queue.write_text((ROOT / "Apps/SharedKeyboard/EngineOpQueue.swift").read_text(encoding="utf-8"), encoding="utf-8")
            binary = directory / "probe"
            run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
                 "-I", str(modules), "-L", str(modules),
                 "-module-cache-path", str(directory / "module-cache"),
                 "-lKeyboardCore", "-lLayoutKit", "-lCandidateKit",
                 "-Xlinker", "-rpath", "-Xlinker", str(modules),
                 *map(str, production), str(queue), str(platform), str(FIXTURE), "-o", str(binary)])
            print(run([str(binary)]), end="")


if __name__ == "__main__":
    unittest.main()
