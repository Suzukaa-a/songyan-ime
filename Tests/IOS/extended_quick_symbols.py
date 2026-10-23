"""Extended production quick-symbol probes; no Simulator or real App Group."""
import subprocess
import sys
import unittest

from swift_probe import ROOT, compile_swift, run, run_swift, scratch_directory, swift_environment


@unittest.skipUnless(sys.platform == "darwin", "requires the macOS Swift toolchain")
class QuickSymbolTests(unittest.TestCase):
    def test_async_model_save_and_touch_order(self):
        model = (ROOT / "Apps/SharedKeyboard/T9QuickSymbolModel.swift").read_text()
        checks = (ROOT / "Tests/IOS/Fixtures/symbol-model-main.swift").read_text()
        print(run_swift(model, "import LayoutKit\n" + checks,
                        prefix="symbol-model", library=True, dependencies=("LayoutKit",)), end="")

    def test_independent_processes_merge_shared_slots(self):
        client = '''import Foundation
import LayoutKit
let store = T9QuickSymbolStore(directory: URL(fileURLWithPath: CommandLine.arguments[1]))
let operation = CommandLine.arguments[2]
if operation == "default" { print(T9QuickSymbolStore.defaultSymbols) }
else if operation == "read" { print(try store.load().symbols) }
else { print(try store.replaceSlot(Int(operation)!, with: CommandLine.arguments[3]).symbols) }
'''
        with scratch_directory("shared-symbols") as directory:
            main = directory / "main.swift"
            main.write_text(client, encoding="utf-8")
            binary = compile_swift(directory, [main], dependencies=("LayoutKit",))
            root = directory / "store"
            manifest = root / "t9-quick-symbols.json"

            def call(operation, value="", target=root):
                return run([str(binary), str(target), operation, value]).strip()

            defaults = call("default")
            self.assertEqual(defaults, "，。？！、…")
            self.assertEqual(call("read"), defaults)
            self.assertFalse(manifest.exists())

            # Concurrent writers are separate processes, not mocks of the lock.
            children = []
            try:
                for index, value in enumerate("ABCDEF"):
                    children.append(subprocess.Popen(
                        [str(binary), str(root), str(index), value], env=swift_environment(),
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True))
                for child in children:
                    stdout, stderr = child.communicate(timeout=30)
                    self.assertEqual(child.returncode, 0, stdout + stderr)
            finally:
                for child in children:
                    if child.poll() is None:
                        child.kill()
                        child.communicate()
            self.assertEqual(call("read"), "ABCDEF")
            self.assertEqual(call("2", "#"), "AB#DEF")
            self.assertEqual(call("read"), "AB#DEF")
            print("PASS: independent writers merge slots; fresh readers see the latest shared value")


if __name__ == "__main__":
    unittest.main()
