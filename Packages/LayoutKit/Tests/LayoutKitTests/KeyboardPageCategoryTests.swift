import Foundation
import XCTest

@testable import LayoutKit

final class KeyboardPageCategoryTests: XCTestCase {
    private func key(_ text: String = "！", width: Double = 1) -> LayoutKey {
        .init(
            label: text, width: width, action: .init(.literal, value: text),
            longPress: [.init(label: "!", action: .init(.literal, value: "!"))])
    }

    private func page(_ categories: [KeyboardPageCategory]) -> KeyboardPageDefinition {
        .init(
            id: "custom-symbols", name: "我的符号", kind: .symbols, rows: [],
            symbolPresentation: .categorized, categories: categories)
    }

    func testCategorizedCopyKeepsEditableContentAndIndependentValueSemantics() throws {
        let original = page([
            .init(
                id: "punctuation", name: "标点", columns: 2, keys: [key(width: 2), key("？")],
                split: .init(rowBreaks: [1], gapFraction: 0.2)),
            .init(id: "recent", name: "最近", keys: [key("。")], source: .recent),
        ])
        var copy = original.copy()
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(copy.symbolPresentation, .categorized)
        XCTAssertEqual(copy.categories, original.categories)
        XCTAssertTrue(copy.rows.isEmpty)
        copy.categories?[0].name = "常用标点"
        copy.categories?[0].keys.reverse()
        XCTAssertEqual(original.categories?[0].name, "标点")
        XCTAssertEqual(original.categories?[0].keys.first?.widthWeight, 2)
        try original.validate()
        try copy.validate()
    }

    func testCategoriesAndRecentSourceSurviveCatalogSaveAndReload() throws {
        let symbols = page([
            .init(
                id: "fixed", name: "自定", columns: 3, keys: [key("。"), key(width: 2), key("？"), key("：")],
                split: .init(rowBreaks: [1, 2], gapFraction: 0.18)),
            .init(id: "recent", name: "刚用过", columns: 2, keys: [], source: .recent),
        ])
        var registry = try LayoutRegistry()
        try registry.savePage(symbols)
        try registry.setComposition(
            .init(mainLayoutID: BuiltinLayouts.qwerty26.id, symbolPageID: symbols.id),
            for: "first:qwerty26")
        try registry.setComposition(.init(mainLayoutID: BuiltinLayouts.qwerty26.id), for: "second:qwerty26")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LayoutStore(directoryURL: directory)
        try store.save(registry)
        let loaded = try store.load()
        XCTAssertEqual(loaded.page(id: symbols.id), symbols)
        XCTAssertEqual(loaded.compositions["first:qwerty26"]?.symbolPageID, symbols.id)
        XCTAssertEqual(loaded.compositions["second:qwerty26"]?.symbolPageID, KeyboardPagePresets.symbolsSystem.id)
        XCTAssertEqual(loaded.page(id: symbols.id)?.categories?[1].source, .recent)
        XCTAssertEqual(loaded.page(id: symbols.id)?.categories?[0].rows.map { $0.keys.count }, [3, 1])
    }

    func testRecentSourcePreservesFixedKeysWhenSwitchedBack() throws {
        var category = KeyboardPageCategory(name: "常用", columns: 2, keys: [key(width: 2), key("？")])
        let authored = category.keys
        category.source = .recent
        let data = try JSONEncoder().encode(category)
        var restored = try JSONDecoder().decode(KeyboardPageCategory.self, from: data)
        restored.source = .fixed
        XCTAssertEqual(restored.keys, authored)
        try restored.validate()
    }

    func testRecentSplitsDoNotDependOnFixedKeyBackup() throws {
        var recent = KeyboardPageCategory(
            name: "最近", columns: 4, keys: [],
            split: .init(rowBreaks: [1, 2, 3, 1, 2], gapFraction: 0.2), source: .recent)
        XCTAssertNoThrow(try page([recent]).validate())
        recent.keys = [key("。")]
        XCTAssertNoThrow(try page([recent]).validate())
        let saved = try JSONDecoder().decode(KeyboardPageDefinition.self, from: JSONEncoder().encode(page([recent])))
        XCTAssertEqual(saved.categories?[0].split?.rowBreaks, [1, 2, 3, 1, 2])
        XCTAssertEqual(saved.categories?[0].keys, recent.keys)
        recent.source = .fixed
        XCTAssertThrowsError(try page([recent]).validate())
        recent.source = .recent
        recent.split?.rowBreaks = [4]
        XCTAssertThrowsError(try page([recent]).validate())
        recent.split?.rowBreaks = Array(repeating: 1, count: LayoutResourceBudget.recentCategoryKeys / 4 + 1)
        XCTAssertThrowsError(try page([recent]).validate())
    }

    func testBrowserAndRowPagesDecodeWithoutCategories() throws {
        let browserJSON = """
            {"id":"old-browser","name":"分类符号","kind":"symbols","rows":[],"symbolPresentation":"categorized"}
            """
        let browser = try JSONDecoder().decode(KeyboardPageDefinition.self, from: Data(browserJSON.utf8))
        XCTAssertNil(browser.categories)
        try browser.validate()
        let row = KeyboardPagePresets.numericChinese
        let restored = try JSONDecoder().decode(KeyboardPageDefinition.self, from: JSONEncoder().encode(row))
        XCTAssertEqual(restored, row)
        try restored.validate()
    }

    func testCategoryValidationRejectsEmptyDuplicateAndInvalidContent() throws {
        XCTAssertThrowsError(try page([]).validate())
        let fixed = KeyboardPageCategory(id: "same", name: "常用", keys: [key()])
        XCTAssertThrowsError(try page([fixed, fixed]).validate())
        XCTAssertThrowsError(try page([.init(name: "空分类", keys: [])]).validate())
        XCTAssertNoThrow(try page([.init(name: "最近", keys: [], source: .recent)]).validate())
        for columns in [0, LayoutResourceBudget.categoryColumns + 1] {
            XCTAssertThrowsError(try page([.init(name: "列数", columns: columns, keys: [key()])]).validate())
        }
        for width in [0, -1, Double.infinity, Double.nan] {
            XCTAssertThrowsError(try page([.init(name: "宽度", keys: [key(width: width)])]).validate())
        }
        let engineKey = LayoutKey(label: "a", action: .init(.code, value: "a"))
        XCTAssertThrowsError(try page([.init(name: "输入", keys: [engineKey])]).validate())
        let engineAlternate = LayoutKey(
            label: "。", action: .init(.literal, value: "。"),
            longPress: [.init(label: "a", action: .init(.code, value: "a"))])
        XCTAssertThrowsError(try page([.init(name: "长按", keys: [engineAlternate])]).validate())
    }

    func testFullCategoriesUseTheirOwnBudgetAndRejectOverflow() throws {
        let full = KeyboardPageCategory(name: "主题", keys: Array(repeating: key(), count: 300))
        XCTAssertNoThrow(try page([full]).validate())
        XCTAssertNoThrow(try LayoutRegistry(pages: [page([full])]))
        let oversized = KeyboardPageCategory(
            name: "过多", keys: Array(repeating: key(), count: LayoutResourceBudget.categoryKeys + 1))
        XCTAssertThrowsError(try page([oversized]).validate())
        let crowded = (0..<3).map { index in
            KeyboardPageCategory(
                id: "full-\(index)", name: "主题",
                keys: Array(repeating: key(), count: LayoutResourceBudget.categoryKeys))
        }
        XCTAssertThrowsError(try page(crowded).validate())
        let tooManyCategories = (0...LayoutResourceBudget.pageCategories).map {
            KeyboardPageCategory(id: "category-\($0)", name: "主题", keys: [key()])
        }
        XCTAssertThrowsError(try page(tooManyCategories).validate())
        let longID = KeyboardPageCategory(id: String(repeating: "x", count: 257), name: "主题", keys: [key()])
        XCTAssertThrowsError(try page([longID]).validate())
    }
}
