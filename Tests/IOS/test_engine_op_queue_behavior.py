"""Exercise the production engine queue without a native engine or iOS runtime."""
import sys
import unittest

from swift_probe import ROOT, run_swift


@unittest.skipUnless(sys.platform == "darwin", "requires the macOS Swift toolchain")
class EngineOpQueueTests(unittest.TestCase):
    def test_serial_off_main_error_propagation(self):
        module = (ROOT / "Apps/SharedKeyboard/EngineOpQueue.swift").read_text()
        checks = (ROOT / "Tests/IOS/Fixtures/engine-queue-main.swift").read_text()
        print(run_swift(module, checks, prefix="engine-queue"), end="")


if __name__ == "__main__":
    unittest.main()
