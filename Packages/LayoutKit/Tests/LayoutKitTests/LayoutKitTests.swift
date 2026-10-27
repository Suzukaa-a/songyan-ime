import Foundation
import XCTest

@testable import LayoutKit

final class LayoutKitTests: XCTestCase {
    func testCopyAndReplacePreserveOrderAndFailureSnapshot() throws {
        var registry = try LayoutRegistry()
        let original = try XCTUnwrap(registry.layout(id: "phone9"))
        let path = LayoutKeyPath.auxiliary(0, key: 0)
        let key = try XCTUnwrap(original.key(at: path))
        let edited = original.replacingKey(
            at: path,
            with: LayoutKey(
                label: key.label, secondaryLabel: "问号", width: 1.5, action: key.action,
                longPress: [.init(label: "？", action: .init(.literal, value: "？"))]))
        try registry.replace(edited)
        XCTAssertEqual(registry.layouts.map(\.id), BuiltinLayouts.all.map(\.id))
        XCTAssertEqual(try LayoutDefinition.decode(edited.encoded()), edited)
        let copy = try registry.copy(edited)
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(copy.rows, edited.rows)
        XCTAssertEqual(copy.auxiliaryAreas, edited.auxiliaryAreas)
        XCTAssertEqual(registry.layouts.map(\.id), BuiltinLayouts.all.map(\.id) + [copy.id])
        let snapshot = registry
        let invalid = edited.replacingKey(at: path, with: .init(label: "坏", action: .init(.code, value: "abc")))
        XCTAssertThrowsError(try registry.replace(invalid))
        XCTAssertThrowsError(try registry.copy(invalid))
        XCTAssertEqual(registry, snapshot)
        XCTAssertThrowsError(try registry.replace(edited.copy()))
        XCTAssertEqual(registry, snapshot)
        try registry.install(copy.renamed("导入替换").encoded(), replaceExisting: true)
        XCTAssertEqual(registry.layout(id: copy.id)?.name, "导入替换", "a same-ID import replaces in place")
        XCTAssertEqual(registry.layouts.last?.id, copy.id)
    }

    func testImportOrderAndBundledPresetsStay() throws {
        var registry = try LayoutRegistry()
        let custom = LayoutDefinition(
            id: "DIY / a", name: "DIY", input: .init(schemaID: "installed_schema"),
            rows: BuiltinLayouts.qwerty26.rows)
        try registry.install(custom.encoded())
        XCTAssertEqual(registry.layouts.last?.id, custom.id)
        XCTAssertThrowsError(try registry.install(custom.encoded()))
        try registry.remove(id: custom.id)
        XCTAssertNil(registry.layout(id: custom.id))
        XCTAssertThrowsError(try registry.remove(id: "qwerty26"), "bundled presets are the default main layouts")
        XCTAssertEqual(registry.usableLayouts { $0.id == "qwerty26" }.map(\.id), ["qwerty26"])
    }

    func testDefaultMainLayoutPrefersTheBoundLayoutThenThePreset() throws {
        func bound(_ id: String, to schemaID: String?) -> LayoutDefinition {
            LayoutDefinition(
                id: id, name: id, input: .init(schemaID: schemaID, builtinLayout: .qwerty26),
                rows: BuiltinLayouts.qwerty26.rows)
        }
        var registry = try LayoutRegistry(layouts: [BuiltinLayouts.merged14])
        let key = KeyboardCompositionKey(inputMethodID: "luna_pinyin", layout: .qwerty26)
        XCTAssertEqual(registry.defaultMainLayoutID(for: key), "qwerty26", "a preset missing from the catalog")
        XCTAssertEqual(registry.resolvedLayout(id: "qwerty26")?.id, "qwerty26")
        try registry.install(bound("mine", to: nil).encoded())
        XCTAssertEqual(registry.defaultMainLayoutID(for: key), "qwerty26", "an unbound copy needs a pairing")
        try registry.install(bound("luna-b", to: "luna_pinyin").encoded())
        try registry.install(bound("luna-a", to: "luna_pinyin").encoded())
        XCTAssertEqual(registry.defaultMainLayoutID(for: key), "luna-a", "the smallest ID, not catalog order")
        XCTAssertEqual(registry.defaultMainLayoutID(for: .init(inputMethodID: "other", layout: .qwerty26)), "qwerty26")
        XCTAssertEqual(
            Set(registry.mainLayoutCandidates(for: key).map(\.id)), ["qwerty26", "mine", "luna-a", "luna-b"])
    }

    func testRejectInvalidActionsIncludingAlternates() throws {
        let invalid =
            #"{"id":"x","name":"x","input":{"builtinLayout":"qwerty26"},"rows":[{"keys":[{"label":"a","action":{"type":"code","value":"a"},"longPress":[{"label":"run","action":{"type":"shell","value":"echo hi"}}]}]}]}"#
        XCTAssertThrowsError(try LayoutDefinition.decode(Data(invalid.utf8)))
        XCTAssertThrowsError(try LayoutAction(.code, value: "abc").validate())
        XCTAssertThrowsError(try LayoutAction(.modeSwitch, value: "runScript").validate())
        let key = try XCTUnwrap(BuiltinLayouts.qwerty26.rows.flatMap(\.keys).first { $0.label == "a" })
        XCTAssertEqual(key.longPress?.map(\.action.value), ["，", ","])
        XCTAssertEqual(key.action, .init(.code, value: "a"))
    }

    /// The merged 14-key must have executable long-press alternates (not just secondaryLabel text):
    /// the main key sends the cluster representative letter, long-press offers the rest; l/m offer punctuation.
    func testMerged14EveryKeyHasRealLongPressAlternate() throws {
        let keys = BuiltinLayouts.merged14.rows.dropLast().flatMap(\.keys)
        XCTAssertEqual(keys.count, 14)
        for key in keys {
            let options = try XCTUnwrap(key.longPress, "\(key.label) is missing long-press alternates")
            XCTAssertFalse(options.isEmpty, "\(key.label) has empty long-press alternates")
            for option in options {
                // Real executable actions (literal/code), not display-only labels.
                XCTAssertTrue(
                    [.literal, .code].contains(option.action.type),
                    "\(key.label) 副键动作不可执行：\(option.action.type)")
            }
        }
        // Merged pair: long-pressing the second letter types it directly; the cluster head stays the main key's code.
        func alt(_ label: String) throws -> [String] {
            let key = try XCTUnwrap(keys.first { $0.label == label })
            return (key.longPress ?? []).map { $0.action.value ?? "" }
        }
        XCTAssertEqual(try alt("ER"), ["r"])
        XCTAssertEqual(try alt("UI"), ["i"])
        XCTAssertEqual(try alt("ZX"), ["x"])
        XCTAssertEqual(try alt("QW"), ["w", "1", "!"])
        let l = try XCTUnwrap(keys.first { $0.label == "L" })
        let m = try XCTUnwrap(keys.first { $0.label == "M" })
        XCTAssertEqual(l.longPress?.map(\.action.value), ["，"])
        XCTAssertEqual(m.longPress?.map(\.action.value), ["。"])
        XCTAssertFalse(keys.contains { $0.action.type == .literal && $0.action.value == nil })
    }

    func testAllExamplesAndBuiltinsValidate() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        for builtin in BuiltinLayouts.all {
            XCTAssertEqual(try LayoutDefinition.decode(builtin.encoded()), builtin)
            let file = root.appendingPathComponent("Resources/Layouts/\(builtin.id).json")
            let example = try LayoutDefinition.decode(Data(contentsOf: file))
            XCTAssertEqual(example.input, builtin.input)
            XCTAssertEqual(example.rows.flatMap(\.keys).map(\.action), builtin.rows.flatMap(\.keys).map(\.action))
            XCTAssertEqual(
                example.rows.flatMap(\.keys).map(\.width), builtin.rows.flatMap(\.keys).map(\.width), builtin.id)
            if builtin.input.builtinLayout == .qwerty26 {
                XCTAssertEqual(
                    example.rows.flatMap(\.keys).map(\.longPress), builtin.rows.flatMap(\.keys).map(\.longPress))
            }
            XCTAssertTrue(example.rows.flatMap(\.keys).contains { !($0.longPress ?? []).isEmpty })
        }
        let areas = try XCTUnwrap(BuiltinLayouts.phone9.auxiliaryAreas)
        XCTAssertFalse(areas.contains { $0.role == .punctuation })
        XCTAssertTrue(areas.contains { $0.requiresEngineDisambiguation && $0.keys.isEmpty })
    }

    /// The author-facing T9 example (`Resources/Layouts/phone9.json`) must match the builtin declaration field for field,
    /// in particular `secondaryLabel` and `longPress`.
    ///
    /// The generic loop above only compares `input` and `action`, and `longPress` only for qwerty26, so
    /// the T9 first key's `secondaryLabel`/`longPress` were never checked. The example is the copy source for
    /// authors, so it must stay in sync.
    ///
    /// This asserts whole-definition equality (including `note`), which is stricter than per-field checks.
    func testT9ExampleMatchesBuiltinDeclarationIncludingFirstKeyDigit() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appendingPathComponent("Resources/Layouts/phone9.json")
        let example = try LayoutDefinition.decode(Data(contentsOf: file))
        XCTAssertEqual(
            example, BuiltinLayouts.phone9,
            "the example must match the builtin phone9 (note, first-key badge and long-press)")
        // Pin the two fields explicitly again so they stay checked even if the equality assertion above is loosened.
        let first = example.rows[0].keys[0]
        XCTAssertEqual(first.secondaryLabel, "1", "the example's first key must have a digit 1 badge")
        XCTAssertEqual(first.longPress?.map(\.label), ["1"], "the example's first-key long-press must be 1")
        XCTAssertEqual(first.longPress?.map(\.action.value), ["1"], "long-press must type 1 directly")
        XCTAssertEqual(first.longPress?.map(\.action.type), [.literal])
        // Same style baseline as 2-9: badge = long-press = the key's digit (the first key 1 lines up with them).
        for key in example.rows.flatMap(\.keys) where key.action.type == .code {
            let digit = try XCTUnwrap(key.action.value)
            XCTAssertEqual(key.secondaryLabel, digit, "\(key.label) badge should equal its digit")
            XCTAssertEqual(
                key.longPress?.map(\.action.value), [digit],
                "\(key.label) 长按应直接输入其数字")
        }
    }

    func testStoreRoundTripAndFailedImportPreservesSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LayoutKit-\(UUID().uuidString)")
        // Only this test's newly-created directory is removed.
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LayoutStore(directoryURL: directory)
        var registry = try store.load()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        try store.save(registry)
        XCTAssertEqual(try store.load(), registry)
        let replacement = BuiltinLayouts.phone9.renamed("我的九键")
        try registry.replace(replacement)
        let copy = try registry.copy(replacement)
        try store.save(registry)
        XCTAssertEqual(try store.load(), registry)
        let beforeFailedEdit = try Data(contentsOf: store.catalogURL)
        XCTAssertThrowsError(try registry.replace(replacement.renamed("")))
        XCTAssertThrowsError(try registry.copy(replacement.renamed("")))
        XCTAssertEqual(try Data(contentsOf: store.catalogURL), beforeFailedEdit)
        XCTAssertEqual(try store.load().layout(id: copy.id), copy)
        let source = directory.appendingPathComponent("import.json")
        let custom = LayoutDefinition(
            id: "custom", name: "Custom", input: .init(builtinLayout: .qwerty26),
            rows: BuiltinLayouts.qwerty26.rows)
        try custom.encoded().write(to: source)
        let imported = try store.importLayout(from: source)
        XCTAssertEqual(imported.layouts.last?.id, "custom")
        try Data("{}".utf8).write(to: source)
        XCTAssertThrowsError(try store.importLayout(from: source))
        XCTAssertEqual(try store.load(), imported)
    }
}
