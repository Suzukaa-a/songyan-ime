import XCTest

@testable import LayoutKit

/// Explicit Chinese/ASCII literal pairs, page-following language behavior, and the frozen default
/// footers: the tests pin the author-visible contract so copying, saving and reuse keep resolving
/// the same visible text.
final class BilingualLiteralTests: XCTestCase {
    // MARK: - Explicit behavior payload

    func testLanguageBehaviorPayloadRoundTripsAndRejectsUnknownValues() throws {
        XCTAssertEqual(LayoutAction.LanguageSwitchBehavior.symbols.rawValue, "symbols")
        XCTAssertEqual(LayoutAction.LanguageSwitchBehavior.letters.rawValue, "letters")
        let followPage = LayoutAction.languageSwitch()
        XCTAssertNil(followPage.value)
        XCTAssertNil(followPage.languageSwitchBehavior)
        XCTAssertNoThrow(try followPage.validate())
        for behavior in LayoutAction.LanguageSwitchBehavior.allCases {
            let action = LayoutAction.languageSwitch(behavior)
            XCTAssertEqual(action.value, behavior.rawValue)
            XCTAssertEqual(action.languageSwitchBehavior, behavior)
            XCTAssertNoThrow(try action.validate())
            XCTAssertEqual(
                try JSONDecoder().decode(LayoutAction.self, from: JSONEncoder().encode(action)), action)
        }
        let unknown = LayoutAction(.languageSwitch, value: "toggleEverything")
        XCTAssertNil(unknown.languageSwitchBehavior)
        XCTAssertThrowsError(try unknown.validate())
        let invalidJSON = Data(
            "{\"id\":\"bad\",\"name\":\"坏\",\"input\":{\"builtinLayout\":\"qwerty26\"},\"rows\":[{\"keys\":[{\"label\":\"中英\",\"action\":{\"type\":\"languageSwitch\",\"value\":\"toggleEverything\"}}]}]}"
                .utf8)
        XCTAssertThrowsError(try LayoutDefinition.decode(invalidJSON))
    }

    func testPolicyPageFollowingMatrixAndExplicitOverrides() {
        func policy(_ page: KeyboardControlPolicy.Page, ascii: Bool = false, category: Bool = true)
            -> KeyboardControlPolicy
        {
            KeyboardControlPolicy(
                page: page, isEnglishMode: false, hasGlobe: true, isPhoneLayout: false,
                usesASCIIPunctuation: ascii, usesCategorySymbolPage: category)
        }
        XCTAssertEqual(policy(.letters).languageAction, .toggleLanguage)
        XCTAssertEqual(policy(.numeric).languageAction, .toggleSymbols)
        XCTAssertEqual(policy(.symbols, category: false).languageAction, .toggleSymbols)
        XCTAssertEqual(policy(.symbols, category: true).languageAction, .returnToLetters)
        for page in KeyboardControlPolicy.Page.allCases {
            XCTAssertEqual(policy(page).languageAction(for: .symbols), .toggleSymbols, "\(page)")
            XCTAssertEqual(policy(page).languageAction(for: .letters), .returnToLetters, "\(page)")
        }
        // Target-language auto faces.
        XCTAssertEqual(policy(.letters).languageTitle, "英文")
        XCTAssertEqual(policy(.letters, ascii: true).languageTitle, "英文")
        XCTAssertEqual(policy(.numeric).languageTitle, "英文")
        XCTAssertEqual(policy(.numeric, ascii: true).languageTitle, "中文")
        XCTAssertEqual(policy(.symbols, category: true).languageTitle, "返回")
        XCTAssertEqual(policy(.numeric).languageTitle(for: .letters), "返回")
        XCTAssertEqual(policy(.symbols, category: true).languageAction(for: .symbols), .toggleSymbols)
        XCTAssertEqual(policy(.letters).languageAccessibilityLabel, "切换到英文")
        XCTAssertEqual(policy(.numeric, ascii: true).languageAccessibilityLabel, "切换到中文符号")
        XCTAssertEqual(policy(.symbols, category: true).languageAccessibilityLabel, "返回主键盘")
    }

    // MARK: - asciiValue legality, resolution and budget

    func testAsciiValueIsLiteralOnlyNonEmptyAndResolvesWithoutTouchingMetadata() throws {
        let fixed = LayoutAction(.literal, value: "。")
        XCTAssertNil(fixed.asciiValue)
        XCTAssertEqual(fixed.literalValue(usesASCIIPunctuation: false), "。")
        XCTAssertEqual(fixed.literalValue(usesASCIIPunctuation: true), "。")

        let pair = LayoutAction(.literal, value: "。", asciiValue: ".")
        XCTAssertEqual(pair.literalValue(usesASCIIPunctuation: false), "。")
        XCTAssertEqual(pair.literalValue(usesASCIIPunctuation: true), ".")
        XCTAssertEqual(pair.settingAsciiValue(nil).literalValue(usesASCIIPunctuation: true), "。")
        XCTAssertThrowsError(try LayoutAction(.literal, value: "x", asciiValue: "").validate())
        XCTAssertThrowsError(try LayoutAction(.space, asciiValue: "x").validate())
        XCTAssertNil(LayoutAction(.space).literalValue(usesASCIIPunctuation: true))

        // Editing only the value/face keeps pair data untouched through every setter.
        let key = LayoutKey(label: "。", action: pair, titleMode: .automatic)
        XCTAssertEqual(key.title("新").action.asciiValue, ".")
        XCTAssertEqual(key.settingWidth(2).action.asciiValue, ".")
        XCTAssertEqual(key.settingSecondaryLabel("提示").action.asciiValue, ".")
        XCTAssertEqual(key.settingLongPress([]).action.asciiValue, ".")
        XCTAssertEqual(key.settingAction(key.action.settingAsciiValue(".")).action.asciiValue, ".")
    }

    func testAsciiValueCountsInTheExistingTextBudget() throws {
        let definition = LayoutDefinition(
            id: "pair.budget", name: "双语预算", input: .init(builtinLayout: .qwerty26),
            rows: [
                LayoutRow(keys: [
                    LayoutKey(
                        label: "q",
                        action: .init(.literal, value: "q", asciiValue: String(repeating: "x", count: 4097)))
                ])
            ])
        XCTAssertThrowsError(try definition.validate())
    }

    // MARK: - Presets carry the two explicit branches

    private func resolve(_ key: LayoutKey, ascii: Bool) -> String? {
        key.action.literalValue(usesASCIIPunctuation: ascii)
    }

    func testPresetsStoreChineseValueAsciiCounterpartAndInitialBranch() throws {
        let chinese = KeyboardPagePresets.numericChinese
        XCTAssertEqual(chinese.defaultSymbolMarks, .chinese)
        let chinesePaired = chinese.rows[1].keys[2]
        XCTAssertEqual(chinesePaired.action.value, "：")
        XCTAssertEqual(chinesePaired.action.asciiValue, ":")
        XCTAssertEqual(chinesePaired.label, "：")
        XCTAssertEqual(chinesePaired.titleMode, .automatic)
        XCTAssertEqual(resolve(chinesePaired, ascii: false), "：")
        XCTAssertEqual(resolve(chinesePaired, ascii: true), ":")

        let english = KeyboardPagePresets.numericEnglish
        XCTAssertEqual(english.defaultSymbolMarks, .ascii)
        let englishPaired = english.rows[1].keys[2]
        XCTAssertEqual(englishPaired.action.value, "：")
        XCTAssertEqual(englishPaired.action.asciiValue, ":")
        XCTAssertEqual(englishPaired.label, ":")
        XCTAssertEqual(resolve(englishPaired, ascii: false), "：")
        XCTAssertEqual(resolve(englishPaired, ascii: true), ":")

        XCTAssertEqual(KeyboardPagePresets.symbolsChinese.defaultSymbolMarks, .chinese)
        XCTAssertEqual(KeyboardPagePresets.symbolsEnglish.defaultSymbolMarks, .ascii)
        XCTAssertNil(KeyboardPagePresets.numericAutomatic.defaultSymbolMarks)
        XCTAssertNil(KeyboardPagePresets.symbolsSystem.defaultSymbolMarks)
        XCTAssertEqual(KeyboardPagePresets.numericKeypad.defaultSymbolMarks, .chinese)

        // Every paired literal resolves to its own branch; identical slots stay fixed.
        for preset in [KeyboardPagePresets.numericChinese, KeyboardPagePresets.symbolsChinese] {
            try preset.validate()
            for key in preset.rows.flatMap(\.keys) {
                XCTAssertNotNil(resolve(key, ascii: false))
                if let ascii = key.action.asciiValue {
                    XCTAssertEqual(resolve(key, ascii: true), ascii)
                } else {
                    XCTAssertEqual(resolve(key, ascii: true), key.action.value)
                }
            }
        }
        // The presets round-trip through the wire form unchanged (pageOrder omission relies on it).
        for preset in KeyboardPagePresets.all {
            XCTAssertEqual(
                try JSONDecoder().decode(
                    KeyboardPageDefinition.self, from: JSONEncoder().encode(preset)), preset)
        }
    }

    func testCopiedPresetsKeepOrChooseTheirInitialSymbolBranch() throws {
        let englishPresetCopy = KeyboardPagePresets.numericEnglish.copy()
        XCTAssertEqual(englishPresetCopy.defaultSymbolMarks, .ascii)
        XCTAssertEqual(englishPresetCopy.rows[1].keys[2].label, ":")

        let automaticASCIICopy = KeyboardPagePresets.numericAutomatic.copy(numericMarks: .ascii)
        XCTAssertEqual(automaticASCIICopy.defaultSymbolMarks, .ascii)
        XCTAssertEqual(automaticASCIICopy.rows[1].keys[2].label, ":")

        let automaticChineseCopy = KeyboardPagePresets.numericAutomatic.copy(numericMarks: .chinese)
        XCTAssertEqual(automaticChineseCopy.defaultSymbolMarks, .chinese)
        XCTAssertEqual(automaticChineseCopy.rows[1].keys[2].label, "：")

        // A legacy authored page without an initial branch is never guessed one.
        let legacy = KeyboardPageDefinition(
            id: "legacy.rows", name: "旧行页", kind: .numeric,
            rows: [LayoutRow(keys: [LayoutKey(label: "1", action: .init(.literal, value: "1"))])])
        XCTAssertNil(legacy.defaultSymbolMarks)
        XCTAssertNil(legacy.materialized().defaultSymbolMarks)
        XCTAssertNil(legacy.copy().defaultSymbolMarks)
    }

    func testAutomaticSymbolCopySnapshotsTheChosenInitialLanguage() throws {
        let ascii = KeyboardPagePresets.symbolsSystem.copy(numericMarks: .ascii)
        XCTAssertEqual(ascii.symbolPresentation, .rows)
        XCTAssertEqual(ascii.defaultSymbolMarks, .ascii)
        XCTAssertEqual(ascii.rows[0], KeyboardPagePresets.symbolsEnglish.rows[0])
        XCTAssertEqual(ascii.rows[1], KeyboardPagePresets.symbolsEnglish.rows[1])
        XCTAssertEqual(Array(ascii.rows[2].keys.dropLast()), KeyboardPagePresets.symbolsEnglish.rows[2].keys)
        XCTAssertEqual(ascii.rows[0].keys[0].label, KeyboardPagePresets.symbolsEnglish.rows[0].keys[0].label)
        XCTAssertEqual(
            ascii.rows[0].keys[0].longPress, KeyboardPagePresets.symbolsEnglish.rows[0].keys[0].longPress,
            "the long-press menu is the chosen initial language's fixed snapshot")
        try ascii.validate()

        let chinese = KeyboardPagePresets.symbolsSystem.copy(numericMarks: .chinese)
        XCTAssertEqual(chinese.rows[0], KeyboardPagePresets.symbolsChinese.rows[0])
        XCTAssertEqual(chinese.rows[0].keys[0].label, KeyboardPagePresets.symbolsChinese.rows[0].keys[0].label)
        XCTAssertEqual(chinese.defaultSymbolMarks, .chinese)
        try chinese.validate()

        // Author-modified automatic rows are never swapped for a whole preset.
        var modified = KeyboardPagePresets.symbolsSystem
        var firstRow = modified.rows[0].keys
        firstRow[0] = LayoutKey(label: "自定", action: .init(.literal, value: "自定"))
        modified.rows[0] = LayoutRow(keys: firstRow)
        let modifiedCopy = modified.materialized(numericMarks: .ascii)
        XCTAssertEqual(modifiedCopy.rows[0].keys[0].label, "自定")
        XCTAssertEqual(modifiedCopy.rows[0].keys[0].action.value, "自定")
        XCTAssertNil(modifiedCopy.rows[0].keys[0].action.asciiValue)
        XCTAssertEqual(modifiedCopy.defaultSymbolMarks, .ascii)
    }

    // MARK: - Fixed author literals

    func testFixedAuthorLiteralNeverGainsAPairOrChangesOnCopy() throws {
        let fixed = LayoutKey(label: "自定", action: .init(.literal, value: "固定"), titleMode: .custom)
        let page = KeyboardPageDefinition(
            id: "author.fixed", name: "作者固定", kind: .numeric,
            rows: [LayoutRow(keys: [fixed])],
            chrome: KeyboardPageChrome(bottom: [fixed]))
        XCTAssertEqual(page.materialized(), page)
        try page.validate()
        let copy = page.copy()
        XCTAssertEqual(copy.rows[0].keys[0], fixed)
        XCTAssertEqual(copy.chrome?.bottom[0], fixed)
        XCTAssertNil(copy.rows[0].keys[0].action.asciiValue)
        XCTAssertEqual(copy.rows[0].keys[0].action.literalValue(usesASCIIPunctuation: true), "固定")

        // Materialising a legacy row page only appends the controls the renderer used to synthesize;
        // it never rewrites an author literal.
        let legacy = KeyboardPageDefinition(
            id: "author.legacy", name: "作者旧页", kind: .numeric,
            rows: [LayoutRow(keys: [fixed, LayoutKey(label: "2", action: .init(.literal, value: "2"))])])
        let materialised = legacy.materialized()
        XCTAssertEqual(Array(materialised.rows[0].keys.prefix(2)), legacy.rows[0].keys)
        XCTAssertEqual(materialised.rows[0].keys.count, 3)  // Delete appended
        XCTAssertNil(materialised.rows[0].keys[0].action.asciiValue)
        try materialised.validate()
    }

    // MARK: - Frozen default footers and policy mapping

    private func footer(_ page: KeyboardPageDefinition) -> [LayoutKey] {
        page.materialized().chrome?.bottom ?? []
    }

    func testDefaultFootersMatchTheFrozenOrderAndActions() throws {
        let abc = footer(KeyboardPagePresets.englishQwerty)
        XCTAssertEqual(
            abc.map(\.action.type), [.globe, .pageSwitch, .languageSwitch, .space, .pageSwitch, .enter])
        XCTAssertEqual(abc[1].action.pageSwitchTarget, .numeric)
        XCTAssertEqual(abc[4].action.pageSwitchTarget, .symbols)
        XCTAssertEqual(abc[4].label, "符号")

        let numeric = footer(KeyboardPagePresets.numericChinese)
        XCTAssertEqual(
            numeric.map(\.action.type), [.globe, .pageSwitch, .languageSwitch, .space, .pageSwitch, .enter])
        XCTAssertEqual(numeric[1].label, "返回")
        XCTAssertEqual(numeric[1].action.pageSwitchTarget, .letters)
        XCTAssertEqual(numeric[4].action.pageSwitchTarget, .symbols)

        let symbols = footer(KeyboardPagePresets.symbolsChinese)
        XCTAssertEqual(
            symbols.map(\.action.type), [.globe, .pageSwitch, .languageSwitch, .space, .pageSwitch, .enter])
        XCTAssertEqual(symbols[4].action.pageSwitchTarget, .numeric)

        let categorized = try XCTUnwrap(KeyboardPagePresets.symbolsCategorized.materialized().chrome?.bottom)
        XCTAssertEqual(categorized.map(\.action.type), [.globe, .languageSwitch, .pageSwitch, .space, .symbolLock])
        XCTAssertEqual(categorized[1].label, "返回")
        XCTAssertEqual(categorized[1].action.languageSwitchBehavior, .letters)
        XCTAssertEqual(categorized[2].action.pageSwitchTarget, .numeric)

        let keypad = try XCTUnwrap(KeyboardPagePresets.numericKeypad.chrome)
        XCTAssertEqual(keypad.bottom.map(\.action.type), [.globe, .pageSwitch, .languageSwitch, .space, .literal])
        XCTAssertEqual(keypad.bottom[1].action.pageSwitchTarget, .letters)
        XCTAssertEqual(keypad.bottom[4].action.value, "0")
        XCTAssertEqual(keypad.trailing.map(\.action.type), [.backspace, .clearInput, .enter])

        // Space is the only relative width in a default footer; function keys draw automatic faces,
        // while the fixed digit 0 keeps the plain literal face.
        for keys in [abc, numeric, symbols, categorized, keypad.bottom] {
            for key in keys {
                XCTAssertEqual(key.width, key.action.type == .space ? 4 : nil)
                XCTAssertEqual(key.titleMode, key.action.type == .literal ? nil : .automatic)
            }
        }
    }

    func testKeypadRailUsesTheRealNumericRailFirstThreeWithPairs() throws {
        let railChinese = BuiltinLayouts.phoneNumericRailValues(ascii: false)
        let railASCII = BuiltinLayouts.phoneNumericRailValues(ascii: true)
        XCTAssertEqual(Array(railChinese.prefix(3)), [".", "？", "！"])
        XCTAssertEqual(Array(railASCII.prefix(3)), [".", "?", "!"])
        XCTAssertEqual(Set(railChinese).count, railChinese.count, "the rail de-duplicates by string")
        XCTAssertEqual(Set(railASCII).count, railASCII.count)
        XCTAssertTrue(railChinese.contains("。"))
        XCTAssertTrue(railASCII.contains("-"))

        let chineseKeypad = try XCTUnwrap(KeyboardPagePresets.numericKeypad.chrome)
        XCTAssertEqual(chineseKeypad.leading.map(\.label), [".", "？", "！"])
        XCTAssertEqual(chineseKeypad.leading[1].action.value, "？")
        XCTAssertEqual(chineseKeypad.leading[1].action.asciiValue, "?")
        XCTAssertEqual(chineseKeypad.leading[0].action.asciiValue, nil)

        let asciiCopy = KeyboardPagePresets.numericAutomatic.copy(
            numericMarks: .ascii, numericForm: .phoneDigitPad)
        let asciiLeading = try XCTUnwrap(asciiCopy.chrome?.leading)
        XCTAssertEqual(asciiLeading.map(\.label), [".", "?", "!"])
        XCTAssertEqual(asciiLeading[2].action.value, "！")
        XCTAssertEqual(asciiLeading[2].action.asciiValue, "!")
        XCTAssertEqual(
            Array(BuiltinLayouts.phoneNumericRailValues(ascii: true).prefix(3)),
            asciiLeading.map { $0.action.asciiValue ?? $0.action.value ?? "" })
        try asciiCopy.validate()
    }

    func testDefaultFooterGeometryStillRecognisesEveryNewDefault() {
        let variants: [(KeyboardPageDefinition, KeyboardControlPolicy)] = [
            (
                KeyboardPagePresets.englishQwerty,
                KeyboardControlPolicy(
                    page: .letters, isEnglishMode: false, hasGlobe: true,
                    isPhoneLayout: false, usesASCIIPunctuation: false)
            ),
            (
                KeyboardPagePresets.numericChinese,
                KeyboardControlPolicy(
                    page: .numeric, isEnglishMode: false, hasGlobe: true,
                    isPhoneLayout: false, usesASCIIPunctuation: false)
            ),
            (
                KeyboardPagePresets.symbolsChinese,
                KeyboardControlPolicy(
                    page: .symbols, isEnglishMode: false, hasGlobe: true,
                    isPhoneLayout: false, usesASCIIPunctuation: false, usesCategorySymbolPage: false)
            ),
            (
                KeyboardPagePresets.symbolsCategorized,
                KeyboardControlPolicy(
                    page: .symbols, isEnglishMode: false, hasGlobe: true,
                    isPhoneLayout: true, usesASCIIPunctuation: false, includesBottomEnter: false)
            ),
            (
                KeyboardPagePresets.numericKeypad,
                KeyboardControlPolicy(
                    page: .numeric, isEnglishMode: false, hasGlobe: true,
                    isPhoneLayout: true, usesASCIIPunctuation: false, includesBottomEnter: false)
            ),
        ]
        for (page, policy) in variants {
            let geometry = KeyboardPageFooterGeometry(width: 402, keys: footer(page), policy: policy)
            XCTAssertTrue(geometry.usesControlRowBudget, page.name)
        }
    }

    // MARK: - Legacy wire decoder

    func testLegacyJSONWithoutNewFieldsStaysReadableAndFixed() throws {
        let json = Data(
            """
            {"id":"old.pair","name":"旧页","kind":"numeric","rows":[{"keys":[{"label":"。","action":{"type":"literal","value":"。"}}]}]}
            """.utf8)
        let page = try JSONDecoder().decode(KeyboardPageDefinition.self, from: json)
        XCTAssertNil(page.defaultSymbolMarks)
        XCTAssertNil(page.rows[0].keys[0].action.asciiValue)
        XCTAssertEqual(page.rows[0].keys[0].action.literalValue(usesASCIIPunctuation: true), "。")
        try page.validate()
        XCTAssertEqual(page.materialized().rows[0].keys[0], page.rows[0].keys[0])
    }
}
