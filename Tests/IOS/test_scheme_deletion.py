"""Page-pairing cleanup after a scheme deletion, through the real LayoutManager.

The inventory parsing itself is covered by the PackageManager tests. These cases need the
LayoutManager probe: they splice the production cleanup out of SchemePackageDeletionCenter,
compile it with the real LayoutManager and the real inventory sources, and drive a catalog on
disk (damaged baseline, damaged-catalog writes, end-to-end prune with a failing save).
"""
import sys
import unittest

from swift_probe import ROOT, compile_swift, run, scratch_directory, section

CENTER = "Apps/HostApp/SchemePackageDeletionCenter.swift"
INVENTORY_SOURCES = [
    ROOT / "Packages/PackageManager/Sources/PackageManager/InstalledInputMethodInventory.swift",
    ROOT / "Packages/PackageManager/Sources/PackageManager/InstalledPackageLayout.swift",
]
# LayoutManager reads the machine's keyboard-switch requirement through this shared helper.
REQUIREMENTS_STUB = ROOT / "Tests/IOS/Fixtures/KeyboardSystemRequirementsProbe.swift"


def member(text, opener):
    """One type member from its declaration opener through its closing brace at member indent."""
    begin = text.index(opener)
    return text[begin:text.index("\n    }\n", begin) + len("\n    }\n")]


def reconcile_block():
    text = (ROOT / CENTER).read_text()
    block = member(text, "    @discardableResult\n    func reconcileCompositionsWithoutProvider()")
    if "InstalledInputMethodInventory" not in block:
        raise AssertionError("the cleanup no longer reads the installed input method inventory")
    return block


@unittest.skipUnless(sys.platform == "darwin", "requires the macOS Swift toolchain")
class SchemeDeletionCompositionCleanupTests(unittest.TestCase):
    def probe(self, *arguments):
        manager = (ROOT / "Apps/HostApp/LayoutManager.swift").read_text()
        manager = manager.replace("import LayoutKit\n", "").replace("import KeyboardCore\n", "")
        appearance = (ROOT / "Apps/HostApp/AppearanceManager.swift").read_text()
        queue = section(appearance, "enum HostConfigIOQueue {", "\n/// Unified")
        harness = (SOURCE.replace("// QUEUE", queue).replace("// MANAGER", manager)
                   .replace("// RECONCILE", reconcile_block()))
        with scratch_directory("scheme-deletion-cleanup") as directory:
            generated = directory / "SchemeDeletionCleanupProbe.swift"
            generated.write_text("import SwiftUI\n" + harness)
            binary = compile_swift(
                directory, [generated, REQUIREMENTS_STUB, *INVENTORY_SOURCES], library=True,
                dependencies=("KeyboardCore", "LayoutKit"))
            print(run([str(binary), *arguments]), end="")

    def test_prune_follows_installs_and_a_failed_save_is_repaired_by_the_next_call(self):
        self.probe()

    def test_cleanup_never_treats_an_unreadable_catalog_as_clean(self):
        self.probe("--corrupt-baseline")

    def test_normal_saves_never_overwrite_an_unreadable_catalog(self):
        self.probe("--damaged-catalog-write")


SOURCE = r'''
import Foundation
import KeyboardCore
import LayoutKit

// MARK: - Production code under test (spliced by the test)

// QUEUE

// MANAGER

// MARK: - Seams the production cleanup talks to

/// Store root of the probe's temporary install area (set before each case).
enum ProbePaths { static var storeRoot: URL! }

enum LayoutStoreLocation {
    case local(URL), shared(URL)
    var url: URL {
        switch self {
        case .local(let url), .shared(let url): return url
        }
    }
    var isShared: Bool {
        if case .shared = self { return true }
        return false
    }
}

enum RimePaths {
    static func layoutStoreDirectory() -> LayoutStoreLocation {
        .local(ProbePaths.storeRoot.appendingPathComponent("catalog"))
    }
    static func layoutStoreReadLocation() -> LayoutStoreLocation {
        .local(ProbePaths.storeRoot.appendingPathComponent("catalog"))
    }
}

@MainActor
final class SchemeImportCenter {
    var diagnostics: [String] = []
    nonisolated static var storeRoot: URL { ProbePaths.storeRoot }
}

extension SchemeImportCenter {
    // RECONCILE
}

// MARK: - Probe

@main struct Probe {
    static var failures: [String] = []

    static func check(_ condition: Bool, _ message: String) {
        if !condition { failures.append(message) }
    }

    /// One install slot whose generation declares the given input methods as schema files.
    static func install(_ packageID: String, methods: [String], root: URL) throws {
        let resources = root.appendingPathComponent(packageID)
            .appendingPathComponent("versions/gen-1/resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        for method in methods {
            try Data("schema".utf8).write(to: resources.appendingPathComponent(method + ".schema.yaml"))
        }
    }

    static func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scheme-deletion-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Loads the catalog the way the app does and waits until the first read has finished.
    @MainActor
    static func loadCatalog() async {
        LayoutManager.shared.reload()
        var spins = 0
        while LayoutManager.shared.location == nil && spins < 20_000 {
            await Task.yield()
            spins += 1
        }
    }

    /// A damaged catalog must not be mistaken for the built-in fallback: the cleanup then
    /// reports failure and leaves the bytes alone, and repairs once the file is valid again.
    @MainActor
    static func corruptBaselineChecks() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        ProbePaths.storeRoot = root
        let catalog = root.appendingPathComponent("catalog")
        try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: true)
        let corrupt = Data("{ this is not a catalog".utf8)
        let catalogFile = catalog.appendingPathComponent("layouts.json")
        try corrupt.write(to: catalogFile)

        // The first load reads the damaged catalog and falls back to the built-in layouts.
        await loadCatalog()
        check(LayoutManager.shared.lastError != nil, "a damaged catalog must surface a read error")

        // No install declares gone_method, but the real catalog cannot be read, so the cleanup
        // must report failure instead of treating the fallback as "nothing to clean".
        let saved = await SchemeImportCenter().reconcileCompositionsWithoutProvider()
        check(!saved, "cleanup must not report success when the catalog cannot be read")
        check(
            LayoutManager.shared.lastSilentFailure != nil,
            "the failed background cleanup must leave a diagnostic")
        check(LayoutManager.shared.lastError != nil, "the failed cleanup must not clear the read error on screen")
        check(
            try Data(contentsOf: catalogFile) == corrupt,
            "a failed cleanup must not touch the catalog")

        // Repairing the file lets the next cleanup do the real work.
        var registry = LayoutManager.shared.registry
        try registry.setComposition(
            .init(mainLayoutID: BuiltinLayouts.qwerty26.id), for: "gone_method:qwerty26")
        try LayoutStore(directoryURL: catalog).save(registry)
        let repaired = await SchemeImportCenter().reconcileCompositionsWithoutProvider()
        check(repaired, "the cleanup must succeed once the catalog is readable")
        check(
            try LayoutStore(directoryURL: catalog).load().compositions["gone_method:qwerty26"] == nil,
            "the orphaned pairing must be gone from the repaired catalog")
    }

    /// When the first read fails, the manager caches the built-in fallback. A normal save must
    /// not write that fallback over the user's damaged catalog; it reports failure and leaves
    /// the bytes alone. Once the file reads again, the next save starts from the real catalog
    /// and merges into the user's own content.
    @MainActor
    static func damagedCatalogWriteChecks() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        ProbePaths.storeRoot = root
        let catalog = root.appendingPathComponent("catalog")
        try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: true)
        let catalogFile = catalog.appendingPathComponent("layouts.json")
        let corrupt = Data("{ this is not a catalog".utf8)
        try corrupt.write(to: catalogFile)

        // The first read fails, so the cached registry is the built-in fallback.
        await loadCatalog()
        check(LayoutManager.shared.lastError != nil, "a damaged catalog must surface a read error")

        // Every ordinary save must fail rather than persist the fallback over the damaged file.
        let page = KeyboardPagePresets.symbolsChinese.copy(name: "新页面")
        check(!(await LayoutManager.shared.savePage(page)), "a page save must fail while the catalog is unreadable")
        check(LayoutManager.shared.lastError != nil, "the read error must survive the failed page save")
        check(
            try Data(contentsOf: catalogFile) == corrupt,
            "a failed page save must not overwrite the damaged catalog")

        let draft = LayoutDefinition(
            id: "my_layout", name: "我的布局", input: .init(builtinLayout: .qwerty26),
            rows: BuiltinLayouts.qwerty26.rows)
        check(!(await LayoutManager.shared.saveDraft(draft)), "a layout save must fail while the catalog is unreadable")
        check(
            try Data(contentsOf: catalogFile) == corrupt,
            "a failed layout save must not overwrite the damaged catalog")

        check(
            !(await LayoutManager.shared.saveComposition(
                .init(mainLayoutID: BuiltinLayouts.merged14.id), for: "some_pinyin:merged14")),
            "a pairing save must fail while the catalog is unreadable")
        check(
            try Data(contentsOf: catalogFile) == corrupt,
            "a failed pairing save must not overwrite the damaged catalog")

        // Adding and removing are writes too: they must not persist the fallback either.
        await LayoutManager.shared.addBuiltin(BuiltinLayouts.merged14)
        check(
            try Data(contentsOf: catalogFile) == corrupt,
            "a failed add must not overwrite the damaged catalog")
        await LayoutManager.shared.remove(BuiltinLayouts.phone9.id)
        check(
            try Data(contentsOf: catalogFile) == corrupt,
            "a failed remove must not overwrite the damaged catalog")

        // The user's real catalog comes back, with content that only exists there.
        var userCatalog = try LayoutRegistry()
        let keptPage = KeyboardPagePresets.numericEnglish.copy(name: "我保留的数字页")
        try userCatalog.savePage(keptPage)
        try userCatalog.setComposition(
            .init(mainLayoutID: BuiltinLayouts.qwerty26.id), for: "kept_method:qwerty26")
        try FileManager.default.removeItem(at: catalogFile)
        try LayoutStore(directoryURL: catalog).save(userCatalog)

        // The next save reads that real baseline and merges into it.
        let freshPage = KeyboardPagePresets.symbolsChinese.copy(name: "新页面")
        check(await LayoutManager.shared.savePage(freshPage), "the repaired catalog must accept a save")
        let saved = try LayoutStore(directoryURL: catalog).load()
        check(saved.page(id: freshPage.id) != nil, "the new page must be in the saved catalog")
        check(
            saved.page(id: keptPage.id) == keptPage,
            "the save must merge into the user's own page instead of replacing the catalog")
        check(
            saved.compositions["kept_method:qwerty26"] != nil,
            "the save must keep the user's pairing")
    }

    /// Deleting the last provider drops its pairing so the page and layout it referenced can be
    /// removed; a failed save keeps the stored pairing and the next call repairs it.
    @MainActor
    static func pruneChecks() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        ProbePaths.storeRoot = root
        try install("removed-scheme", methods: ["gone_method"], root: root)
        try install("keeper", methods: ["kept_method"], root: root)

        var registry = LayoutManager.shared.registry
        let page = KeyboardPagePresets.numericChinese.copy(name: "我的数字")
        let layout = try registry.copy(BuiltinLayouts.qwerty26, name: "我的布局")
        try registry.savePage(page)
        try registry.setComposition(.init(mainLayoutID: layout.id, numericPageID: page.id), for: "gone_method:qwerty26")
        try registry.setComposition(.init(mainLayoutID: BuiltinLayouts.qwerty26.id), for: "kept_method:qwerty26")
        let catalog = root.appendingPathComponent("catalog")
        try LayoutStore(directoryURL: catalog).save(registry)
        await loadCatalog()
        check(LayoutManager.shared.registry.compositions.count == 2, "both seeded pairings must be visible")
        check(!(await LayoutManager.shared.removePage(page.id)), "the page is blocked while paired")

        try FileManager.default.removeItem(at: root.appendingPathComponent("removed-scheme"))
        let saved = await SchemeImportCenter().reconcileCompositionsWithoutProvider()
        check(saved, "the cleanup must save")
        check(
            LayoutManager.shared.registry.compositions["gone_method:qwerty26"] == nil,
            "the deleted scheme's pairing must be cleaned up")
        check(
            LayoutManager.shared.registry.compositions["kept_method:qwerty26"] != nil,
            "a live provider must keep its pairing")
        check(await LayoutManager.shared.removePage(page.id), "the page must be removable after cleanup")
        await LayoutManager.shared.remove(layout.id)
        check(LayoutManager.shared.registry.page(id: page.id) == nil, "the page is really gone")
        check(LayoutManager.shared.registry.layout(id: layout.id) == nil, "the layout is really gone")

        // A failed save must not report success, must keep the pairing in the cache, and must
        // not overwrite the stored value; the next call repairs it from the current installs.
        let seeded = await LayoutManager.shared.saveComposition(
            .init(mainLayoutID: BuiltinLayouts.qwerty26.id), for: "victim_method:qwerty26")
        check(seeded, "the victim pairing must be saved before the failing save")
        check(
            LayoutManager.shared.registry.compositions["victim_method:qwerty26"] != nil,
            "the victim pairing must be visible before the failing save")

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: catalog.path)
        do {
            let failed = await SchemeImportCenter().reconcileCompositionsWithoutProvider()
            check(!failed, "a failed save must not report success")
            check(
                LayoutManager.shared.registry.compositions["victim_method:qwerty26"] != nil,
                "a failed save must keep the previous pairing in the cache")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: catalog.path)
        check(
            try LayoutStore(directoryURL: catalog).load().compositions["victim_method:qwerty26"] != nil,
            "a failed save must not overwrite the stored value")

        let repaired = await SchemeImportCenter().reconcileCompositionsWithoutProvider()
        check(repaired, "the next call must recover without any record of the failure")
        check(
            LayoutManager.shared.registry.compositions["victim_method:qwerty26"] == nil,
            "the retry must remove the orphaned pairing")
    }

    static func finish() -> Never {
        if failures.isEmpty {
            print("PASS: deletion cleanup keeps live providers and never treats an unread catalog as clean")
        } else {
            for failure in failures { print("FAIL: " + failure) }
            exit(1)
        }
        exit(0)
    }

    @MainActor
    static func main() async throws {
        if CommandLine.arguments.contains("--corrupt-baseline") {
            try await corruptBaselineChecks()
        } else if CommandLine.arguments.contains("--damaged-catalog-write") {
            try await damagedCatalogWriteChecks()
        } else {
            try await pruneChecks()
        }
        finish()
    }
}
'''


if __name__ == "__main__":
    unittest.main()
