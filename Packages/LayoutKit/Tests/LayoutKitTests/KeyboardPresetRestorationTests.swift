import Foundation
import LayoutKit
import XCTest

/// Restoring a built-in preset replaces exactly one entry by ID: the edited content becomes the
/// shipped content again, while pairings, enable state and user copies are untouched. The round
/// trip goes through `LayoutStore`, so the assertions describe what the next launch would read.
final class KeyboardPresetRestorationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("preset-restoration-" + UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Saving then reading back is what the next launch sees.
    private func reloaded(_ registry: LayoutRegistry) throws -> LayoutRegistry {
        let store = LayoutStore(directoryURL: directory)
        try store.save(registry)
        return try store.load()
    }

    /// An edited built-in main layout: same ID as the shipped one, different name and note.
    private func staleMainLayout() -> LayoutDefinition {
        let shipped = BuiltinLayouts.qwerty26
        return LayoutDefinition(
            id: shipped.id, name: "旧版 26 键", input: shipped.input, rows: shipped.rows,
            note: "旧版的说明")
    }

    /// An edited built-in page: same ID as the shipped one, different name.
    private func staleNumericPage() -> KeyboardPageDefinition {
        var page = KeyboardPagePresets.numericChinese
        page.name = "旧版中文 123"
        return page
    }

    func testRestoringAMainLayoutPresetKeepsPairingsEnableStateAndUserCopies() throws {
        var old = try LayoutRegistry()
        // The user's own copy of the same kind, renamed, edited, and enabled alongside the preset.
        let mine = try old.copy(BuiltinLayouts.qwerty26, name: "我的 26 键", enable: true)
        let mineEdited = LayoutDefinition(
            id: mine.id, name: mine.name, input: mine.input, rows: mine.rows, note: "我改过的说明")
        try old.replace(mineEdited)

        try old.replace(staleMainLayout())
        let pairing = KeyboardComposition(mainLayoutID: BuiltinLayouts.qwerty26.id)
        try old.setComposition(pairing, for: "some_pinyin:qwerty26")
        XCTAssertEqual(old.layout(id: BuiltinLayouts.qwerty26.id)?.name, "旧版 26 键")
        XCTAssertEqual(old.layout(id: BuiltinLayouts.qwerty26.id)?.note, "旧版的说明")
        let enabledBefore = old.enabledIDs
        let enabledLayoutsBefore = old.enabledLayouts.map(\.id)
        XCTAssertTrue(enabledBefore.contains(mine.id))

        // What the "restore preset" action does: replace that one ID with the shipped definition.
        try old.replace(BuiltinLayouts.qwerty26)
        let restored = try reloaded(old)

        XCTAssertEqual(restored.layout(id: BuiltinLayouts.qwerty26.id), BuiltinLayouts.qwerty26)
        XCTAssertEqual(restored.layout(id: BuiltinLayouts.qwerty26.id)?.note, BuiltinLayouts.qwerty26.note)
        XCTAssertEqual(restored.enabledIDs, enabledBefore)
        XCTAssertEqual(restored.enabledLayouts.map(\.id), enabledLayoutsBefore)
        XCTAssertEqual(restored.compositions["some_pinyin:qwerty26"], pairing)
        // The user's copy keeps its own content instead of becoming a second preset.
        XCTAssertEqual(restored.layout(id: mine.id)?.name, "我的 26 键")
        XCTAssertEqual(restored.layout(id: mine.id)?.note, "我改过的说明")
        XCTAssertNotEqual(restored.layout(id: mine.id), BuiltinLayouts.qwerty26)
    }

    func testRestoringAPagePresetKeepsPairingsEnableStateAndUserCopies() throws {
        var old = try LayoutRegistry()
        let myPage = KeyboardPagePresets.numericEnglish.copy(name: "我的数字页")
        try old.savePage(myPage)
        try old.savePage(staleNumericPage())

        let pairing = KeyboardComposition(
            mainLayoutID: BuiltinLayouts.merged14.id,
            numericPageID: KeyboardPagePresets.numericChinese.id)
        try old.setComposition(pairing, for: "some_pinyin:merged14")
        XCTAssertEqual(old.page(id: KeyboardPagePresets.numericChinese.id)?.name, "旧版中文 123")
        let enabledBefore = old.enabledIDs

        // Restore by ID, exactly as the page library's "restore preset" action does.
        try old.savePage(KeyboardPagePresets.numericChinese)
        let restored = try reloaded(old)

        XCTAssertEqual(restored.page(id: KeyboardPagePresets.numericChinese.id), KeyboardPagePresets.numericChinese)
        XCTAssertEqual(restored.enabledIDs, enabledBefore)
        XCTAssertEqual(restored.compositions["some_pinyin:merged14"], pairing)
        XCTAssertEqual(
            restored.compositions["some_pinyin:merged14"]?.numericPageID,
            KeyboardPagePresets.numericChinese.id)
        // The user's page keeps its own content instead of becoming a second preset.
        XCTAssertEqual(restored.page(id: myPage.id), myPage)
        XCTAssertNotEqual(restored.page(id: myPage.id), KeyboardPagePresets.numericEnglish)
    }
}
