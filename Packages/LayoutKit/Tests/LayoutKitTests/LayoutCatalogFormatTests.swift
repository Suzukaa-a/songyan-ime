import XCTest

@testable import LayoutKit

/// `layouts-before-pages.json` was written by `LayoutStore.save` of the release before pages,
/// pairings and splits existed: the four built-ins (stored merged14/merged18 included), an edited
/// 14-key copy and a layout bound to one input method, with a reordered enabled list.
final class LayoutCatalogFormatTests: XCTestCase {
    private let copyID = "0a8d7d3a-4d0f-4398-9151-412e0a584584"

    private func fixtureStore() throws -> LayoutStore {
        let fixture = try XCTUnwrap(
            Bundle.module.url(forResource: "layouts-before-pages", withExtension: "json", subdirectory: "Fixtures"))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("layout-format-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = LayoutStore(directoryURL: directory)
        try FileManager.default.copyItem(at: fixture, to: store.catalogURL)
        return store
    }

    func testCatalogWithoutPagesLoadsWithEveryLayoutAndTheBuiltInPages() throws {
        let registry = try fixtureStore().load()
        XCTAssertEqual(
            registry.layouts.map(\.id), ["qwerty26", "merged14", "merged18", "phone9", copyID, "luna-26"])
        XCTAssertEqual(registry.enabledIDs, ["merged18", copyID, "merged14", "qwerty26", "luna-26"])
        XCTAssertEqual(registry.pages, KeyboardPagePresets.all)
        XCTAssertTrue(registry.compositions.isEmpty)

        for id in ["merged14", "merged18"] {
            let stored = try XCTUnwrap(registry.layout(id: id))
            let preset = try XCTUnwrap(BuiltinLayouts.all.first { $0.id == id })
            XCTAssertEqual(stored.rows, preset.rows, "\(id) keeps its stored keys")
            XCTAssertEqual(stored.input, preset.input)
            XCTAssertTrue(BuiltinLayouts.matchesMainShell(stored, as: preset.input.builtinLayout!))
        }
        let copy = try XCTUnwrap(registry.layout(id: copyID))
        XCTAssertEqual(copy.name, "我的 14 键")
        XCTAssertEqual(copy.rows[0].keys[0].secondaryLabel, "1")
        let bound = try XCTUnwrap(registry.layout(id: "luna-26"))
        XCTAssertEqual(bound.input, LayoutInput(schemaID: "luna_pinyin", builtinLayout: .qwerty26))
        XCTAssertEqual(bound.longPressDelay, 0.5)
        XCTAssertEqual(bound.note, "只给朙月拼音用")
    }

    func testCatalogWithoutPagesAcceptsPairingsAndRoundTrips() throws {
        let store = try fixtureStore()
        var registry = try store.load()
        let key = KeyboardCompositionKey(inputMethodID: "luna_pinyin", layout: .merged14)
        // The first enabled layout of the keyboard's shape, as the keyboard itself picks.
        XCTAssertEqual(registry.defaultMainLayoutID(for: key), copyID)
        XCTAssertEqual(
            registry.defaultMainLayoutID(for: .init(inputMethodID: "luna_pinyin", layout: .qwerty26)), "qwerty26")
        try registry.setComposition(registry.composition(for: key), for: key.rawValue)
        try store.save(registry)
        XCTAssertEqual(try store.load(), registry)
    }
}
