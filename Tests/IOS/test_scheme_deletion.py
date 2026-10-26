"""Scheme deletion composition cleanup: compiles the production cleanup out of
SchemePackageDeletionCenter, splices the real LayoutManager, and drives it against a real
on-disk install inventory (last provider, another provider, unreadable install, failed save,
damaged catalog). The app builds with Swift 6, so a second check typechecks the nonisolated
helpers under Swift 6 actor isolation, which the Swift 5 behavioural probe cannot see.
"""
import sys
import unittest

from swift_probe import ROOT, compile_swift, production_modules, run, scratch_directory, section

CENTER = "Apps/HostApp/SchemePackageDeletionCenter.swift"
# LayoutManager now reads the machine's keyboard-switch requirement through this shared helper.
REQUIREMENTS_STUB = ROOT / "Tests/IOS/Fixtures/KeyboardSystemRequirementsProbe.swift"


def production_blocks():
    text = (ROOT / CENTER).read_text()
    return {
        "// RECONCILE": section(
            text, "    /// Drops page pairings whose input method no longer has any provider",
            "    /// Input methods the installs on disk still declare"),
        "// INVENTORY": section(
            text, "    /// Input methods the installs on disk still declare",
            "    /// Removes trash left by a deletion that was interrupted"),
    }


@unittest.skipUnless(sys.platform == "darwin", "requires the macOS Swift toolchain")
class SchemeDeletionCompositionCleanupTests(unittest.TestCase):
    def probe(self, *arguments):
        harness = SOURCE
        for marker, block in production_blocks().items():
            if "func " not in block:
                raise AssertionError("production block not found: " + marker)
            harness = harness.replace(marker, block)
        manager = (ROOT / "Apps/HostApp/LayoutManager.swift").read_text()
        manager = manager.replace("import LayoutKit\n", "").replace("import KeyboardCore\n", "")
        appearance = (ROOT / "Apps/HostApp/AppearanceManager.swift").read_text()
        queue = section(appearance, "enum HostConfigIOQueue {", "\n/// Unified")
        harness = harness.replace("// QUEUE", queue).replace("// MANAGER", manager)
        with scratch_directory("scheme-deletion-cleanup") as directory:
            generated = directory / "SchemeDeletionCleanupProbe.swift"
            generated.write_text("import SwiftUI\n" + harness)
            binary = compile_swift(
                directory, [generated, REQUIREMENTS_STUB], library=True,
                dependencies=("KeyboardCore", "LayoutKit"))
            print(run([str(binary), *arguments]), end="")

    def test_cleanup_uses_declared_inventory_and_failure_keeps_the_stored_pairing(self):
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

    // INVENTORY
}

// MARK: - Probe

@main struct Probe {
    static var failures: [String] = []

    static func check(_ condition: Bool, _ message: String) {
        if !condition { failures.append(message) }
    }

    static let schemaSuffix = ".schema.yaml"

    /// One install slot whose live generation declares the given input methods as schema files.
    /// The generation's resources directory is returned for cases that also write metadata.
    @discardableResult
    static func install(
        _ packageID: String, methods: [String], root: URL, keepGeneration: Bool = false,
        activeSchemaID: String? = nil, generation: String = "gen-1"
    ) throws -> URL {
        let slot = root.appendingPathComponent(packageID)
        let version = slot.appendingPathComponent("versions").appendingPathComponent(generation)
        let resources = version.appendingPathComponent("resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        for method in methods {
            try Data("schema".utf8).write(to: resources.appendingPathComponent(method + schemaSuffix))
        }
        if keepGeneration {
            // Same fields as the install record (PackageManager); the cleanup reads the two it needs.
            try writeDeclaration(
                [
                    "id": packageID, "revision": "r1", "generation": generation,
                    "schemaID": activeSchemaID ?? methods.first ?? "", "activatedAt": "2026-01-01T00:00:00Z",
                ], to: slot.appendingPathComponent("active.json"))
        }
        return resources
    }

    /// Writes an authoritative declaration file the installer would have written.
    static func writeDeclaration<T: Encodable>(_ value: T, to url: URL) throws {
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }

    static func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scheme-deletion-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// The declared inventory is files on disk, so this reads it directly without a manager.
    static func inventoryChecks() throws {
        // 1) An install slot declares its methods; deleting it stops that; built-ins always count.
        do {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            ProbePaths.storeRoot = root
            try install("gone", methods: ["gone_method"], root: root)
            check(
                SchemeImportCenter.declaredInputMethods(in: root)?.contains("gone_method") == true,
                "an installed scheme declares its input method")
            try FileManager.default.removeItem(at: root.appendingPathComponent("gone"))
            let after = SchemeImportCenter.declaredInputMethods(in: root)
            check(after?.contains("gone_method") == false, "a deleted scheme stops declaring its method")
            check(after?.contains(BuiltinTemplateSchemas.quanpin) == true, "built-in schemes always count")
        }
        // 2) A method that is only disabled or never enabled still has a provider: scanning the
        //    files rather than the enabled list is what keeps its pairing alive.
        do {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            ProbePaths.storeRoot = root
            try install("keeps", methods: ["disabled_method", "unused_method"], root: root)
            let providers = SchemeImportCenter.declaredInputMethods(in: root)
            check(providers?.contains("disabled_method") == true, "a disabled method still has a provider")
            check(providers?.contains("unused_method") == true, "an unenabled method still has a provider")
        }
        // 3) A second install of the same method keeps it after the first one goes.
        do {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            ProbePaths.storeRoot = root
            try install("shared-a", methods: ["shared_method"], root: root)
            try install("shared-b", methods: ["shared_method"], root: root)
            try FileManager.default.removeItem(at: root.appendingPathComponent("shared-a"))
            check(
                SchemeImportCenter.declaredInputMethods(in: root)?.contains("shared_method") == true,
                "a second install keeps providing the method")
        }
        // 4) A damaged install whose schema file is gone still declares its input method in the
        //    authoritative lists, so it keeps providing it (audit repro: treating the file list
        //    as the truth would delete a live preference).
        do {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            ProbePaths.storeRoot = root
            let resources = try install(
                "damaged", methods: [], root: root, keepGeneration: true)
            try writeDeclaration(
                [KeyboardSchemaDescriptor(id: "X", name: "X", alphabet: "")],
                to: resources.appendingPathComponent("keyboard-schemas.json"))
            try writeDeclaration(["disabled_X"], to: resources.appendingPathComponent("keyboard-source-schemas.json"))
            let providers = SchemeImportCenter.declaredInputMethods(in: root)
            check(providers?.contains("X") == true, "a declared schema keeps providing its input method")
            check(providers?.contains("disabled_X") == true, "a declared disabled source keeps providing it")
        }
        // 5) Adapter metadata maps a generated companion back to the logical input method, so a
        //    build holding only the derived file still keeps the source's pairing.
        do {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            ProbePaths.storeRoot = root
            // The default method and the only schema file are both X; Y exists nowhere except in
            // the adapter registry, so only reading its source mapping can keep Y's pairing.
            let resources = try install(
                "derived", methods: [], root: root, keepGeneration: true, activeSchemaID: "X")
            try writeDeclaration(
                [KeyboardSchemaDescriptor(id: "X", name: "X", alphabet: "")],
                to: resources.appendingPathComponent("keyboard-schemas.json"))
            let build = resources.deletingLastPathComponent().appendingPathComponent("user/build")
            try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
            try Data("schema".utf8).write(to: build.appendingPathComponent("derived14.schema.yaml"))
            try writeDeclaration(
                [KeyboardResourceSet.EncodingAdapter(
                    sourceSchemaID: "Y", schemaID: "derived14", layout: .merged14)],
                to: build.appendingPathComponent("keyboard-adapters.json"))
            let providers = SchemeImportCenter.declaredInputMethods(in: root)
            check(providers?.contains("X") == true, "the declared default stays a provider")
            check(
                providers?.contains("Y") == true,
                "only the adapter's source mapping can keep Y as a provider")
            check(
                providers?.contains("derived14") == false,
                "the generated companion's own name is not mistaken for an input method")
        }
        // 7) A lost resources directory leaves the generation's full declared set unrecoverable;
        //    the marker alone names only the default, so nothing may be dropped (audit repro: a
        //    non-default method's preference must not be lost because the files are gone).
        do {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            ProbePaths.storeRoot = root
            let resources = try install(
                "lost-resources", methods: ["default_X"], root: root, keepGeneration: true,
                activeSchemaID: "default_X")
            try writeDeclaration(
                [KeyboardSchemaDescriptor(id: "default_X", name: "X", alphabet: "")],
                to: resources.appendingPathComponent("keyboard-schemas.json"))
            try FileManager.default.removeItem(at: resources)
            check(
                SchemeImportCenter.declaredInputMethods(in: root) == nil,
                "a generation whose declared set is unrecoverable must keep every pairing")
        }
        // 7b) Resources kept but emptied: the same damage as losing the directory, so the
        //     marker's default alone must not replace the generation's lost declared set.
        do {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            ProbePaths.storeRoot = root
            let resources = try install(
                "emptied", methods: ["default_X", "nonDefault_Y"], root: root,
                keepGeneration: true, activeSchemaID: "default_X")
            for name in try FileManager.default.contentsOfDirectory(atPath: resources.path) {
                try FileManager.default.removeItem(at: resources.appendingPathComponent(name))
            }
            check(
                SchemeImportCenter.declaredInputMethods(in: root) == nil,
                "an emptied resources directory must keep every pairing")
        }
        // 8) A marked install whose resources are intact declares its whole set, so a method
        //    that is not the default stays a provider and its pairing is kept.
        do {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            ProbePaths.storeRoot = root
            let resources = try install(
                "multi", methods: ["default_X"], root: root, keepGeneration: true,
                activeSchemaID: "default_X")
            try writeDeclaration(
                [
                    KeyboardSchemaDescriptor(id: "default_X", name: "X", alphabet: ""),
                    KeyboardSchemaDescriptor(id: "nonDefault_Y", name: "Y", alphabet: ""),
                ], to: resources.appendingPathComponent("keyboard-schemas.json"))
            let providers = SchemeImportCenter.declaredInputMethods(in: root)
            check(providers?.contains("default_X") == true, "the marked default stays a provider")
            check(providers?.contains("nonDefault_Y") == true, "a non-default method stays a provider")
        }
        // 9) An ordinary 26-key install writes no adapter registry; its build files are all known
        //    source schemas, so they must not make the inventory look incomplete.
        do {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            ProbePaths.storeRoot = root
            let resources = try install(
                "plain26", methods: ["plain26"], root: root, keepGeneration: true,
                activeSchemaID: "plain26")
            let build = resources.deletingLastPathComponent().appendingPathComponent("user/build")
            try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
            try Data("schema".utf8).write(to: build.appendingPathComponent("plain26.schema.yaml"))
            check(
                SchemeImportCenter.declaredInputMethods(in: root)?.contains("plain26") == true,
                "a registry-less build of known schemas keeps the inventory complete")
        }
        // 10) An active marker whose generation is gone keeps the inventory incomplete.
        do {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            ProbePaths.storeRoot = root
            let slot = root.appendingPathComponent("dangling")
            try install("dangling", methods: ["V"], root: root)
            try writeDeclaration(
                [
                    "id": "dangling", "revision": "r1", "generation": "gone-gen",
                    "schemaID": "V", "activatedAt": "2026-01-01T00:00:00Z",
                ], to: slot.appendingPathComponent("active.json"))
            check(
                SchemeImportCenter.declaredInputMethods(in: root) == nil,
                "a dangling active marker must keep every pairing")
        }
        // 6) A declaration that exists but cannot be parsed makes the inventory incomplete instead
        //    of silently declaring nothing.
        do {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            ProbePaths.storeRoot = root
            let resources = try install("badjson", methods: ["Z"], root: root, keepGeneration: true)
            try Data("not json".utf8).write(
                to: resources.appendingPathComponent("keyboard-schemas.json"))
            check(
                SchemeImportCenter.declaredInputMethods(in: root) == nil,
                "an unreadable declaration must keep every pairing")
        }
        // 4) An install that exists but cannot be read makes the inventory incomplete, so no
        //    pairing may be treated as provider-less.
        do {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            ProbePaths.storeRoot = root
            try install("broken", methods: ["some_method"], root: root)
            let slot = root.appendingPathComponent("broken")
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: slot.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: slot.path) }
            check(
                SchemeImportCenter.declaredInputMethods(in: root) == nil,
                "an unreadable install must not be read as 'no provider'")
        }
        // 5) A failed or superseded slot without generations declares nothing and is not fatal.
        do {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            ProbePaths.storeRoot = root
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("staging"), withIntermediateDirectories: true)
            check(
                SchemeImportCenter.declaredInputMethods(in: root)?.contains("staging") == false,
                "a slot without generations contributes no input method")
        }
    }

    /// A damaged catalog must not be mistaken for the built-in fallback: the maintenance write
    /// then reports failure and leaves the bytes alone, and repairs once the file is valid again.
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
        LayoutManager.shared.reload()
        var spins = 0
        while LayoutManager.shared.location == nil && spins < 20_000 {
            await Task.yield()
            spins += 1
        }
        check(LayoutManager.shared.lastError != nil, "a damaged catalog must surface a read error")

        // No install declares gone_method, but the real catalog cannot be read, so the cleanup
        // must report failure instead of treating the fallback as "nothing to clean".
        let saved = await SchemeImportCenter().reconcileCompositionsWithoutProvider()
        check(!saved, "cleanup must not report success when the catalog cannot be read")
        check(LayoutManager.shared.lastError != nil, "the read error must survive the failed cleanup")
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

    /// The reported data-loss path: when the first read fails, the manager caches the built-in
    /// fallback. A normal save must not write that fallback over the user's damaged catalog; it
    /// reports failure and leaves the bytes alone. Once the file reads again, the next save
    /// starts from the real catalog and merges into the user's own content.
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
        LayoutManager.shared.reload()
        var spins = 0
        while LayoutManager.shared.location == nil && spins < 20_000 { await Task.yield(); spins += 1 }
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

        // Enable/remove are writes too: they must not persist the fallback either.
        await LayoutManager.shared.setEnabled(BuiltinLayouts.merged14.id, on: false)
        check(
            try Data(contentsOf: catalogFile) == corrupt,
            "a failed enable write must not overwrite the damaged catalog")
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
            finish()
        }
        if CommandLine.arguments.contains("--damaged-catalog-write") {
            try await damagedCatalogWriteChecks()
            finish()
        }
        try inventoryChecks()

        // The reported bug, end to end in one process: the pairing of the last provider is
        // dropped, and then the page and layout it referenced really can be removed.
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
        LayoutManager.shared.reload()
        var spins = 0
        while LayoutManager.shared.location == nil && spins < 20_000 {
            await Task.yield()
            spins += 1
        }
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

        finish()
    }
}
'''


STUBS = '''
import Foundation
import KeyboardCore
import LayoutKit

enum ProbeRoot { nonisolated(unsafe) static var value: URL! }

enum HostConfigIOQueue {
    static func async<T: Sendable>(_ work: @escaping @Sendable () -> T) async throws -> T { try work() }
}

@MainActor
final class LayoutManager {
    static let shared = LayoutManager()
    var lastError: String?
    var registry: LayoutRegistry = try! LayoutRegistry()
    func pruneCompositions(where isObsolete: (String) -> Bool) -> Bool { true }
}

@MainActor
final class SchemeImportCenter {
    var diagnostics: [String] = []
    nonisolated static var storeRoot: URL { ProbeRoot.value }
}
'''


@unittest.skipUnless(sys.platform == "darwin", "requires the macOS Swift toolchain")
class SchemeDeletionIsolationTests(unittest.TestCase):
    def test_cleanup_helpers_are_not_main_actor_isolated(self):
        text = (ROOT / CENTER).read_text()
        cleanup = section(text, "    /// Drops page pairings whose input method no longer has any provider",
                          "    /// Removes trash left by a deletion that was interrupted")
        self.assertIn("declaredInputMethods", cleanup)
        with scratch_directory("scheme-deletion-isolation") as directory:
            source = directory / "Cleanup.swift"
            source.write_text(STUBS + "\nextension SchemeImportCenter {\n" + cleanup + "\n}\n")
            modules = production_modules()
            # Swift 6 exactly as the app builds: an isolated constant read from nonisolated code fails here.
            run(["xcrun", "swiftc", "-swift-version", "6", "-typecheck",
                 "-I", str(modules), str(source)])


if __name__ == "__main__":
    unittest.main()