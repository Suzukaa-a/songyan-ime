"""Run the real learning snapshot tests offline without an iOS binary slice."""
import os
import re
import shutil
import subprocess
import sys
import unittest

from swift_probe import ROOT, scratch_directory, swift_environment


@unittest.skipUnless(sys.platform == "darwin", "requires the macOS Swift toolchain")
class LearningBackupFormatTests(unittest.TestCase):
    def test_production_snapshot_parser_and_files(self):
        with scratch_directory("learning-backup-format") as directory:
            source = directory / "Sources/RimeBridge"
            tests = directory / "Tests/RimeBridgeTests"
            source.mkdir(parents=True)
            tests.mkdir(parents=True)
            shutil.copyfile(
                ROOT / "Packages/RimeBridge/Sources/RimeBridge/RimeLearningBackup.swift",
                source / "RimeLearningBackup.swift",
            )
            for filename in ("RimeLearningBackupTests.swift",):
                shutil.copyfile(
                    ROOT / "Packages/RimeBridge/Tests/RimeBridgeTests" / filename,
                    tests / filename,
                )
            (source / "PureFormatBuildGuard.swift").write_text(
                '#if canImport(RimeKit)\n#error("The pure format gate must not import RimeKit")\n#endif\n',
                encoding="utf-8",
            )
            (directory / "Package.swift").write_text(
                """// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "LearningBackupFormatGate",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "RimeBridge"),
        .testTarget(name: "RimeBridgeTests", dependencies: ["RimeBridge"]),
    ]
)
""",
                encoding="utf-8",
            )
            command = [
                "xcrun", "swift", "test", "--package-path", str(directory),
                "--scratch-path", str(directory / "build"),
                "--cache-path", str(directory / "cache"),
                "--config-path", str(directory / "configuration"),
                "--security-path", str(directory / "security"),
                "--manifest-cache", "local", "--disable-dependency-cache",
                "--disable-automatic-resolution", "--jobs", os.environ.get("SWIFT_TEST_JOBS", "4"),
            ]
            if os.environ.get("CI_SWIFTPM_DISABLE_SANDBOX") == "1":
                command.append("--disable-sandbox")
            environment = swift_environment()
            environment["CLANG_MODULE_CACHE_PATH"] = str(directory / "module-cache")
            temporary = directory / "temporary"
            temporary.mkdir()
            environment["TMPDIR"] = str(temporary) + os.sep
            discovery = subprocess.run([*command, "list"], capture_output=True, text=True,
                                       env=environment, timeout=180)
            discovery_output = discovery.stdout + discovery.stderr
            self.assertEqual(discovery.returncode, 0, discovery_output)
            discovered = re.findall(
                r"^RimeBridgeTests\.([A-Za-z_][A-Za-z0-9_]*)/(test[A-Za-z0-9_]+)$",
                discovery.stdout, flags=re.MULTILINE,
            )
            self.assertTrue(discovered, "No production learning tests were discovered\n" + discovery_output)
            self.assertEqual(len(set(discovered)), len(discovered), discovery_output)
            classes = {name for name, _ in discovered}
            self.assertIn("RimeLearningBackupTests", classes,
                          "The real learning test suite must be discovered\n" + discovery_output)
            result = subprocess.run([*command, "--skip-build"], capture_output=True, text=True,
                                    env=environment, timeout=180)
            output = result.stdout + result.stderr
            self.assertEqual(result.returncode, 0, output)
            # Darwin SwiftPM does not consistently implement --xunit-output for XCTest.
            passed = re.findall(
                r"^Test Case '-\[RimeBridgeTests\.([A-Za-z_][A-Za-z0-9_]*) (test[A-Za-z0-9_]+)\]' passed \(",
                output, flags=re.MULTILINE,
            )
            self.assertEqual(len(passed), len(discovered), "Not all discovered tests passed\n" + output)
            self.assertEqual(len(set(passed)), len(passed), "Duplicate test execution\n" + output)
            self.assertEqual(set(passed), set(discovered), "Test discovery/execution mismatch\n" + output)
            self.assertIn(f"Executed {len(discovered)} tests, with 0 failures (0 unexpected)", output)
            print(f"Verified {len(discovered)} real learning tests across {len(classes)} suites")
            print(output, end="" if output.endswith("\n") else "\n")


if __name__ == "__main__":
    unittest.main()
