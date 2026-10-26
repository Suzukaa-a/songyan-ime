"""Drive the real HostApp LayoutManager against a real on-disk catalog and a controllable
machine requirement: required / unknown / not required. The probe exercises the public save and
import entry points (saveDraft incl. copy and install, savePage, readImport, saveComposition) and
checks that a rejected write keeps both the catalog bytes and the in-memory registry untouched,
while a legal write really reaches the file. The production sources are spliced unchanged; only
the machine requirement and the app-group paths are test seams.
"""
import sys
import unittest

from swift_probe import CORE, ROOT, compile_swift, run, scratch_directory, section

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
    static var failures: [String] = []

    static func check(_ condition: Bool, _ message: String) {
        if !condition { failures.append(message) }
    }

    static func snapshot(_ root: URL) -> [String: Data] {
        var result: [String: Data] = [:]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return result }
        for case let url as URL in enumerator {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                !isDirectory.boolValue,
                let data = try? Data(contentsOf: url)
            else { continue }
            let relative = url.path.hasPrefix(root.path + "/")
                ? String(url.path.dropFirst(root.path.count + 1)) : url.lastPathComponent
            result[relative] = data
        }
        return result
    }

    static func letters() -> [LayoutKey] {
        (0..<10).map { _ in LayoutKey(label: "a", action: .init(.literal, value: "a")) }
    }

    @MainActor
    static func main() async throws {
        let runtime = URL(fileURLWithPath: CommandLine.arguments[1])
        let catalog = runtime.appendingPathComponent("catalog")
        let imports = runtime.appendingPathComponent("imports")
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)

        // One real catalog with a custom layout and an authored page, each without a primary globe.
        let noGlobeLayout = LayoutDefinition(
            id: "probe.no.globe.layout", name: "无地球布局",
            input: .init(builtinLayout: .qwerty26),
            rows: [LayoutRow(keys: letters())])
        let globeLayout = LayoutDefinition(
            id: "probe.globe.layout", name: "有地球布局",
            input: .init(builtinLayout: .qwerty26),
            rows: [LayoutRow(keys: [LayoutKey(label: "🌐", action: .init(.globe))] + letters())])
        let noGlobePage = KeyboardPageDefinition(
            id: "probe.no.globe.page", name: "无地球页", kind: .numeric,
            rows: [LayoutRow(keys: [LayoutKey(label: "1", action: .init(.literal, value: "1"))])],
            chrome: KeyboardPageChrome())
        var globePage = KeyboardPagePresets.numericChinese.materialized()
        globePage.id = "probe.globe.page"
        globePage.name = "有地球页"

        var seed = try LayoutRegistry()
        try seed.install(noGlobeLayout.encoded(), enable: true)
        try seed.install(globeLayout.encoded(), enable: true)
        try seed.savePage(noGlobePage)
        try seed.savePage(globePage)
        try LayoutStore(directoryURL: catalog).save(seed)

        let noGlobeImport = imports.appendingPathComponent("no-globe-layout.json")
        let globeImport = imports.appendingPathComponent("globe-layout.json")
        try noGlobeLayout.encoded().write(to: noGlobeImport)
        try globeLayout.encoded().write(to: globeImport)
        let initialNoGlobeImport = try Data(contentsOf: noGlobeImport)

        let manager = LayoutManager.shared
        var spins = 0
        while manager.location == nil && spins < 20_000 {
            await Task.yield()
            spins += 1
        }
        check(manager.location != nil, "the seeded catalog must load through the real manager")
        check(manager.registry == seed, "the seeded catalog must be the manager baseline")

        let editedNoGlobe = noGlobeLayout.renamed("改过的无地球布局")
        let newNoGlobe = LayoutDefinition(
            id: "probe.no.globe.new", name: "新无地球布局", input: noGlobeLayout.input,
            rows: noGlobeLayout.rows, auxiliaryAreas: noGlobeLayout.auxiliaryAreas,
            note: noGlobeLayout.note, longPressDelay: noGlobeLayout.longPressDelay,
            candidateArea: noGlobeLayout.candidateArea, split: noGlobeLayout.split)
        var editedNoGlobePage = noGlobePage
        editedNoGlobePage.name = "改过的无地球页"
        var newNoGlobePage = noGlobePage
        newNoGlobePage.id = "probe.no.globe.page.new"
        newNoGlobePage.name = "新无地球页"
        let noGlobeComposition = KeyboardComposition(
            mainLayoutID: BuiltinLayouts.qwerty26.id, numericPageID: noGlobePage.id)

        @MainActor
        func rejected(_ name: String, _ operation: () async -> Bool) async {
            let beforeBytes = snapshot(catalog)
            let beforeRegistry = manager.registry
            let passed = await operation()
            check(!passed, "\(name): a write without a primary globe must be rejected")
            check((manager.lastError ?? "").contains("缺少地球键"),
                  "\(name): the error must name the missing globe (\(manager.lastError ?? "nil"))")
            check(snapshot(catalog) == beforeBytes,
                  "\(name): a rejected write must leave the catalog bytes untouched")
            check(manager.registry == beforeRegistry,
                  "\(name): a rejected write must leave the registry untouched")
        }

        @MainActor
        func rejectedImport(_ name: String, _ url: URL) async {
            let beforeBytes = snapshot(catalog)
            let beforeImport = try? Data(contentsOf: url)
            let beforeRegistry = manager.registry
            do {
                _ = try await manager.readImport(url)
                check(false, "\(name): an import without a primary globe must be rejected")
            } catch {
                check(String(describing: error).contains("缺少地球键"),
                      "\(name): the import error must name the missing globe")
            }
            check(manager.isImporting == false, "\(name): the busy flag must be cleared")
            check((try? Data(contentsOf: url)) == beforeImport,
                  "\(name): a rejected import must not rewrite the imported file")
            check(snapshot(catalog) == beforeBytes,
                  "\(name): a rejected import must leave the catalog bytes untouched")
            check(manager.registry == beforeRegistry,
                  "\(name): a rejected import must leave the registry untouched")
        }

        // Required: every public entry point rejects a missing primary globe, and a copy/install
        // is rejected before it can touch the file.
        KeyboardSystemRequirementsProbe.setRequired(true)
        await rejected("draft replace") { await manager.saveDraft(editedNoGlobe) }
        await rejected("draft install") { await manager.saveDraft(newNoGlobe) }
        await rejected("draft copy") { await manager.saveDraft(noGlobeLayout, asCopy: true) }
        await rejected("page replace") { await manager.savePage(editedNoGlobePage) }
        await rejected("page install") { await manager.savePage(newNoGlobePage) }
        await rejected("composition using an existing no-globe page") {
            await manager.saveComposition(noGlobeComposition, for: "probe_method:qwerty26")
        }
        await rejectedImport("import no-globe layout", noGlobeImport)

        // Unknown: before a keyboard ever appears the requirement must count as required.
        KeyboardSystemRequirementsProbe.setRequired(nil)
        check(KeyboardSystemRequirements.requiresKeyboardSwitchEntry(),
              "an unknown requirement must count as required")
        await rejected("draft replace (unknown)") { await manager.saveDraft(editedNoGlobe) }
        await rejected("page replace (unknown)") { await manager.savePage(editedNoGlobePage) }
        await rejected("composition (unknown)") {
            await manager.saveComposition(noGlobeComposition, for: "probe_method:qwerty26")
        }
        await rejectedImport("import (unknown)", noGlobeImport)

        // Not required: the same data must save and import through the real manager.
        KeyboardSystemRequirementsProbe.setRequired(false)
        let notRequiredBefore = snapshot(catalog)
        check(await manager.saveDraft(editedNoGlobe),
              "not required: a draft without a globe must save")
        check(snapshot(catalog) != notRequiredBefore,
              "not required: the saved draft must reach the catalog")
        check(await manager.savePage(editedNoGlobePage),
              "not required: an authored page without a globe must save")
        check(await manager.saveDraft(noGlobeLayout, asCopy: true),
              "not required: copying a layout without a globe must save")
        check(await manager.saveComposition(noGlobeComposition, for: "probe_method:qwerty26"),
              "not required: pairing an existing no-globe page must save")
        check(try await manager.readImport(noGlobeImport) == noGlobeLayout,
              "not required: the no-globe layout must import")
        check((try? Data(contentsOf: noGlobeImport)) == initialNoGlobeImport,
              "a successful draft import must not rewrite the imported file")
        let afterNotRequired = try LayoutStore(directoryURL: catalog).load()
        check(afterNotRequired.layout(id: noGlobeLayout.id)?.name == "改过的无地球布局",
              "not required: the replaced layout must persist")
        check(afterNotRequired.page(id: noGlobePage.id)?.name == "改过的无地球页",
              "not required: the edited page must persist")
        check(afterNotRequired.compositions["probe_method:qwerty26"]?.numericPageID == noGlobePage.id,
              "not required: the pairing with the no-globe page must persist")
        check(afterNotRequired.layouts.count == seed.layouts.count + 1,
              "not required: the copy path must add exactly one layout")

        // Required again, but now with real data: a primary globe passes, and fixing the missing
        // globe really saves the same content.
        KeyboardSystemRequirementsProbe.setRequired(true)
        let editedGlobe = globeLayout.renamed("改过的有地球布局")
        var editedGlobePage = globePage
        editedGlobePage.name = "改过的有地球页"
        check(await manager.saveDraft(editedGlobe),
              "required: a layout with a primary globe must save")
        check(await manager.savePage(editedGlobePage),
              "required: a page with a primary globe must save")
        check(try await manager.readImport(globeImport) == globeLayout,
              "required: a layout with a primary globe must import")
        check(await manager.saveComposition(
            .init(mainLayoutID: BuiltinLayouts.qwerty26.id, numericPageID: globePage.id),
            for: "probe_globe:qwerty26"),
              "required: pairing a page with a primary globe must save")

        let fixedRows = [
            LayoutRow(keys: [LayoutKey(label: "🌐", action: .init(.globe))]
                + editedNoGlobe.rows[0].keys)
        ] + Array(editedNoGlobe.rows.dropFirst())
        let fixedLayout = LayoutDefinition(
            id: editedNoGlobe.id, name: editedNoGlobe.name, input: editedNoGlobe.input,
            rows: fixedRows, auxiliaryAreas: editedNoGlobe.auxiliaryAreas,
            note: editedNoGlobe.note, longPressDelay: editedNoGlobe.longPressDelay,
            candidateArea: editedNoGlobe.candidateArea, split: editedNoGlobe.split)
        check(await manager.saveDraft(fixedLayout),
              "required: adding the missing primary globe lets the same layout save")
        var fixedPage = editedNoGlobePage
        fixedPage.rows[0] = LayoutRow(
            keys: [LayoutKey(label: "🌐", action: .init(.globe))] + fixedPage.rows[0].keys)
        check(await manager.savePage(fixedPage),
              "required: adding the missing primary globe lets the same page save")

        let final = try LayoutStore(directoryURL: catalog).load()
        check(final.layout(id: noGlobeLayout.id)?.hasInputModeSwitchKey == true,
              "the repaired layout must persist its primary globe")
        check(final.page(id: noGlobePage.id)?.hasInputModeSwitchKey == true,
              "the repaired page must persist its primary globe")
        check(final.compositions["probe_method:qwerty26"]?.numericPageID == noGlobePage.id,
              "the earlier legal pairing must survive later writes")
        check(manager.registry == final,
              "the manager cache must equal the persisted catalog after every write")
        check(SecurityScopeProbe.active == 0,
              "every import must release its security-scoped access")

        if failures.isEmpty {
            print("PASS: real LayoutManager save/import drives required, unknown and not-required "
                + "system requirements without data loss")
        } else {
            for failure in failures { print("FAIL: " + failure) }
            exit(1)
        }
    }
}
'''


@unittest.skipUnless(sys.platform == "darwin", "requires the macOS Swift toolchain")
class LayoutSystemRequirementTests(unittest.TestCase):
    def test_real_manager_gates_missing_globe_without_touching_files_or_registry(self):
        # App source, only imports stripped; behaviour and structure unchanged.
        manager = (ROOT / "Apps/HostApp/LayoutManager.swift").read_text()
        manager = manager.replace("import LayoutKit\n", "").replace("import KeyboardCore\n", "")
        # Ordinary temporary URLs carry no OS grant; instrument only scope acquire/release.
        manager = manager.replace("startAccessingSecurityScopedResource()", "probeStartAccessing()")
        manager = manager.replace("stopAccessingSecurityScopedResource()", "probeStopAccessing()")
        appearance = (ROOT / "Apps/HostApp/AppearanceManager.swift").read_text()
        queue = section(appearance, "enum HostConfigIOQueue {", "\n/// Unified")
        gates = (CORE / "Support/RefreshCoordination.swift").read_text()
        outcome = gates[gates.index("public enum StructuredRefreshOutcome {"):]
        sources = sorted((ROOT / "Packages/LayoutKit/Sources/LayoutKit").glob("*.swift"))
        fixture = REQUIREMENTS_STUB.read_text()
        with scratch_directory("layout-system-requirement") as directory:
            generated = directory / "LayoutSystemRequirementProbe.swift"
            generated.write_text(
                "import SwiftUI\n" + manager + "\n" + queue + "\n" + outcome + "\n"
                + fixture + "\n" + CHECKS)
            binary = compile_swift(
                directory,
                [generated, CORE / "Support/LatestWinsReadGate.swift", *sources],
                library=True)
            runtime = directory / "runtime"
            runtime.mkdir()
            print(run([str(binary), str(runtime)]), end="")


if __name__ == "__main__":
    unittest.main()
