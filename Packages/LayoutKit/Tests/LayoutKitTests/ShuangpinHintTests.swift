import XCTest

@testable import LayoutKit

/// Bounded validation and roundtrip tests for the shuangpin hint presets.
///
/// The contract the keyboard relies on: one atomic snapshot carries selection and content together,
/// the default is off, and every document the user imported by link or file is read strictly —
/// an inconsistent file is refused, never quietly repaired.
final class ShuangpinHintTests: XCTestCase {

    // MARK: - Fixtures

    private func temporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shuangpin-hints-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private var doItPreset: ShuangpinHintPreset {
        ShuangpinHintPreset(
            id: "my-diy", name: "我的提示",
            hints: ["q": "iq", "w": "ua", "e": "e", "z": "ei"])
    }

    // MARK: - Built-in preset

    func testBuiltinPresetCarriesTheXiaoheDisplayHints() {
        let builtin = ShuangpinHintPresets.builtinXiaohe
        XCTAssertEqual(builtin.id, "xiaohe-26")
        XCTAssertEqual(builtin.name, "小鹤双拼提示")
        XCTAssertEqual(builtin.hints.count, 24)
        XCTAssertEqual(builtin.hints["q"], "iu")
        XCTAssertEqual(builtin.hints["l"], "iang/uang")
        XCTAssertEqual(builtin.hints["k"], "ing/uai")
        // a and e have no final: they must read as "no hint", never as an empty badge.
        XCTAssertEqual(Set(builtin.hints.keys), Set(ShuangpinHintPreset.letters).subtracting(["a", "e"]))
        XCTAssertNoThrow(try builtin.validate())
    }

    // MARK: - Default state and persistence

    func testDefaultSnapshotIsOffAndPointsAtTheBuiltinPreset() {
        let snapshot = ShuangpinHintSnapshot.disabled
        XCTAssertFalse(snapshot.enabled)
        XCTAssertEqual(snapshot.selectedPresetID, "xiaohe-26")
        XCTAssertEqual(snapshot.presets.map(\.id), ["xiaohe-26"])
        XCTAssertNil(snapshot.activePreset, "hints must stay off until the user turns them on")
        XCTAssertEqual(snapshot.userPresets, [])
        XCTAssertTrue(snapshot.isBuiltin(ShuangpinHintPresets.builtinXiaohe))
        XCTAssertNoThrow(try snapshot.validate())
    }

    func testMissingFileLoadsAsTheOffDefaultWithoutWriting() throws {
        let directory = try temporaryDirectory("missing")
        let store = ShuangpinHintStore(directory: directory)
        XCTAssertEqual(try store.load(), .disabled)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: store.catalogURL.path),
            "reading must not create storage")
    }

    func testSaveAndLoadRoundtripsSelectionContentAndToggles() throws {
        let directory = try temporaryDirectory("roundtrip")
        let store = ShuangpinHintStore(directory: directory)
        let snapshot = ShuangpinHintSnapshot(
            enabled: true, selectedPresetID: doItPreset.id,
            presets: ShuangpinHintPresets.all + [doItPreset])
        try store.save(snapshot)
        let loaded = try store.load()
        XCTAssertEqual(loaded, snapshot)
        XCTAssertEqual(loaded.activePreset?.hints, doItPreset.hints)
        XCTAssertEqual(loaded.selectedPresetName, "我的提示")
    }

    func testEncodedDocumentRoundtripsThroughTheStrictDecoder() throws {
        let directory = try temporaryDirectory("document")
        let store = ShuangpinHintStore(directory: directory)
        let snapshot = ShuangpinHintSnapshot(
            enabled: true, selectedPresetID: doItPreset.id,
            presets: ShuangpinHintPresets.all + [doItPreset])
        try store.save(snapshot)
        let onDisk = try Data(contentsOf: store.catalogURL)
        XCTAssertEqual(try ShuangpinHintStore.decodeSnapshot(onDisk), snapshot)
    }

    func testSinglePresetFileRoundtrips() throws {
        let data = try ShuangpinHintStore.encodePreset(doItPreset)
        XCTAssertEqual(try ShuangpinHintStore.decodePresetFile(data), doItPreset)
    }

    func testSnapshotFileImportsThePresetInUse() throws {
        let snapshot = ShuangpinHintSnapshot(
            enabled: true, selectedPresetID: doItPreset.id,
            presets: ShuangpinHintPresets.all + [doItPreset])
        let data = try ShuangpinHintStore.encodeSnapshot(snapshot)
        XCTAssertEqual(try ShuangpinHintStore.decodePresetFile(data), doItPreset)
    }

    func testDisabledSnapshotFileImportsAUserPresetNotTheBuiltinOne() throws {
        let snapshot = ShuangpinHintSnapshot(
            enabled: false,
            presets: ShuangpinHintPresets.all + [doItPreset])
        let data = try ShuangpinHintStore.encodeSnapshot(snapshot)
        XCTAssertEqual(try ShuangpinHintStore.decodePresetFile(data), doItPreset)
    }

    // MARK: - Fail closed

    func testStoredFileWithoutTheBuiltinPresetKeepsExactlyWhatItSays() throws {
        let json = """
            {"version":1,"enabled":true,"selectedPresetID":"my-diy","presets":[
              {"version":1,"id":"my-diy","name":"我的提示","hints":{"q":"iq"}}]}
            """
        let snapshot = try ShuangpinHintStore.decodeSnapshot(Data(json.utf8))
        XCTAssertEqual(snapshot.presets.map(\.id), ["my-diy"])
        XCTAssertEqual(snapshot.activePreset?.id, "my-diy")
    }

    func testEnsuringTheBuiltinPresetIsAnExplicitAction() {
        let snapshot = ShuangpinHintSnapshot(
            enabled: true, selectedPresetID: "my-diy",
            presets: [doItPreset]
        ).ensuringBuiltinPreset()
        XCTAssertEqual(snapshot.presets.map(\.id), ["xiaohe-26", "my-diy"])
        XCTAssertEqual(snapshot.activePreset?.id, "my-diy")
        XCTAssertEqual(snapshot.ensuringBuiltinPreset(), snapshot, "the repair is idempotent")
    }

    func testUnknownSelectedPresetIsRejectedNotRepaired() {
        let snapshot = ShuangpinHintSnapshot(
            enabled: true, selectedPresetID: "gone",
            presets: ShuangpinHintPresets.all + [doItPreset])
        XCTAssertThrowsError(
            try snapshot.validate(),
            "a selection that no longer exists must fail closed, not switch to the built-in preset")
        let json = """
            {"version":1,"enabled":true,"selectedPresetID":"gone","presets":[
              {"version":1,"id":"my-diy","name":"我的提示","hints":{"q":"iq"}}]}
            """
        XCTAssertThrowsError(try ShuangpinHintStore.decodeSnapshot(Data(json.utf8)))
    }

    func testEmptySelectionIsRejected() {
        let snapshot = ShuangpinHintSnapshot(
            enabled: true, selectedPresetID: "",
            presets: ShuangpinHintPresets.all)
        XCTAssertThrowsError(try snapshot.validate())
    }

    func testDuplicatePresetIdentitiesAreRejectedNotDropped() {
        let snapshot = ShuangpinHintSnapshot(
            enabled: true, selectedPresetID: "my-diy",
            presets: [ShuangpinHintPresets.builtinXiaohe, doItPreset, doItPreset])
        XCTAssertThrowsError(try snapshot.validate())
        let json = """
            {"version":1,"enabled":false,"selectedPresetID":"my-diy","presets":[
              {"version":1,"id":"my-diy","name":"甲","hints":{"q":"iq"}},
              {"version":1,"id":"my-diy","name":"乙","hints":{"q":"ua"}}]}
            """
        XCTAssertThrowsError(try ShuangpinHintStore.decodeSnapshot(Data(json.utf8)))
    }

    // MARK: - Rejections (oversized, unknown and malformed input)

    func testTooManyHintEntriesAreRejected() {
        var hints: [String: String] = [:]
        for index in 0..<27 { hints["\(Character(UnicodeScalar(97 + index)!))"] = "x" }
        XCTAssertThrowsError(try ShuangpinHintPreset(id: "too-many", name: "太多", hints: hints).validate())
    }

    func testTwentySixHintEntriesAreAccepted() throws {
        var hints: [String: String] = [:]
        for letter in ShuangpinHintPreset.letters { hints[letter] = "ab" }
        XCTAssertEqual(hints.count, 26)
        XCTAssertNoThrow(try ShuangpinHintPreset(id: "full", name: "满表", hints: hints).validate())
    }

    func testOversizedHintTextIsRejectedAtTheByteBoundary() throws {
        let atLimit = String(repeating: "a", count: ShuangpinHintPreset.maximumHintBytes)
        XCTAssertNoThrow(try ShuangpinHintPreset(id: "edge", name: "边界", hints: ["q": atLimit]).validate())
        let overLimit = String(repeating: "a", count: ShuangpinHintPreset.maximumHintBytes + 1)
        XCTAssertThrowsError(try ShuangpinHintPreset(id: "edge", name: "边界", hints: ["q": overLimit]).validate())
        // Multi-byte text is bounded by bytes, not characters.
        let chinese = String(repeating: "韵", count: 11)
        XCTAssertThrowsError(try ShuangpinHintPreset(id: "edge", name: "边界", hints: ["q": chinese]).validate())
    }

    func testBlankHintsAreDroppedInsteadOfDrawnEmpty() {
        let preset = ShuangpinHintPreset(
            id: "blank", name: "空提示",
            hints: ["q": "iu", "w": "   ", "e": ""]
        ).normalized()
        XCTAssertEqual(preset.hints, ["q": "iu"])
    }

    func testBadPresetFieldsAreRejected() {
        XCTAssertThrowsError(try ShuangpinHintPreset(id: "", name: "无标识", hints: [:]).validate())
        XCTAssertThrowsError(try ShuangpinHintPreset(id: "空格 标识", name: "坏标识", hints: [:]).validate())
        XCTAssertThrowsError(try ShuangpinHintPreset(id: "ok", name: "   ", hints: [:]).validate())
        XCTAssertThrowsError(
            try ShuangpinHintPreset(id: "ok", name: "大写键", hints: ["Q": "iu"]).validate(),
            "a file must write lowercase letters, not rely on silent normalization")
        XCTAssertThrowsError(try ShuangpinHintPreset(id: "ok", name: "长键", hints: ["qq": "iu"]).validate())
        XCTAssertThrowsError(try ShuangpinHintPreset(id: "ok", name: "数字键", hints: ["1": "iu"]).validate())
        XCTAssertThrowsError(try ShuangpinHintPreset(id: "ok", name: "换行", hints: ["q": "a\nb"]).validate())
        // "\r\n" is one Character, so a Character-level check would let it through.
        XCTAssertThrowsError(try ShuangpinHintPreset(id: "ok", name: "换行", hints: ["q": "a\r\nb"]).validate())
        XCTAssertThrowsError(try ShuangpinHintPreset(id: "ok", name: "换行", hints: ["q": "a\rb"]).validate())
        XCTAssertThrowsError(try ShuangpinHintPreset(id: "ok", name: "版本", hints: [:], version: 2).validate())
    }

    func testUnknownFieldsAreRejectedWithTheFieldNamed() {
        let presetJSON = """
            {"version":1,"id":"x","name":"未知字段","hints":{},"extra":1}
            """
        XCTAssertThrowsError(try ShuangpinHintStore.decodePresetFile(Data(presetJSON.utf8))) { error in
            XCTAssertTrue("\(error.localizedDescription)".contains("extra"), "\(error)")
        }
        let snapshotJSON = """
            {"version":1,"enabled":false,"selectedPresetID":"xiaohe-26","presets":[],"weight":3}
            """
        XCTAssertThrowsError(try ShuangpinHintStore.decodeSnapshot(Data(snapshotJSON.utf8))) { error in
            XCTAssertTrue("\(error.localizedDescription)".contains("weight"), "\(error)")
        }
    }

    func testWrongVersionAndWrongTypesAreRejected() {
        let wrongVersion = #"{"version":2,"enabled":false,"selectedPresetID":"xiaohe-26","presets":[]}"#
        XCTAssertThrowsError(try ShuangpinHintStore.decodeSnapshot(Data(wrongVersion.utf8)))
        let wrongType = #"{"version":1,"enabled":"yes","selectedPresetID":"xiaohe-26","presets":[]}"#
        XCTAssertThrowsError(try ShuangpinHintStore.decodeSnapshot(Data(wrongType.utf8))) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("开关") && message.contains("enabled"), message)
            XCTAssertFalse(message.contains("$."), "messages name the field, not a JSON path: \(message)")
        }
        let missingName = #"{"version":1,"id":"x","hints":{}}"#
        XCTAssertThrowsError(try ShuangpinHintStore.decodePresetFile(Data(missingName.utf8))) { error in
            XCTAssertTrue(error.localizedDescription.contains("名称"), error.localizedDescription)
        }
        let badPresets = #"{"version":1,"enabled":false,"selectedPresetID":"xiaohe-26","presets":"none"}"#
        XCTAssertThrowsError(try ShuangpinHintStore.decodeSnapshot(Data(badPresets.utf8)))
        let badHintValue = #"{"version":1,"id":"x","name":"坏值","hints":{"q":5}}"#
        XCTAssertThrowsError(try ShuangpinHintStore.decodePresetFile(Data(badHintValue.utf8)))
        let duplicateCase = #"{"version":1,"id":"x","name":"重复","hints":{"q":"iu","Q":"ei"}}"#
        XCTAssertThrowsError(
            try ShuangpinHintStore.decodePresetFile(Data(duplicateCase.utf8)),
            "mixed case must be refused, never silently merged")
    }

    func testBooleanAndNumericJsonPrimitivesAreNotInterchangeable() {
        // JSONSerialization bridges true/false to NSNumber; a version of true must not read as 1.
        let boolVersion = #"{"version":true,"enabled":false,"selectedPresetID":"xiaohe-26","presets":[]}"#
        XCTAssertThrowsError(try ShuangpinHintStore.decodeSnapshot(Data(boolVersion.utf8)))
        let numericFlag = #"{"version":1,"enabled":1,"selectedPresetID":"xiaohe-26","presets":[]}"#
        XCTAssertThrowsError(try ShuangpinHintStore.decodeSnapshot(Data(numericFlag.utf8)))
        let fractionalVersion = #"{"version":1.5,"enabled":false,"selectedPresetID":"xiaohe-26","presets":[]}"#
        XCTAssertThrowsError(try ShuangpinHintStore.decodeSnapshot(Data(fractionalVersion.utf8)))
    }

    func testOversizedDocumentIsRejectedBeforeDecoding() throws {
        let padding = String(repeating: "a", count: ShuangpinHintDocument.maximumBytes)
        let json = "{\"version\":1,\"id\":\"x\",\"name\":\"大文件\",\"hints\":{\"q\":\"\(padding)\"}}"
        XCTAssertThrowsError(try ShuangpinHintStore.decodePresetFile(Data(json.utf8))) { error in
            XCTAssertTrue("\(error.localizedDescription)".contains("过大"), "\(error)")
        }
    }

    func testTooManyPresetsAreRejectedBeforeAnyNormalization() {
        var presets = ShuangpinHintPresets.all
        for index in 0...ShuangpinHintSnapshot.maximumPresets {
            presets.append(ShuangpinHintPreset(id: "preset\(index)", name: "预设 \(index)", hints: ["q": "iu"]))
        }
        let snapshot = ShuangpinHintSnapshot(enabled: true, selectedPresetID: "preset0", presets: presets)
        XCTAssertThrowsError(try snapshot.validate())
        // Duplicates cannot slip under the bound either: the count is checked on the raw list.
        let duplicated = ShuangpinHintSnapshot(
            enabled: false, selectedPresetID: "xiaohe-26",
            presets: Array(
                repeating: ShuangpinHintPresets.builtinXiaohe,
                count: ShuangpinHintSnapshot.maximumPresets + 1))
        XCTAssertThrowsError(try duplicated.validate())
    }

    func testOversizedStoredFileIsRejectedByTheLoadPath() throws {
        let directory = try temporaryDirectory("oversized")
        let store = ShuangpinHintStore(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: ShuangpinHintDocument.maximumBytes + 1).write(to: store.catalogURL)
        XCTAssertThrowsError(try store.load())
    }

    func testImportedFileReaderRefusesOversize() throws {
        let directory = try temporaryDirectory("import")
        let real = directory.appendingPathComponent("real.json")
        try Data(#"{"version":1,"id":"x","name":"甲","hints":{"q":"iu"}}"#.utf8).write(to: real)
        XCTAssertEqual(
            try ShuangpinHintStore.readImportedFile(at: real).count,
            #"{"version":1,"id":"x","name":"甲","hints":{"q":"iu"}}"#.utf8.count)
        let big = directory.appendingPathComponent("big.json")
        try Data(repeating: 0x41, count: ShuangpinHintDocument.maximumBytes + 1).write(to: big)
        XCTAssertThrowsError(try ShuangpinHintStore.readImportedFile(at: big))
    }

    // MARK: - Editing helpers

    func testCopyGetsANewIdentityAndKeepsTheHints() {
        let copy = doItPreset.copy()
        XCTAssertNotEqual(copy.id, doItPreset.id)
        XCTAssertEqual(copy.hints, doItPreset.hints)
        XCTAssertEqual(copy.name, "我的提示 副本")
        XCTAssertEqual(doItPreset.renamed("改名").id, doItPreset.id)
    }

    func testTurningHintsOnKeepsAUsableSelection() throws {
        var snapshot = ShuangpinHintSnapshot.disabled
        snapshot.enabled = true
        try snapshot.validate()
        XCTAssertEqual(snapshot.activePreset?.id, "xiaohe-26")
        XCTAssertNil(
            ShuangpinHintSnapshot.disabled.activePreset,
            "the same preset stays hidden while the switch is off")
    }
}
