"""Production option persistence: full identities, FIFO, revisions, and failures."""
import sys
import unittest

from swift_probe import ROOT, run_swift


@unittest.skipUnless(sys.platform == "darwin", "requires the macOS Swift toolchain")
class OptionPersistenceTests(unittest.TestCase):
    def test_cache_ordering_errors_and_atomic_store(self):
        source = (ROOT / "Apps/SharedKeyboard/OptionStore.swift").read_text()
        source = source.split("/// Conservative reader", 1)[0]
        source = source.replace("import KeyboardCore\n", "").replace("import RimeKit\n", "")
        checks = (ROOT / "Tests/IOS/Fixtures/option-persistence-main.swift").read_text()
        print(run_swift(source, checks, prefix="option-persistence", library=True), end="")


if __name__ == "__main__":
    unittest.main()
