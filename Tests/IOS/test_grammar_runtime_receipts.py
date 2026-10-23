"""Exercise production grammar receipt storage with an isolated root on macOS."""
import sys
import unittest

from swift_probe import CORE, ROOT, run_swift, section


@unittest.skipUnless(sys.platform == "darwin", "requires the macOS Swift toolchain")
class GrammarRuntimeReceiptTests(unittest.TestCase):
    def test_exact_runtime_identity_and_safe_paths(self):
        shared = ROOT / "Apps/SharedKeyboard"
        receipts = (shared / "GrammarRuntimeReceiptStore.swift").read_text()
        store = (shared / "KeyboardRecipeStore.swift").read_text()
        production = (section(receipts, "public enum GrammarRuntimeReceiptStore {", "\n}\n") + "\n}\n"
                      + store[store.index("/// Sorted keys keep"):])
        model_path = (CORE / "Support/GrammarModelPath.swift").read_text()
        shim = '''
import Foundation
public enum KeyboardRecipeStore {
    public struct Activation {
        public var generation: String
        public var selectedSchemaID: String?
        public var recipeEnabled: Bool
    }
    public struct StoreError: Error { public let message: String }
    public static func root() throws -> URL { fatalError("test must inject root") }
    public static func readRoot() throws -> URL { fatalError("test must inject root") }
}
'''
        probe = (ROOT / "Tests/IOS/Fixtures/grammar-receipts-main.swift").read_text()
        print(run_swift(shim + model_path + production, probe,
                        prefix="grammar-receipts", library=True), end="")


if __name__ == "__main__":
    unittest.main()
