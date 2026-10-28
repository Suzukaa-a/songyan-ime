import XCTest

@testable import LayoutKit

/// The authored function area: chrome data, the stable key path, materialized drafts and the
/// title-mode contract. No source strings or hashes: every assertion is real data behaviour.
final class KeyboardPageChromeTests: XCTestCase {
    // MARK: - Compatibility

    func testNativeControlsPageStaysReadableAndMaterializingDoesNotWriteIt() throws {
        let native = KeyboardPagePresets.englishQwerty
        let data = try JSONEncoder().encode(native)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["chrome"], "a page on native controls must not gain chrome on the wire")
        let decoded = try JSONDecoder().decode(KeyboardPageDefinition.self, from: data)
        XCTAssertEqual(decoded, native)
        XCTAssertNil(decoded.chrome)

        let materialized = decoded.materialized()
        XCTAssertNil(decoded.chrome, "materializing a value must not write into the stored page")
        XCTAssertNotNil(materialized.chrome)
        XCTAssertEqual(materialized.id, decoded.id)
        XCTAssertEqual(materialized.name, decoded.name)
    }

    func testTitleModeEncodesAndOldKeysDecodeAsNil() throws {
        let custom = LayoutKey(label: "确认", width: 2, action: .init(.enter), titleMode: .custom)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(custom)) as? [String: Any])
        XCTAssertEqual(object["titleMode"] as? String, "custom")
        XCTAssertEqual(try JSONDecoder().decode(LayoutKey.self, from: JSONEncoder().encode(custom)), custom)

        let plain = Data("{\"label\":\"q\",\"action\":{\"type\":\"literal\",\"value\":\"q\"}}".utf8)
        let decoded = try JSONDecoder().decode(LayoutKey.self, from: plain)
        XCTAssertNil(decoded.titleMode)
        XCTAssertNil(decoded.width)
    }

    func testFieldEditsPreserveTitleModeAndDeclaredContent() {
        let key = LayoutKey(
            label: "123", secondaryLabel: "数字", width: 2,
            action: .pageSwitch(.numeric),
            longPress: [LayoutOption(label: "符号", action: .pageSwitch(.symbols))],
            titleMode: .automatic)
        let renamed = key.title("我的数字")
        XCTAssertEqual(renamed.titleMode, .custom)
        XCTAssertEqual(renamed.action, key.action)
        XCTAssertEqual(renamed.longPress, key.longPress)
        XCTAssertEqual(renamed.secondaryLabel, "数字")
        XCTAssertEqual(key.settingWidth(3).titleMode, .automatic)
        XCTAssertEqual(key.settingSecondaryLabel(nil).secondaryLabel, nil)
        XCTAssertEqual(key.settingSecondaryLabel("数字").secondaryLabel, "数字")
        XCTAssertEqual(key.settingLongPress(nil).titleMode, .automatic)
        XCTAssertEqual(key.settingAction(.init(.space)).longPress, key.longPress)
    }

    // MARK: - Materialization defaults

    func testMaterializedABCCarriesShiftDeleteAndNativeFooter() throws {
        let page = KeyboardPagePresets.englishQwerty.materialized()
        XCTAssertEqual(page.rows.map { $0.keys.count }, [10, 9, 9])
        XCTAssertEqual(page.rows[0], KeyboardPagePresets.englishQwerty.rows[0])
        XCTAssertEqual(page.rows[1], KeyboardPagePresets.englishQwerty.rows[1])

        let last = page.rows[2].keys
        let shift = try XCTUnwrap(last.first)
        XCTAssertEqual(shift.action.type, .shift)
        XCTAssertEqual(shift.width, 1.5)
        XCTAssertEqual(shift.titleMode, .automatic)
        XCTAssertNil(shift.secondaryLabel, "a synthesized control must not invent a subtitle")
        let delete = try XCTUnwrap(last.last)
        XCTAssertEqual(delete.action.type, .backspace)
        XCTAssertEqual(delete.width, 1.5)
        XCTAssertEqual(delete.titleMode, .automatic)
        XCTAssertEqual(
            last.dropFirst().dropLast().map(\.label), Array("zxcvbnm").map(String.init))

        let bottom = try XCTUnwrap(page.chrome?.bottom)
        XCTAssertEqual(bottom.count, 6)
        XCTAssertEqual(bottom[0].action.type, .globe, "the default footer puts the low-frequency globe first")
        XCTAssertEqual(bottom[1].action.pageSwitchTarget, .numeric)
        XCTAssertEqual(bottom[2].action.type, .languageSwitch)
        XCTAssertEqual(bottom[3].action.type, .space)
        XCTAssertEqual(bottom[3].width, 4)
        // The comma sits where 符号 used to be; its long press holds the other sentence marks.
        XCTAssertEqual(bottom[4].action.type, .literal)
        XCTAssertEqual(bottom[4].action.value, "，")
        XCTAssertEqual(bottom[4].action.asciiValue, ",")
        XCTAssertEqual(bottom[4].label, ",")
        XCTAssertEqual(bottom[4].longPress?.map(\.label), [".", "?", "!", "'", "\""])
        XCTAssertEqual(bottom[4].longPress?.map(\.action.value), ["。", "？", "！", "、", "…"])
        XCTAssertEqual(bottom[5].action.type, .enter)
        XCTAssertTrue(bottom.allSatisfy { $0.titleMode == .automatic })
        XCTAssertTrue(page.chrome?.leading.isEmpty == true)
        XCTAssertTrue(page.chrome?.trailing.isEmpty == true)
        XCTAssertEqual(page.materialized(), page, "materialization is idempotent")
        try page.validate()
    }

    /// The frozen contract fixes the default footer weights: space is 4, every other default key 1.
    func testDefaultFunctionAreaKeepsContractWeights() throws {
        for page in [
            KeyboardPagePresets.englishQwerty, KeyboardPagePresets.numericChinese, KeyboardPagePresets.symbolsChinese,
        ] {
            let materialized = page.materialized()
            XCTAssertEqual(materialized.chrome?.bottom.map(\.widthWeight), [1, 1, 1, 4, 1, 1])
        }
        let categorized = KeyboardPagePresets.symbolsCategorized.materialized()
        XCTAssertEqual(categorized.chrome?.bottom.map(\.widthWeight), [1, 1, 1, 4, 1])
        XCTAssertEqual(categorized.chrome?.trailing.map(\.widthWeight), [1, 1, 2])
        let keypad = KeyboardPagePresets.numericAutomatic.materialized(numericForm: .phoneDigitPad)
        XCTAssertEqual(keypad.chrome?.leading.map(\.widthWeight), [1, 1, 1])
        XCTAssertEqual(keypad.chrome?.bottom.map(\.widthWeight), [1, 1, 1, 4, 1])
        XCTAssertEqual(keypad.chrome?.trailing.map(\.widthWeight), [1, 1, 2])
    }

    func testMaterializedNumericRowPageKeepsSwitchMarksAndDeleteOnTheThirdRow() throws {
        let chinese = KeyboardPagePresets.numericChinese.materialized()
        XCTAssertNil(chinese.numericPresentation)
        XCTAssertEqual(chinese.rows.map { $0.keys.count }, [10, 10, 9])
        let switchKey = try XCTUnwrap(chinese.rows[2].keys.first)
        XCTAssertEqual(switchKey.action.pageSwitchTarget, .symbols)
        XCTAssertEqual(switchKey.label, "符号")
        XCTAssertEqual(switchKey.width, 1.5)
        XCTAssertEqual(switchKey.titleMode, .automatic)
        let delete = try XCTUnwrap(chinese.rows[2].keys.last)
        XCTAssertEqual(delete.action.type, .backspace)
        XCTAssertEqual(delete.width, 1.5, "Delete is a side key as wide as on the ABC page")
        XCTAssertEqual(delete.titleMode, .automatic)
        XCTAssertEqual(chinese.defaultSymbolMarks, .chinese)
        // Frozen default footer: globe, 返回, 中英, space, comma, Return.
        let bottom = try XCTUnwrap(chinese.chrome?.bottom)
        XCTAssertEqual(bottom.count, 6)
        XCTAssertEqual(bottom.map(\.action.type), [.globe, .pageSwitch, .languageSwitch, .space, .literal, .enter])
        XCTAssertEqual(bottom[4].action.value, "，")
        XCTAssertEqual(bottom[1].label, "返回")
        XCTAssertEqual(bottom[1].action.pageSwitchTarget, .letters)
        XCTAssertEqual(bottom[1].titleMode, .automatic)
        XCTAssertNil(bottom[2].action.languageSwitchBehavior)
        // The marks are an explicit bilingual pair: Chinese value, ASCII counterpart, and the
        // stored label follows the initial branch.
        let paired = chinese.rows[1].keys[2]
        XCTAssertEqual(paired.action.value, "：")
        XCTAssertEqual(paired.action.asciiValue, ":")
        XCTAssertEqual(paired.label, "：")
        XCTAssertEqual(paired.titleMode, .automatic)
        XCTAssertEqual(chinese.rows[0].keys[0].action.asciiValue, nil, "identical digits need no pair")
        try chinese.validate()

        let automaticASCII = KeyboardPagePresets.numericAutomatic.materialized(numericMarks: .ascii)
        XCTAssertEqual(automaticASCII.rows.map { $0.keys.count }, [10, 10, 9])
        XCTAssertEqual(automaticASCII.defaultSymbolMarks, .ascii)
        XCTAssertEqual(automaticASCII.rows[1].keys[2].label, ":")
        XCTAssertEqual(automaticASCII.rows[1].keys[2].action.value, "：")
        XCTAssertEqual(automaticASCII.rows[1].keys[2].action.asciiValue, ":")
        XCTAssertEqual(automaticASCII.rows[2].keys.first?.action.pageSwitchTarget, .symbols)
        try automaticASCII.validate()

        let symbols = KeyboardPagePresets.symbolsChinese.materialized()
        let symbolSwitch = try XCTUnwrap(symbols.rows[2].keys.first)
        XCTAssertEqual(symbolSwitch.action.pageSwitchTarget, .numeric)
        XCTAssertEqual(symbolSwitch.label, "123")
        XCTAssertEqual(symbolSwitch.width, 1.5)
        XCTAssertEqual(symbolSwitch.titleMode, .automatic)
        XCTAssertEqual(symbols.rows[2].keys.last?.action.type, .backspace)
        XCTAssertEqual(symbols.chrome?.bottom.count, 6)
    }

    func testMaterializedAutomaticSymbolPageBecomesAuthoredRows() throws {
        let page = KeyboardPagePresets.symbolsSystem.materialized()
        XCTAssertEqual(page.symbolPresentation, .rows)
        XCTAssertEqual(page.rows.map { $0.keys.count }, [10, 10, 9])
        XCTAssertEqual(page.rows[2].keys.first?.action.pageSwitchTarget, .numeric)
        XCTAssertEqual(page.rows[2].keys.last?.action.type, .backspace)
        XCTAssertEqual(page.chrome?.bottom.count, 6)
        XCTAssertEqual(page.chrome?.bottom[1].action.pageSwitchTarget, .letters)
        try page.validate()
    }

    func testMaterializedCategoryPageMovesNavigationToTrailingRail() throws {
        let page = KeyboardPagePresets.symbolsCategorized.materialized()
        XCTAssertTrue(page.rows.isEmpty)
        XCTAssertEqual(page.symbolPresentation, .categorized)
        XCTAssertTrue(page.rows.isEmpty)
        let chrome = try XCTUnwrap(page.chrome)
        XCTAssertEqual(chrome.bottom.count, 5)
        XCTAssertEqual(chrome.bottom.map(\.action.type), [.globe, .languageSwitch, .pageSwitch, .space, .symbolLock])
        XCTAssertEqual(chrome.bottom[1].label, "返回")
        XCTAssertEqual(chrome.bottom[1].action.languageSwitchBehavior, .letters)
        XCTAssertEqual(chrome.bottom[2].action.pageSwitchTarget, .numeric)
        XCTAssertEqual(chrome.trailing.map(\.action.type), [.backspace, .clearInput, .enter])
        XCTAssertEqual(chrome.trailing.map(\.widthWeight), [1, 1, 2])
        XCTAssertTrue(chrome.trailingSpansBottom)
        XCTAssertTrue(chrome.leading.isEmpty)
        try page.validate()

        // A categorized page with authored rows keeps its browser rows; materializing only adds chrome.
        var rowsBrowser = KeyboardPagePresets.symbolsCategorized
        rowsBrowser.rows = KeyboardPagePresets.symbolsChinese.rows
        let kept = rowsBrowser.materialized()
        XCTAssertEqual(kept.rows, rowsBrowser.rows)
        XCTAssertEqual(kept.chrome?.trailing.count, 3)
        try kept.validate()
    }

    func testExplicitKeypadIsAuthoredDataForAnyMainLayout() throws {
        let keypad = KeyboardPagePresets.numericAutomatic.materialized(numericForm: .phoneDigitPad)
        XCTAssertEqual(keypad.numericPresentation, .keypad)
        XCTAssertTrue(keypad.isKeypad)
        XCTAssertFalse(keypad.resolvesAtRuntime)
        XCTAssertEqual(keypad.rows.count, 3)
        XCTAssertEqual(keypad.rows.flatMap(\.keys).map(\.label), ["1", "2", "3", "4", "5", "6", "7", "8", "9"])
        XCTAssertTrue(keypad.rows.flatMap(\.keys).allSatisfy { $0.action.type == .literal })
        XCTAssertEqual(keypad.chrome?.leading.count, 3)
        XCTAssertEqual(keypad.chrome?.bottom.last?.action.value, "0")
        XCTAssertEqual(keypad.chrome?.trailing.map(\.action.type), [.backspace, .clearInput, .enter])
        XCTAssertEqual(keypad.chrome?.trailing.map(\.widthWeight), [1, 1, 2])
        XCTAssertNil(keypad.chrome?.leadingWidth)
        XCTAssertNil(keypad.chrome?.trailingWidth)
        try keypad.validate()
        XCTAssertEqual(keypad.materialized(), keypad)

        let preset = KeyboardPagePresets.numericKeypad
        XCTAssertEqual(preset.numericPresentation, .keypad)
        XCTAssertEqual(preset.name, "数字九宫格")
        try preset.validate()
        XCTAssertTrue(KeyboardPagePresets.all.contains { $0.id == preset.id })
        XCTAssertEqual(KeyboardPagePresets.mergingInto([]).filter { $0.id == preset.id }.count, 1)

        // An explicit keypad pairs with any main layout, never only the phone shell.
        var registry = try LayoutRegistry(layouts: [BuiltinLayouts.qwerty26])
        try registry.setComposition(
            KeyboardComposition(mainLayoutID: BuiltinLayouts.qwerty26.id, numericPageID: preset.id),
            for: "quanpin:qwerty26")
        XCTAssertEqual(registry.compositions["quanpin:qwerty26"]?.numericPageID, preset.id)
    }

    func testKeypadStructureIsAuthorEditable() throws {
        var edited = KeyboardPagePresets.numericKeypad
        edited.rows = [LayoutRow(keys: [LayoutKey(label: "5", action: .init(.literal, value: "5"))])]
        edited.chrome?.leading = []
        try edited.validate()
        XCTAssertEqual(edited.numericPresentation, .keypad)
        XCTAssertTrue(edited.rows[0].keys.count == 1)
    }

    // MARK: - Split cut and shift insertion

    func testInsertingTheLeadingKeyMovesTheStoredCutByOneOnly() throws {
        let native = KeyboardPageDefinition(
            id: "cut.abc", name: "切开 ABC", kind: .english,
            rows: KeyboardPagePresets.englishQwerty.rows,
            split: LayoutSplitConfiguration(rowBreaks: [5, 4, 3]))
        let materialized = native.materialized()
        XCTAssertEqual(materialized.rows[2].keys.count, 9)
        XCTAssertEqual(materialized.split?.rowBreaks, [5, 4, 4], "the cut moved with the inserted Shift")
        let geometry = KeyboardPageRowGeometry(
            width: 834, page: materialized, row: 2, split: materialized.split?.resolved(forWidth: 834))
        XCTAssertEqual(geometry.splitIndex, 4, "the authored row index is the stored cut itself")
        XCTAssertEqual(geometry.keyWidths.count, geometry.keyIndices.count)
        XCTAssertEqual(geometry.keyIndices.count, 9)
        try materialized.validate()

        let nativeNumeric = KeyboardPageDefinition(
            id: "cut.num", name: "切开数字", kind: .numeric,
            rows: KeyboardPagePresets.numericChinese.rows,
            split: LayoutSplitConfiguration(rowBreaks: [5, 4, 3]))
        let numeric = nativeNumeric.materialized()
        XCTAssertEqual(numeric.split?.rowBreaks, [5, 4, 4], "the cut moved with the inserted page switch")
        XCTAssertEqual(numeric.rows[2].keys.count, 9)
        try numeric.validate()
    }

    func testDefaultCutOnTheMaterializedShiftRowIsTheFullRowMiddle() {
        let native = KeyboardPageDefinition(
            id: "default.cut", name: "默认切分 ABC", kind: .english,
            rows: KeyboardPagePresets.englishQwerty.rows,
            split: LayoutSplitConfiguration(rowBreaks: [5, 4]))
        let materialized = native.materialized()
        let geometry = KeyboardPageRowGeometry(
            width: 834, page: materialized, row: 2, split: materialized.split?.resolved(forWidth: 834))
        XCTAssertEqual(geometry.splitIndex, 5, "Shift + 4 letters before the cut")
    }

    // MARK: - Deletion, movement and fidelity

    func testDeletingFunctionKeysIsNotUndoneByMaterialization() throws {
        var edited = KeyboardPagePresets.englishQwerty.materialized()
        edited.chrome?.bottom.removeLast()
        edited.rows[2] = LayoutRow(keys: Array(edited.rows[2].keys.dropLast()))
        let again = edited.materialized()
        XCTAssertEqual(again, edited)
        XCTAssertEqual(again.chrome?.bottom.count, 5)
        XCTAssertFalse(again.rows[2].keys.contains { $0.action.type == .backspace })
        try again.validate()

        var emptied = KeyboardPagePresets.numericChinese.materialized()
        emptied.chrome?.bottom = []
        emptied.chrome?.leading = []
        emptied.chrome?.trailing = []
        XCTAssertEqual(emptied.materialized(), emptied)
        try emptied.validate()
    }

    func testKeysMoveAcrossRowsFooterAndRailsWithoutLoss() throws {
        var page = KeyboardPagePresets.englishQwerty.materialized()
        let enter = try XCTUnwrap(page.chrome?.bottom.last)
        var chrome = try XCTUnwrap(page.chrome)
        chrome.bottom.removeLast()
        chrome.trailing = [enter]
        page.chrome = chrome
        XCTAssertEqual(page.key(at: .chrome(.trailing, key: 0)), enter)
        XCTAssertNil(page.key(at: .chrome(.bottom, key: 5)))
        XCTAssertEqual(page.chromeKeys.count, 6)
        XCTAssertEqual(page.allKeys.count, page.rows.flatMap(\.keys).count + 6)

        let renamed = try XCTUnwrap(page.key(at: .row(0, key: 0))).title("我的 Q")
        page = page.replacingKey(at: .row(0, key: 0), with: renamed)
        XCTAssertEqual(page.key(at: .row(0, key: 0))?.titleMode, .custom)
        XCTAssertEqual(page.key(at: .row(0, key: 0))?.action.type, .literal)
        XCTAssertNil(page.key(at: .chrome(.bottom, key: 99)))
        XCTAssertEqual(page.replacingKey(at: .row(99, key: 0), with: renamed), page)
        XCTAssertEqual(page.materialized(), page)
        XCTAssertNil(page.materialized().key(at: .chrome(.bottom, key: 5)))
        try page.validate()
    }

    func testAllKeysIncludeCategoryContent() throws {
        let category = KeyboardPageCategory(
            id: "cate.1", name: "常用",
            keys: [LayoutKey(label: "⏎", action: .init(.enter))])
        var page = KeyboardPagePresets.symbolsCategorized
        page.categories = [category]
        let materialized = page.materialized()
        XCTAssertEqual(materialized.categories?.count, 1)
        XCTAssertEqual(materialized.allKeys.count, 1 + materialized.chromeKeys.count)
        XCTAssertTrue(materialized.allKeys.contains { $0.action.type == .enter })
        try materialized.validate()
    }

    func testFunctionKeyContentSurvivesMaterialization() throws {
        var page = KeyboardPagePresets.numericChinese.materialized()
        var bottom = try XCTUnwrap(page.chrome?.bottom)
        let option = LayoutOption(label: "小键盘", action: .pageSwitch(.symbols))
        bottom[0] = bottom[0].settingLongPress([option])
        bottom[1] = bottom[1].title("翻页")
        page.chrome?.bottom = bottom
        let materialized = page.materialized()
        XCTAssertEqual(materialized.chrome?.bottom[0].longPress, [option])
        XCTAssertEqual(materialized.chrome?.bottom[1].titleMode, .custom)
        XCTAssertEqual(materialized.chrome?.bottom[1].label, "翻页")
        try materialized.validate()
    }

    func testCopyMaterializesAndAssignsANewIdentity() throws {
        let original = KeyboardPagePresets.numericAutomatic
        let copy = original.copy(name: "我的数字盘", numericForm: .phoneDigitPad)
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(copy.name, "我的数字盘")
        XCTAssertEqual(copy.numericPresentation, .keypad)
        XCTAssertNotNil(copy.chrome)
        XCTAssertEqual(copy.materialized(), copy)
        XCTAssertNil(original.chrome, "copying must not mutate the stored preset")
        try copy.validate()

        let authored = KeyboardPagePresets.englishQwerty.materialized()
        let authoredCopy = authored.copy()
        XCTAssertNotEqual(authoredCopy.id, authored.id)
        XCTAssertEqual(authoredCopy.chrome, authored.chrome)
        XCTAssertEqual(authoredCopy.rows, authored.rows)
    }

    // MARK: - Validation

    func testAuthoredFunctionAreaRejectsDataTheRuntimeCannotHonour() {
        func rejection(_ page: KeyboardPageDefinition, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertThrowsError(try page.validate(), file: file, line: line)
        }

        var categorized = KeyboardPagePresets.symbolsCategorized
        categorized.chrome = KeyboardPageChrome(
            leading: [LayoutKey(label: "x", action: .init(.literal, value: "x"))])
        rejection(categorized)

        var page = KeyboardPagePresets.numericChinese.materialized()
        page.chrome?.leadingWidth = 0
        rejection(page)
        page.chrome?.leadingWidth = .infinity
        rejection(page)
        page.chrome?.leadingWidth = .nan
        rejection(page)
        page.chrome?.leadingWidth = nil
        page.chrome?.trailing = Array(
            repeating: LayoutKey(label: "x", action: .init(.literal, value: "x")),
            count: LayoutResourceBudget.keysPerRegion + 1)
        rejection(page)

        var invalidSwitch = KeyboardPagePresets.numericChinese.materialized()
        invalidSwitch.chrome?.bottom[1] = LayoutKey(
            label: "123", action: .init(.pageSwitch, value: "somewhere"))
        rejection(invalidSwitch)
        var valuedKind = KeyboardPagePresets.numericChinese.materialized()
        valuedKind.chrome?.bottom[1] = LayoutKey(label: "⇧", action: .init(.shift, value: "x"))
        rejection(valuedKind)

        XCTAssertThrowsError(
            try KeyboardPageDefinition(
                id: "keypad.no.chrome", name: "无数据数字盘", kind: .numeric,
                rows: KeyboardPagePresets.numericKeypad.rows, numericPresentation: .keypad
            ).validate())

        var automatic = KeyboardPagePresets.numericAutomatic
        automatic.chrome = KeyboardPageChrome(bottom: [])
        rejection(automatic)
    }

    func testAuthoredEmptyStructureIsDeliberate() throws {
        let empty = KeyboardPageDefinition(
            id: "empty.page", name: "空白页", kind: .english, rows: [],
            chrome: KeyboardPageChrome())
        try empty.validate()
        XCTAssertEqual(empty.materialized(), empty)
        XCTAssertTrue(empty.allKeys.isEmpty)
    }

    /// The letter page types punctuation only when its 123 page can reach the symbol page itself.
    func testNumericPageReachesSymbolsFollowsThePageThePairingDraws() {
        // The built-in (nil) and automatic pages carry the row switch unless the layout is a phone keypad.
        for page in [nil, KeyboardPagePresets.numericAutomatic] {
            XCTAssertTrue(KeyboardPageResolver.numericPageReachesSymbols(page: page, mainLayoutIsPhoneKeypad: false))
            XCTAssertFalse(KeyboardPageResolver.numericPageReachesSymbols(page: page, mainLayoutIsPhoneKeypad: true))
        }
        // Native-control rows (no chrome) always draw the switch.
        XCTAssertTrue(
            KeyboardPageResolver.numericPageReachesSymbols(
                page: KeyboardPagePresets.numericChinese, mainLayoutIsPhoneKeypad: true))
        // An authored page reaches symbols only through its own symbol switch.
        let keypad = KeyboardPagePresets.numericKeypad.materialized()
        XCTAssertFalse(KeyboardPageResolver.numericPageReachesSymbols(page: keypad, mainLayoutIsPhoneKeypad: false))
        var withSwitch = keypad
        withSwitch.chrome?.bottom.append(LayoutKey(label: "符号", action: .pageSwitch(.symbols)))
        XCTAssertTrue(KeyboardPageResolver.numericPageReachesSymbols(page: withSwitch, mainLayoutIsPhoneKeypad: false))
    }
}
