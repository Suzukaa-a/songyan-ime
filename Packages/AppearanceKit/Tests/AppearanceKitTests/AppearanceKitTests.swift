import CandidateKit
import Darwin
import SkinKit
import XCTest

@testable import AppearanceKit

final class AppearanceKitTests: XCTestCase {

    // MARK: - Fixtures

    private func temporaryDirectory(_ tag: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("appearance-\(tag)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Builds a fully distinguishable appearance project: skin accent, candidate size and collapsed height all differ.
    private func makeDocument(
        id: String, name: String,
        accent: String, candidateSize: Double,
        collapsedHeight: Double
    ) -> AppearanceDocument {
        var skin = SkinDefinition.systemDefault
        var light = skin.variants.light ?? .init()
        light.colors = (light.colors ?? [:]).merging(["accent": accent]) { _, new in new }
        skin.variants.light = light
        skin.typography.candidateSize = candidateSize
        var bar = CandidateBarDefinition.systemDefault
        bar.collapsed.height = collapsedHeight
        return AppearanceDocument(id: id, name: name, skin: skin, candidateBar: bar).normalized()
    }

    private func store(_ directory: URL) -> AppearanceStore {
        AppearanceStore(directory: directory)
    }

    func testFileImportRejectsPipesDirectoriesAndOversizedInput() throws {
        let directory = temporaryDirectory("hostile-import")
        defer { try? FileManager.default.removeItem(at: directory) }
        let normal = directory.appendingPathComponent("normal.json")
        let document = AppearanceDocument(id: "safe", name: "Safe")
        try document.encoded().write(to: normal)
        XCTAssertEqual(try AppearanceDocument.decodeImported(contentsOf: normal), document.normalized())
        let pipe = directory.appendingPathComponent("pipe.json")
        XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)
        for file in [pipe, directory] {
            XCTAssertThrowsError(try AppearanceDocument.decodeImported(contentsOf: file))
        }
        let oversized = Data(repeating: 0x20, count: 256 * 1024 + 1)
        try oversized.write(to: normal)
        XCTAssertThrowsError(try AppearanceDocument.decodeImported(contentsOf: normal))
        XCTAssertThrowsError(try AppearanceDocument.decodeImported(oversized)) { error in
            XCTAssertTrue(error.localizedDescription.contains("超过 256KB"))
        }
    }

    func testDeletionRejectsTraversalWithoutTouchingSiblingFiles() throws {
        let directory = temporaryDirectory("delete-boundary")
        defer { try? FileManager.default.removeItem(at: directory) }
        let appearance = store(directory.appendingPathComponent("appearance"))
        try appearance.save(AppearanceDocument(id: "safe", name: "Safe"))
        let victimAppearance = directory.appendingPathComponent("victim.songyanappearance.json")
        try Data("keep".utf8).write(to: victimAppearance)
        for id in ["../victim", "", "a/b", "a\\b"] {
            XCTAssertThrowsError(try appearance.remove(id))
        }
        XCTAssertEqual(try Data(contentsOf: victimAppearance), Data("keep".utf8))
    }

    // MARK: - Strict decoding / composite identity

    func testStrictDecodeRejectsUnknownFieldsBadVersionAndMissingParts() throws {
        let document = makeDocument(
            id: "my-look", name: "我的外观", accent: "#145ACC",
            candidateSize: 22, collapsedHeight: 48)
        XCTAssertEqual(try AppearanceDocument.decode(document.encoded()), document)
        for json in [
            // wrong version
            #"{"formatVersion":2,"id":"x","name":"x","skin":{},"candidateBar":{}}"#,
            // unknown top-level field
            #"{"formatVersion":1,"id":"x","name":"x","renderer":"evil","skin":{},"candidateBar":{}}"#,
            // missing candidate area
            #"{"formatVersion":1,"id":"x","name":"x","skin":{}}"#,
            // invalid appearance value
            #"{"formatVersion":1,"id":"x","name":"x","appearance":"sepia","skin":{},"candidateBar":{}}"#,
        ] {
            XCTAssertThrowsError(try AppearanceDocument.decode(Data(json.utf8)), json)
        }
    }

    /// The three identities move in lockstep: a skin id or candidate-area id that differs from the project id must be rejected (mixed generations).
    func testDecodeRejectsCrossGenerationIdentity() throws {
        let document = makeDocument(
            id: "look-a", name: "A", accent: "#145ACC",
            candidateSize: 22, collapsedHeight: 48)
        let object = try JSONSerialization.jsonObject(with: document.encoded()) as! [String: Any]
        var skinMismatch = object
        var skin = object["skin"] as! [String: Any]
        skin["id"] = "someone-else"
        skinMismatch["skin"] = skin
        XCTAssertThrowsError(
            try AppearanceDocument.decode(
                JSONSerialization.data(withJSONObject: skinMismatch)),
            "a skin identity that differs from the project must be rejected")
        var barMismatch = object
        var bar = object["candidateBar"] as! [String: Any]
        bar["id"] = "other-bar"
        barMismatch["candidateBar"] = bar
        XCTAssertThrowsError(
            try AppearanceDocument.decode(
                JSONSerialization.data(withJSONObject: barMismatch)),
            "a candidate-area identity that differs from the project must be rejected")
    }

    func testCopyGivesOneNewIdentityForAllParts() {
        let document = makeDocument(
            id: "look-a", name: "A", accent: "#145ACC",
            candidateSize: 22, collapsedHeight: 48)
        let copy = document.copy()
        XCTAssertNotEqual(copy.id, document.id)
        XCTAssertTrue(copy.identityIsConsistent, "a duplicate must move all three identities to the same new identity")
        XCTAssertEqual(copy.skin.id, copy.id)
        XCTAssertEqual(copy.candidateBar.id, copy.id)
        XCTAssertEqual(copy.name, document.name + " 副本")
        XCTAssertEqual(copy.skin.typography.candidateSize, document.skin.typography.candidateSize)
        XCTAssertEqual(copy.candidateBar.collapsed, document.candidateBar.collapsed)
        XCTAssertTrue(copy.isSystemDefault == false)
        XCTAssertTrue(AppearanceDocument.systemDefault.isSystemDefault)
    }

    /// The candidate area stores layout behavior only; colors and fonts always derive from the skin.
    func testCandidateAreaCarriesLayoutOnlyAndSkinOwnsColorsAndFonts() throws {
        let document = makeDocument(
            id: "look-a", name: "A", accent: "#145ACC",
            candidateSize: 27, collapsedHeight: 52)
        let barJSON = String(decoding: try document.candidateBar.encoded(), as: UTF8.self)
        for forbidden in ["color", "accent", "font", "typography", "candidateSize"] {
            XCTAssertFalse(barJSON.contains(forbidden), "candidate-area config must not carry \(forbidden)")
        }
        // Changing only the skin leaves every candidate-area field unchanged.
        var reskinned = document.skin
        reskinned.typography.candidateSize = 18
        let updated = document.replacing(skin: reskinned)
        XCTAssertEqual(updated.candidateBar, document.candidateBar)
        XCTAssertEqual(updated.skin.typography.candidateSize, 18)
        XCTAssertTrue(updated.identityIsConsistent)
        // Changing only the candidate layout leaves every skin field unchanged.
        var bar = document.candidateBar
        bar.expanded.mode = .grid
        bar.expanded.columns = 3
        let relaid = document.replacing(candidateBar: bar)
        XCTAssertEqual(relaid.skin, document.skin)
        XCTAssertEqual(relaid.candidateBar.expanded.columns, 3)
        XCTAssertTrue(relaid.identityIsConsistent)
    }

    // MARK: - Atomic apply / read consistency

    func testAtomicApplyKeepsSkinAndBarInOneGeneration() throws {
        let directory = temporaryDirectory("atomic")
        let host = store(directory), reader = store(directory)
        let first = makeDocument(
            id: "look-a", name: "A", accent: "#145ACC",
            candidateSize: 22, collapsedHeight: 44)
        let second = makeDocument(
            id: "look-b", name: "B", accent: "#CC3311",
            candidateSize: 26, collapsedHeight: 52)
        // saving is not applying
        try host.save(first)
        XCTAssertEqual(try reader.readSnapshot().selectedID, AppearanceDocument.systemDefaultID)
        try host.apply(first)
        XCTAssertEqual(try reader.readSnapshot().selectedID, first.id)
        try host.save(second, replacing: false)
        XCTAssertThrowsError(try host.save(second, replacing: false), "the same ID requires explicit replacement")
        try host.apply(second)

        let read = reader.read()
        XCTAssertEqual(read.source, .applied)
        XCTAssertNil(read.error)
        XCTAssertTrue(read.identityIsConsistent)
        // One read yields B's skin and B's candidate area together; "A skin + B candidate bar" is impossible.
        XCTAssertEqual(read.snapshot.document.skin, second.skin)
        XCTAssertEqual(read.snapshot.document.candidateBar, second.candidateBar)
        XCTAssertEqual(read.snapshot.document.collapsedHeight, 52)

        // A corrupt snapshot reads as the built-in default with a clear error.
        try Data("broken".utf8).write(to: directory.appendingPathComponent("active.json"), options: .atomic)
        let degraded = reader.read()
        XCTAssertEqual(degraded.source, .systemDefault)
        XCTAssertNotNil(degraded.error)
        XCTAssertTrue(degraded.identityIsConsistent)
        XCTAssertThrowsError(try reader.readSnapshot(), "a strict read must throw")
    }

    func testSnapshotSizeLimit() throws {
        let directory = temporaryDirectory("bounded-snapshot")
        let appearance = store(directory)
        let second = makeDocument(
            id: "look-b", name: "B", accent: "#CC3311",
            candidateSize: 24, collapsedHeight: 52)
        try appearance.apply(second)

        let active = directory.appendingPathComponent("active.json")
        let encoded = try JSONEncoder().encode(AppearanceSnapshot(document: second))
        let limit = 512 * 1024
        XCTAssertLessThan(encoded.count, limit)
        var boundary = encoded
        boundary.append(Data(repeating: 0x20, count: limit - encoded.count))
        try boundary.write(to: active, options: .atomic)
        XCTAssertEqual(try appearance.readSnapshot().selectedID, second.id)

        boundary.append(0x20)
        try boundary.write(to: active, options: .atomic)
        XCTAssertThrowsError(try appearance.readSnapshot()) { error in
            XCTAssertTrue(error.localizedDescription.contains("外观快照过大"))
        }
        let degraded = appearance.read()
        XCTAssertEqual(degraded.source, .systemDefault)
        XCTAssertEqual(degraded.snapshot.selectedID, AppearanceDocument.systemDefaultID)
        XCTAssertNotNil(degraded.error)
    }

    func testAppliedSnapshotRejectsSelectionContentMismatch() throws {
        let directory = temporaryDirectory("mismatch")
        let host = store(directory), reader = store(directory)
        let document = makeDocument(
            id: "look-a", name: "A", accent: "#145ACC",
            candidateSize: 22, collapsedHeight: 44)
        try host.apply(document)
        var object =
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: directory.appendingPathComponent("active.json"))) as! [String: Any]
        object["selectedID"] = "look-b"
        try JSONSerialization.data(withJSONObject: object)
            .write(to: directory.appendingPathComponent("active.json"), options: .atomic)
        XCTAssertThrowsError(try reader.readSnapshot())
        let read = reader.read()
        XCTAssertTrue(read.identityIsConsistent)
        XCTAssertNotNil(read.error)
        XCTAssertNotEqual(read.source, .applied)
    }

    func testSaveIsNotApplySystemDefaultReadOnlyAndInvalidRejected() throws {
        let directory = temporaryDirectory("save-apply")
        let host = store(directory)
        XCTAssertThrowsError(try host.save(.systemDefault), "the system default is read-only")
        XCTAssertThrowsError(try host.remove(AppearanceDocument.systemDefaultID))
        let document = makeDocument(
            id: "look-a", name: "A", accent: "#145ACC",
            candidateSize: 22, collapsedHeight: 44)
        try host.save(document)
        XCTAssertEqual(
            try host.list().map(\.id),
            [AppearanceDocument.systemDefaultID] + AppearanceDocument.builtinPresets.map(\.id) + ["look-a"])
        var invalid = document
        invalid.collapsedHeight = .infinity
        XCTAssertThrowsError(try host.apply(invalid), "invalid values cannot be applied")
        XCTAssertThrowsError(try host.save(invalid))
        XCTAssertEqual(try host.readSnapshot().selectedID, AppearanceDocument.systemDefaultID)
        // Applying the built-in default is legal (the user explicitly switches back).
        try host.apply(.systemDefault)
        XCTAssertEqual(try host.readSnapshot().selectedID, AppearanceDocument.systemDefaultID)
    }

    func testListRejectsFileNameIdentityMismatch() throws {
        let directory = temporaryDirectory("filename")
        let document = makeDocument(
            id: "look-a", name: "A", accent: "#145ACC",
            candidateSize: 22, collapsedHeight: 44)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try document.encoded().write(
            to: directory.appendingPathComponent("someone-else.songyanappearance.json"), options: .atomic)
        XCTAssertThrowsError(try store(directory).list(), "the file name must match the identity")
    }

    func testRemoveKeepsAppliedSnapshotUntilNextApply() throws {
        let directory = temporaryDirectory("remove")
        let host = store(directory)
        let document = makeDocument(
            id: "look-a", name: "A", accent: "#145ACC",
            candidateSize: 22, collapsedHeight: 44)
        try host.save(document)
        try host.apply(document)
        try host.remove(document.id)
        // The applied snapshot keeps its content until the next apply.
        XCTAssertEqual(try host.readSnapshot().document.candidateBar, document.candidateBar)
        XCTAssertEqual(
            try host.list().map(\.id),
            [AppearanceDocument.systemDefaultID] + AppearanceDocument.builtinPresets.map(\.id))
    }

    // MARK: - Import

    func testImportAcceptsAppearanceSkinAndBarFiles() throws {
        // new composite file
        let document = makeDocument(
            id: "look-a", name: "A", accent: "#145ACC",
            candidateSize: 22, collapsedHeight: 48)
        XCTAssertEqual(try AppearanceDocument.decodeImported(document.encoded()), document)

        // Standalone skin file (custom id): wrapped with the system-default candidate layout.
        var skin = SkinDefinition.systemDefault.copy()
        skin.name = "旧皮肤"
        let importedSkin = try AppearanceDocument.decodeImported(try skin.encoded())
        XCTAssertEqual(importedSkin.id, skin.id)
        XCTAssertEqual(importedSkin.name, "旧皮肤")
        XCTAssertEqual(importedSkin.skin.typography, skin.typography)
        XCTAssertEqual(importedSkin.candidateBar.collapsed, CandidateBarDefinition.systemDefault.collapsed)
        XCTAssertTrue(importedSkin.identityIsConsistent)

        // Built-in default skin file: automatically copied to a new identity so it does not collide with the read-only default.
        let importedDefault = try AppearanceDocument.decodeImported(try SkinDefinition.systemDefault.encoded())
        XCTAssertNotEqual(importedDefault.id, AppearanceDocument.systemDefaultID)
        XCTAssertTrue(importedDefault.identityIsConsistent)

        // Standalone candidate-area file: wrapped with the system-default skin.
        var bar = CandidateBarDefinition.systemDefault.copy()
        bar.name = "旧候选区"
        bar.expanded.mode = .grid
        bar.expanded.columns = 3
        let importedBar = try AppearanceDocument.decodeImported(try bar.encoded())
        XCTAssertEqual(importedBar.id, bar.id)
        XCTAssertEqual(importedBar.candidateBar.expanded.columns, 3)
        XCTAssertEqual(importedBar.skin.typography, SkinDefinition.systemDefault.typography)
        XCTAssertTrue(importedBar.identityIsConsistent)

        // Unrecognized JSON / snapshot files are rejected explicitly rather than with a vague schema error.
        XCTAssertThrowsError(try AppearanceDocument.decodeImported(Data(#"{"hello":1}"#.utf8)))
        XCTAssertThrowsError(try AppearanceDocument.decodeImported(Data("broken".utf8)))
        for snapshot in [
            #"{"selectedSkinID":"x","skin":{"formatVersion":1,"id":"x","name":"x"},"appearance":"system"}"#,
            #"{"selectedBarID":"x","bar":{"formatVersion":1,"id":"x","name":"x"}}"#,
            #"{"selectedID":"x","document":{"formatVersion":1,"id":"x","name":"x"}}"#,
        ] {
            XCTAssertThrowsError(try AppearanceDocument.decodeImported(Data(snapshot.utf8)), snapshot)
        }
    }
}

private extension AppearanceDocument {
    var collapsedHeight: Double {
        get { candidateBar.collapsed.height }
        set { candidateBar.collapsed.height = newValue }
    }
}

final class AppearancePresetTests: XCTestCase {
    func testBuiltinPresetsAreConsistentAndDistinct() throws {
        let presets = AppearanceDocument.builtinPresets
        XCTAssertEqual(Set(presets.map(\.id)).count, presets.count)
        for preset in presets {
            XCTAssertTrue(preset.identityIsConsistent, preset.id)
            XCTAssertTrue(preset.isBuiltin)
            XCTAssertFalse(preset.isSystemDefault)
            // Round-trip encoding loses nothing (export and apply share one format).
            XCTAssertEqual(try AppearanceDocument.decode(preset.encoded()).skin, preset.skin)
        }
    }
}
