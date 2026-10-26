import Foundation
import XCTest

@testable import LayoutKit

final class KeyboardCompositionTests: XCTestCase {
    func testCatalogAtTheKeyBudgetStillLoadsWithTheBuiltInPages() throws {
        let key = LayoutKey(label: "a", action: .init(.literal, value: "a"))
        let rows = Array(repeating: LayoutRow(keys: Array(repeating: key, count: 32)), count: 8)
        let layouts = (0..<16).map { index in
            LayoutDefinition(id: "full-\(index)", name: "自定义", input: .init(builtinLayout: .qwerty26), rows: rows)
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "layouts": try JSONSerialization.jsonObject(with: JSONEncoder().encode(layouts)),
            "enabledIDs": [layouts[0].id],
        ])
        let registry = try JSONDecoder().decode(LayoutRegistry.self, from: data)
        XCTAssertNoThrow(try registry.validate())
        XCTAssertEqual(registry.pages, KeyboardPagePresets.all)
    }

    func testTwoKeyboardsKeepIndependentPageSelectionsAcrossStoreRoundTrip() throws {
        var registry = try LayoutRegistry()
        var custom = KeyboardPagePresets.numericChinese.copy(name: "我的数字")
        custom.rows = [
            .init(keys: [
                .init(
                    label: "一", width: 2, action: .init(.literal, value: "1"),
                    longPress: [.init(label: "①", action: .init(.literal, value: "①"))]),
                .init(label: "二", action: .init(.literal, value: "2")),
            ])
        ]
        custom.split = .init(rowBreaks: [1], gapFraction: 0.2)
        try registry.savePage(custom)
        let original = KeyboardComposition(mainLayoutID: BuiltinLayouts.qwerty26.id)
        var changed = original
        changed.numericPageID = custom.id
        try registry.setComposition(original, for: "first:qwerty26")
        try registry.setComposition(changed, for: "second:qwerty26")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LayoutStore(directoryURL: root)
        try store.save(registry)
        let loaded = try store.load()
        XCTAssertEqual(loaded.compositions["first:qwerty26"], original)
        XCTAssertEqual(loaded.compositions["second:qwerty26"], changed)
        XCTAssertEqual(loaded.page(id: custom.id), custom)
        XCTAssertEqual(loaded.page(id: custom.id)?.layoutDefinition.split, custom.split)
    }

    func testInvalidCompositionAndReferencedRemovalLeaveCatalogIntact() throws {
        var registry = try LayoutRegistry()
        let custom = KeyboardPagePresets.symbolsChinese.copy()
        try registry.savePage(custom)
        let composition = KeyboardComposition(mainLayoutID: BuiltinLayouts.qwerty26.id, symbolPageID: custom.id)
        try registry.setComposition(composition, for: "test:qwerty26")
        let before = registry
        var invalid = composition
        invalid.numericPageID = custom.id
        XCTAssertThrowsError(try registry.setComposition(invalid, for: "other:qwerty26"))
        XCTAssertEqual(registry, before)
        XCTAssertThrowsError(try registry.removePage(id: custom.id))
        XCTAssertThrowsError(try registry.remove(id: composition.mainLayoutID))
        XCTAssertEqual(registry, before)
        var missing = composition
        missing.mainLayoutID = "missing"
        XCTAssertThrowsError(try registry.setComposition(missing, for: "other:qwerty26"))
    }

    func testSymbolBrowsersRemainSelectableAndCopiesRetainTheirPresentation() throws {
        let registry = try LayoutRegistry()
        XCTAssertEqual(registry.page(id: KeyboardPagePresets.symbolsSystem.id)?.symbolPresentation, .automatic)
        XCTAssertEqual(registry.page(id: KeyboardPagePresets.symbolsCategorized.id)?.symbolPresentation, .categorized)
        let copy = KeyboardPagePresets.symbolsCategorized.copy()
        XCTAssertNotEqual(copy.id, KeyboardPagePresets.symbolsCategorized.id)
        XCTAssertEqual(copy.symbolPresentation, .categorized)
        XCTAssertNil(copy.categories)
        XCTAssertEqual(copy.rows, KeyboardPagePresets.symbolsCategorized.rows)
        try copy.validate()
    }

    func testReplacingReferencedMainWithDifferentLayoutCapabilityIsRejected() throws {
        var registry = try LayoutRegistry()
        let custom = BuiltinLayouts.qwerty26.copy()
        try registry.install(custom.encoded())
        try registry.setComposition(.init(mainLayoutID: custom.id), for: "test:qwerty26")
        let before = registry
        let replacement = LayoutDefinition(
            id: custom.id, name: custom.name,
            input: .init(builtinLayout: .phone9), rows: BuiltinLayouts.phone9.rows)
        XCTAssertThrowsError(try registry.replace(replacement))
        XCTAssertEqual(registry, before)
    }

    func testBoundLayoutsCanOnlyBeCombinedWithTheirOwnInputMethod() throws {
        var registry = try LayoutRegistry()
        let layout = LayoutDefinition(
            id: "bound", name: "我的布局", input: .init(schemaID: "my_method"),
            rows: BuiltinLayouts.qwerty26.rows)
        try registry.install(layout.encoded(), enable: false)
        let composition = KeyboardComposition(mainLayoutID: layout.id)
        XCTAssertNoThrow(try registry.setComposition(composition, for: "my_method:qwerty26"))
        XCTAssertThrowsError(try registry.setComposition(composition, for: "other:qwerty26"))
    }

    func testPageValidationRejectsEngineActionsAndResourceOverflow() throws {
        var page = KeyboardPagePresets.englishQwerty.copy()
        page.rows = [.init(keys: [.init(label: "a", action: .init(.code, value: "a"))])]
        XCTAssertThrowsError(try page.validate())
        page.rows = [
            .init(
                keys: Array(
                    repeating: .init(label: "a", action: .init(.literal, value: "a")),
                    count: LayoutResourceBudget.keysPerRegion + 1))
        ]
        XCTAssertThrowsError(try page.validate())
        let tooMany = (0...LayoutResourceBudget.pages).map { index in
            var copy = KeyboardPagePresets.englishQwerty
            copy.id = "page-\(index)"
            return copy
        }
        XCTAssertThrowsError(try LayoutRegistry(pages: tooMany))
    }

    // MARK: Automatic pages follow the live keyboard

    /// Saving a pairing without touching a page must not change what the pages show: the default
    /// 123 page resolves against the live language and the running main layout.
    func testDefaultSavedCompositionResolvesToTheLiveKeyboard() throws {
        var registry = try LayoutRegistry()
        // The two pairings a user gets for the built-in scheme: a 26-key and a 9-key keyboard.
        for (keyboard, layout) in [
            ("quanpin:qwerty26", BuiltinLayouts.qwerty26), ("quanpin:phone9", BuiltinLayouts.phone9),
        ] {
            try registry.setComposition(KeyboardComposition(mainLayoutID: layout.id), for: keyboard)
        }
        let loaded = try storedRoundTrip(registry)

        let rowsPage = try XCTUnwrap(
            loaded.page(id: try XCTUnwrap(loaded.compositions["quanpin:qwerty26"]).pageID(for: .numeric)))
        XCTAssertEqual(rowsPage.numericPresentation, .automatic)
        XCTAssertTrue(rowsPage.resolvesAtRuntime)
        // Chinese input keeps the ten-column Chinese page; the built-in area draws it, so the key
        // area receives no authored page.
        let chineseResolution = KeyboardPageResolver.resolve(
            page: rowsPage, kind: .numeric,
            input: .init(usesASCIIPunctuation: false, mainLayoutIsPhoneKeypad: false))
        XCTAssertEqual(chineseResolution, .automaticNumeric(form: .rows, marks: .chinese))
        XCTAssertNil(chineseResolution.page)
        // English input and ASCII fields get the half-width marks from the same page.
        XCTAssertEqual(
            KeyboardPageResolver.resolve(
                page: rowsPage, kind: .numeric,
                input: .init(usesASCIIPunctuation: true, mainLayoutIsPhoneKeypad: false)),
            .automaticNumeric(form: .rows, marks: .ascii))

        let phonePage = try XCTUnwrap(
            loaded.page(id: try XCTUnwrap(loaded.compositions["quanpin:phone9"]).pageID(for: .numeric)))
        XCTAssertEqual(phonePage.numericPresentation, .automatic)
        // A 9-key keyboard keeps its digit pad, in either punctuation width.
        for ascii in [false, true] {
            XCTAssertEqual(
                KeyboardPageResolver.resolve(
                    page: phonePage, kind: .numeric,
                    input: .init(usesASCIIPunctuation: ascii, mainLayoutIsPhoneKeypad: true)),
                .automaticNumeric(
                    form: .phoneDigitPad, marks: ascii ? .ascii : .chinese))
        }

        // The paired symbol page keeps following the configured symbol presentation.
        let symbolsPage = try XCTUnwrap(
            loaded.page(id: try XCTUnwrap(loaded.compositions["quanpin:qwerty26"]).pageID(for: .symbols)))
        XCTAssertEqual(
            KeyboardPageResolver.resolve(
                page: symbolsPage, kind: .symbols,
                input: .init(usesASCIIPunctuation: false, mainLayoutIsPhoneKeypad: false)),
            .automaticSymbolPage)
    }

    /// A pairing with no page for a kind keeps the built-in page area, exactly as before pairings.
    func testUnpairedKindsKeepTheBuiltInPageArea() {
        let input = KeyboardPageResolutionInput(usesASCIIPunctuation: false, mainLayoutIsPhoneKeypad: false)
        XCTAssertEqual(
            KeyboardPageResolver.resolve(page: nil, kind: .numeric, input: input),
            .automaticNumeric(form: .rows, marks: .chinese))
        XCTAssertEqual(
            KeyboardPageResolver.resolve(
                page: nil, kind: .numeric,
                input: .init(usesASCIIPunctuation: false, mainLayoutIsPhoneKeypad: true)),
            .automaticNumeric(form: .phoneDigitPad, marks: .chinese))
        XCTAssertEqual(KeyboardPageResolver.resolve(page: nil, kind: .symbols, input: input), .automaticSymbolPage)
        XCTAssertEqual(KeyboardPageResolver.resolve(page: nil, kind: .english, input: input), .builtIn)
    }

    /// An explicitly chosen 中文/英文 page keeps its own literals: no automatic conversion of the
    /// user's data, whatever the live language is.
    func testExplicitPagesKeepTheirOwnContent() throws {
        var registry = try LayoutRegistry()
        let composition = KeyboardComposition(
            mainLayoutID: BuiltinLayouts.qwerty26.id,
            symbolPageID: KeyboardPagePresets.symbolsChinese.id,
            numericPageID: KeyboardPagePresets.numericChinese.id,
            englishPageID: KeyboardPagePresets.englishQwerty.id)
        try registry.setComposition(composition, for: "quanpin:qwerty26")
        let loaded = try storedRoundTrip(registry)

        let numeric = try XCTUnwrap(loaded.page(id: composition.numericPageID))
        for ascii in [false, true] {
            let resolution = KeyboardPageResolver.resolve(
                page: numeric, kind: .numeric,
                input: .init(usesASCIIPunctuation: ascii, mainLayoutIsPhoneKeypad: false))
            guard case .authored(let authored) = resolution else {
                return XCTFail("an explicit page must stay authored (ascii=\(ascii))")
            }
            XCTAssertEqual(authored, numeric)
            XCTAssertEqual(authored.rows, KeyboardPagePresets.numericChinese.rows)
            XCTAssertTrue(
                authored.rows.flatMap(\.keys).contains { $0.action.value == "。" },
                "the Chinese marks must not be rewritten to ASCII")
        }

        let symbols = try XCTUnwrap(loaded.page(id: composition.symbolPageID))
        guard
            case .authored(let authoredSymbols) = KeyboardPageResolver.resolve(
                page: symbols, kind: .symbols,
                input: .init(usesASCIIPunctuation: true, mainLayoutIsPhoneKeypad: true))
        else { return XCTFail("an explicit symbol page must stay authored") }
        XCTAssertEqual(authoredSymbols.id, KeyboardPagePresets.symbolsChinese.id)

        let english = try XCTUnwrap(loaded.page(id: composition.englishPageID))
        guard
            case .authored = KeyboardPageResolver.resolve(
                page: english, kind: .english,
                input: .init(usesASCIIPunctuation: true, mainLayoutIsPhoneKeypad: false))
        else { return XCTFail("the ABC page pairing must stay authored") }
    }

    func testAutomaticPageRejectsAuthoredContent() throws {
        XCTAssertNoThrow(try KeyboardPagePresets.numericAutomatic.validate())
        XCTAssertThrowsError(
            try KeyboardPageDefinition(
                id: "auto-on-symbols", name: "自动符号", kind: .symbols, rows: [],
                numericPresentation: .automatic
            ).validate())
        XCTAssertThrowsError(
            try KeyboardPageDefinition(
                id: "auto-with-rows", name: "自动 123", kind: .numeric,
                rows: [.init(keys: [.init(label: "1", action: .init(.literal, value: "1"))])],
                numericPresentation: .automatic
            ).validate())
        XCTAssertThrowsError(
            try KeyboardPageDefinition(
                id: "auto-with-symbol-presentation", name: "自动 123", kind: .numeric, rows: [],
                symbolPresentation: .rows, numericPresentation: .automatic
            ).validate())
    }

    private func storedRoundTrip(_ registry: LayoutRegistry) throws -> LayoutRegistry {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("composition-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LayoutStore(directoryURL: directory)
        try store.save(registry)
        return try store.load()
    }
}
