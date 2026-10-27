"""Compile production LayoutManager and LayoutKit to exercise real asynchronous imports."""
import sys
import unittest

from swift_probe import CORE, ROOT, compile_swift, run, scratch_directory, section

# LayoutManager now reads the machine's keyboard-switch requirement through this shared helper.
REQUIREMENTS_STUB = ROOT / "Tests/IOS/Fixtures/KeyboardSystemRequirementsProbe.swift"

CHECKS = r'''
@MainActor enum SecurityScopeProbe {
    static var active = 0
    static var starts = 0
    static var stops = 0
}
extension URL {
    @MainActor func probeStartAccessing() -> Bool {
        SecurityScopeProbe.active += 1
        SecurityScopeProbe.starts += 1
        return true
    }
    @MainActor func probeStopAccessing() {
        SecurityScopeProbe.active -= 1
        SecurityScopeProbe.stops += 1
    }
}
enum LayoutStoreLocation {
    case local(URL), shared(URL)
    var url: URL { switch self { case .local(let url), .shared(let url): return url } }
    var isShared: Bool { if case .shared = self { return true }; return false }
}
enum RimePaths {
    static var root = URL(fileURLWithPath: CommandLine.arguments[1])
    static func layoutStoreDirectory() -> LayoutStoreLocation {
        precondition(!Thread.isMainThread, "directory I/O ran on main thread")
        return .local(root.appendingPathComponent("catalog"))
    }
    static func layoutStoreReadLocation() -> LayoutStoreLocation {
        .local(root.appendingPathComponent("catalog"))
    }
}

@main struct Probe {
    @MainActor static func main() async throws {
        let source = RimePaths.root.appendingPathComponent("layout.json")
        try BuiltinLayouts.qwerty26.encoded().write(to: source)
        let manager = LayoutManager.shared
        while manager.location == nil { await Task.yield() }
        let baseline = manager.registry

        // Hold the production serial queue, then start import. Returning to this
        // MainActor task while import is pending proves it has suspended for I/O.
        let semaphore = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        let blocker = Task.detached {
            try await HostConfigIOQueue.async {
                precondition(!Thread.isMainThread)
                entered.signal()
                precondition(semaphore.wait(timeout: .now() + 10) == .success)
            }
        }
        await Task.detached { precondition(entered.wait(timeout: .now() + 10) == .success) }.value
        let first = Task { try await manager.readImport(source) }
        while !manager.isImporting { await Task.yield() }
        do {
            _ = try await manager.readImport(source)
            fatalError("duplicate import accepted")
        } catch let error as LayoutError {
            precondition(error == .invalid("正在导入键盘布局，请稍候。"))
        }
        precondition(manager.isImporting, "duplicate request cleared active import")
        precondition(SecurityScopeProbe.active == 1 && SecurityScopeProbe.starts == 1 && SecurityScopeProbe.stops == 0)
        // Changing the actual file while the queue is blocked proves file reading
        // occurs inside the queued work, not synchronously before its await.
        let changed = BuiltinLayouts.qwerty26.renamed("后台实际读取")
        try changed.encoded().write(to: source)
        semaphore.signal()
        try await blocker.value
        let imported = try await first.value
        precondition(imported == changed)
        precondition(!manager.isImporting)
        precondition(SecurityScopeProbe.active == 0 && SecurityScopeProbe.starts == SecurityScopeProbe.stops)
        precondition(manager.registry == baseline, "draft import wrote registry")
        precondition(!FileManager.default.fileExists(atPath: RimePaths.root.appendingPathComponent("catalog/layouts.json").path))

        var oversized = try changed.encoded()
        oversized.append(Data(repeating: 0x20, count: LayoutResourceBudget.definitionBytes))
        try oversized.write(to: source)
        do { _ = try await manager.readImport(source); fatalError("oversized import accepted") }
        catch is LayoutError { }
        precondition(!manager.isImporting)
        precondition(SecurityScopeProbe.active == 0 && SecurityScopeProbe.starts == SecurityScopeProbe.stops)
        precondition(manager.registry == baseline)

        let invalid = LayoutDefinition(id: "complex", name: "complex", input: .init(builtinLayout: .qwerty26),
            rows: Array(repeating: .init(keys: [.init(label: "a", action: .init(.code, value: "a"))]), count: 17))
        try JSONEncoder().encode(invalid).write(to: source)
        do { _ = try await manager.readImport(source); fatalError("complex import accepted") }
        catch is LayoutError { }
        precondition(!manager.isImporting)
        precondition(SecurityScopeProbe.active == 0 && SecurityScopeProbe.starts == SecurityScopeProbe.stops)

        try changed.encoded().write(to: source)
        let recovered = try await manager.readImport(source)
        precondition(recovered == changed)
        let saved = await manager.saveDraft(recovered)
        precondition(saved)
        let stored = try LayoutStore(directoryURL: RimePaths.root.appendingPathComponent("catalog")).load()
        precondition(stored == manager.registry)
        print("PASS: production background I/O, duplicate guard, budgets, error recovery and draft isolation")
    }
}
'''


@unittest.skipUnless(sys.platform == "darwin", "requires the macOS Swift toolchain")
class LayoutImportTests(unittest.TestCase):
    def test_actual_background_read_duplicate_guard_and_failure_recovery(self):
        manager = (ROOT / "Apps/HostApp/LayoutManager.swift").read_text()
        manager = manager.replace("import LayoutKit\n", "").replace("import KeyboardCore\n", "")
        # Ordinary temporary URLs have no OS grant; instrument only scope acquire/release.
        # Production async method, queue and all file reading/decoding remain unchanged.
        manager = manager.replace("startAccessingSecurityScopedResource()", "probeStartAccessing()")
        manager = manager.replace("stopAccessingSecurityScopedResource()", "probeStopAccessing()")
        appearance = (ROOT / "Apps/HostApp/AppearanceManager.swift").read_text()
        queue = section(appearance, "enum HostConfigIOQueue {", "\n/// Unified")
        gates = (CORE / "Support/RefreshCoordination.swift").read_text()
        outcome = gates[gates.index("public enum StructuredRefreshOutcome {"):]
        sources = sorted((ROOT / "Packages/LayoutKit/Sources/LayoutKit").glob("*.swift"))
        with scratch_directory("layout-import") as directory:
            generated = directory / "LayoutImportProbe.swift"
            generated.write_text("import SwiftUI\n" + manager + "\n" + queue + "\n" + outcome + "\n" + CHECKS)
            binary = compile_swift(
                directory,
                [generated, REQUIREMENTS_STUB, CORE / "Support/LatestWinsReadGate.swift", CORE / "Support/SerialIOQueue.swift", *sources],
                library=True)
            runtime = directory / "runtime"
            runtime.mkdir()
            print(run([str(binary), str(runtime)]), end="")


if __name__ == "__main__":
    unittest.main()
