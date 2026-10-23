"""External literal delivery must not retain its payload in repeat memory."""
import sys
import unittest

from swift_probe import ROOT, run_swift

CORE = ROOT / "Packages/KeyboardCore/Sources/KeyboardCore/QuickInsert/QuickInsertCore.swift"
STATE = ROOT / "Apps/SharedKeyboard/QuickInsertState.swift"
FIXTURE = ROOT / "Tests/IOS/Fixtures/ExternalInsertMemory.swift"


@unittest.skipUnless(sys.platform == "darwin", "requires the macOS Swift toolchain")
class ExternalInsertMemoryTests(unittest.TestCase):
    def test_real_core_and_state_external_payload_suppression(self):
        # Remove only the package import; compile the complete production types.
        state = STATE.read_text(encoding="utf-8").replace("import KeyboardCore\n", "")
        source = CORE.read_text(encoding="utf-8") + "\n" + state
        checks = FIXTURE.read_text(encoding="utf-8")
        output = run_swift(source, checks, prefix="external-insert-memory", library=True)
        self.assertEqual(output.count("PASS:"), 8)
        print(output, end="")


if __name__ == "__main__":
    unittest.main()
