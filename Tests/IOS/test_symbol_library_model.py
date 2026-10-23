"""Production symbol models/stores: asynchronous I/O and truthful management state.

Only App Group resolution and Bundle.module are fixture seams. Compilation is
performed by a test case, never as a side effect of unittest discovery/import.
"""
import sys
import unittest

from swift_probe import ROOT, compile_swift, run, scratch_directory


@unittest.skipUnless(sys.platform == "darwin", "requires the macOS Swift toolchain")
class SymbolLibraryModelTests(unittest.TestCase):
    def test_ordering_responsiveness_errors_and_security_scope(self):
        source = (ROOT / "Apps/SharedKeyboard/SymbolLibraryModel.swift").read_text()
        model = source.split("// MARK: - Serial symbol store (the main thread only publishes results)", 1)[1]
        paths = (ROOT / "Apps/SharedKeyboard/KeyboardResourceReadQueue.swift").read_text()
        queue = "public enum KeyboardResourceReadQueue {" + paths.split("public enum KeyboardResourceReadQueue {", 1)[1]
        management = (ROOT / "Apps/HostApp/SymbolCatalogManagementView.swift").read_text()
        management = management[management.index("private final class SymbolCatalogManagementWorker:"):]
        management = management.split("/// Host-side JSON catalog management.", 1)[0]
        checks = (ROOT / "Tests/IOS/Fixtures/symbol-library-main.swift").read_text()
        stores = ROOT / "Packages/QuickContentKit/Sources/QuickContentKit"
        with scratch_directory("symbol-library") as directory:
            generated = directory / "SymbolModelProbe.swift"
            # Private worker queues stay in the same file as the behavioral checks.
            generated.write_text("import Foundation\nimport Combine\n" + queue + "\n" + model + "\n" + management + "\n" + checks)
            binary = compile_swift(directory, [generated, *sorted(stores.rglob("*.swift"))], library=True)
            runtime = directory / "runtime"
            runtime.mkdir()
            print(run([str(binary), str(runtime), str(stores / "Resources")]), end="")

    def test_read_only_keyboard_reads_the_shared_library(self):
        source = (ROOT / "Apps/SharedKeyboard/SymbolLibraryModel.swift").read_text()
        storage = "public enum SymbolLibraryStorage {" + source.split("public enum SymbolLibraryStorage {", 1)[1]
        storage = storage.split("// MARK: - Serial symbol store", 1)[0]
        stores = ROOT / "Packages/QuickContentKit/Sources/QuickContentKit"
        probe = r'''
import Foundation
import OSLog
import os

extension Logger { static let keyboardStorage = Logger(subsystem: "probe", category: "probe") }
enum KeyboardRecipeStore {
    nonisolated(unsafe) static var canWriteSharedContainer = false
    nonisolated(unsafe) static var container: URL!
    static func sharedContainerURL() -> URL? { container }
}
extension Bundle { static var module: Bundle { .main } }

@main struct Main {
    static func main() throws {
        let group = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("group")
        KeyboardRecipeStore.container = group
        let shared = group.appendingPathComponent(SymbolCatalogStore.sharedDirectoryName, isDirectory: true)
        let readOnly = SymbolLibraryStorage.defaultStoreDirectory()
        precondition(readOnly == shared, "a read-only keyboard must read the host's library")
        precondition(!FileManager.default.fileExists(atPath: group.path), "a read-only resolution must not write")
        precondition(!SymbolLibraryStorage.allowsWrites(to: shared))
        KeyboardRecipeStore.canWriteSharedContainer = true
        precondition(SymbolLibraryStorage.defaultStoreDirectory() == shared)
        precondition(FileManager.default.fileExists(atPath: shared.path), "a writable resolution probes the directory")
        precondition(SymbolLibraryStorage.allowsWrites(to: shared))
        print("PASS without Full Access the shared symbol library is read in place, uncached and unwritten")
    }
}
'''
        with scratch_directory("symbol-storage") as directory:
            generated = directory / "StorageProbe.swift"
            generated.write_text("import Foundation\nimport OSLog\nimport os\n" + storage + "\n" + probe)
            binary = compile_swift(directory, [generated, *sorted(stores.rglob("*.swift"))], library=True)
            runtime = directory / "runtime"
            runtime.mkdir()
            print(run([str(binary), str(runtime)]), end="")


if __name__ == "__main__":
    unittest.main()
