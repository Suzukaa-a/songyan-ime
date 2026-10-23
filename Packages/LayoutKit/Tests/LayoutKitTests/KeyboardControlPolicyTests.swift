import XCTest

@testable import LayoutKit

final class KeyboardControlPolicyTests: XCTestCase {
    func testT9LeadingShortcutsAreComplementaryLiteralsAndASCIIAdapts() {
        let chinese = BuiltinLayouts.t9LeadingShortcuts(ascii: false)
        XCTAssertEqual(chinese.map(\.action.value), ["@", "/", "-", "(", ")", "…"])
        XCTAssertTrue(Set(chinese.map(\.label)).isDisjoint(with: ["，", "。", "？"]))
        for ascii in [false, true] {
            let keys = BuiltinLayouts.t9LeadingShortcuts(ascii: ascii)
            XCTAssertEqual(keys.count, 6)
            let actions = keys.map(\.action) + keys.flatMap { ($0.longPress ?? []).map(\.action) }
            XCTAssertTrue(actions.allSatisfy { $0.type == .literal })
            if ascii {
                XCTAssertTrue(actions.allSatisfy { ($0.value ?? "").utf8.allSatisfy { $0 < 128 } })
            }
        }
        // Presentation shortcuts do not mutate the persisted builtin.
        XCTAssertFalse((BuiltinLayouts.phone9.auxiliaryAreas ?? []).contains { $0.role == .punctuation })
    }
    func testPageLanguageMatrixKeepsAllSlotWidthsAndReturnLanguage() {
        for globe in [false, true] {
            for width in [312.0, 367, 382, 422, 804] {
                let reference = KeyboardControlPolicy(
                    page: .letters, isEnglishMode: false,
                    hasGlobe: globe, isPhoneLayout: true, usesASCIIPunctuation: false)
                for phone in [false, true] {
                    for english in [false, true] {
                        for page in KeyboardControlPolicy.Page.allCases {
                            let policy = KeyboardControlPolicy(
                                page: page, isEnglishMode: english,
                                hasGlobe: globe, isPhoneLayout: phone, usesASCIIPunctuation: false)
                            XCTAssertEqual(policy.slots, reference.slots)
                            let metrics = policy.metrics(width: width)
                            XCTAssertEqual(metrics, reference.metrics(width: width))
                            XCTAssertEqual(
                                policy.slots.reduce(0) { $0 + metrics[$1] }
                                    + Double(policy.slots.count - 1) * metrics.spacing, width, accuracy: 0.0001)
                            XCTAssertGreaterThanOrEqual(metrics.page, 50)
                            XCTAssertGreaterThanOrEqual(metrics.language, 50)
                            XCTAssertGreaterThanOrEqual(metrics.space, 44)
                            XCTAssertGreaterThanOrEqual(metrics.enter, 60)
                            if page != .letters {
                                XCTAssertEqual(policy.languageAction, .returnToLetters)
                                XCTAssertEqual(policy.languageTitle, english ? "ABC" : "中文")
                                XCTAssertEqual(policy.pageTarget, page == .numeric ? .symbols : .numeric)
                            } else {
                                XCTAssertEqual(policy.languageAction, .toggleLanguage)
                                XCTAssertEqual(policy.languageTitle, english ? "中文" : "ABC")
                            }
                            if english, !(phone && page == .numeric) {
                                XCTAssertEqual(policy.utility, .punctuation(phone ? "." : ","))
                            }
                        }
                    }
                }
            }
        }
    }

    /// Digit/symbol pages: the Chinese/ABC return key takes the leftmost slot (where 123 was on entry) and the page key moves to second;
    /// the letter page keeps [123][CN/EN]. Slot widths stay position-based.
    func testNonLetterPagesLeadWithReturnKey() {
        for page in KeyboardControlPolicy.Page.allCases {
            let policy = KeyboardControlPolicy(
                page: page, isEnglishMode: false,
                hasGlobe: true, isPhoneLayout: false, usesASCIIPunctuation: false)
            let keys = policy.slots.map(policy.key(at:))
            XCTAssertEqual(Array(keys.prefix(2)), page == .letters ? [.page, .language] : [.language, .page])
            XCTAssertEqual(Set(keys), Set(policy.slots))
        }
    }

    /// 26/14/18 keep the system row: symbols go through 123 -> #+=, and the utility slot stays a punctuation key.
    func testGenericControlRowHasNoDedicatedSymbolKey() {
        for phone in [false, true] {
            for english in [false, true] {
                for page in KeyboardControlPolicy.Page.allCases {
                    let policy = KeyboardControlPolicy(
                        page: page, isEnglishMode: english,
                        hasGlobe: true, isPhoneLayout: phone, usesASCIIPunctuation: false)
                    XCTAssertEqual(
                        policy.utility,
                        phone && page == .numeric
                            ? .digit("0")
                            : .punctuation(phone ? (english ? "." : "。") : (english ? "," : "，")),
                        "bottom-row utility is a direct punctuation key (0 on the 9-key digit page)"
                    )
                    XCTAssertFalse(policy.slots.map(policy.key(at:)).contains(.symbolPage))
                }
            }
        }
    }

    /// Bundled 9-key, as on Sogou / iFlytek: 符号 | 123 | 空格 | 中/英 on letters, so the symbol page is
    /// one tap from the bottom-left corner; on 123 and 符号 that corner returns to letters.
    func testBundledT9BottomRowLeadsWithSymbolKey() {
        func keys(_ page: KeyboardControlPolicy.Page, globe: Bool = false) -> [KeyboardControlPolicy.Slot] {
            let policy = KeyboardControlPolicy(
                page: page, isEnglishMode: false, hasGlobe: globe, isPhoneLayout: true,
                usesASCIIPunctuation: false, includesBottomEnter: false)
            return policy.slots.map(policy.key(at:))
        }
        XCTAssertEqual(keys(.letters), [.symbolPage, .page, .space, .language])
        XCTAssertEqual(keys(.numeric), [.language, .page, .space, .utility])
        XCTAssertEqual(keys(.symbols), [.language, .page, .space])
        XCTAssertEqual(keys(.letters, globe: true), [.symbolPage, .page, .globe, .space, .language])
        let letters = KeyboardControlPolicy(
            page: .letters, isEnglishMode: false, hasGlobe: false, isPhoneLayout: true,
            usesASCIIPunctuation: false, includesBottomEnter: false)
        XCTAssertEqual(letters.pageTitle, "123")
        XCTAssertEqual(letters.languageTitle, "ABC")
        let numeric = KeyboardControlPolicy(
            page: .numeric, isEnglishMode: false, hasGlobe: false, isPhoneLayout: true,
            usesASCIIPunctuation: false, includesBottomEnter: false)
        XCTAssertEqual(numeric.pageTitle, KeyboardControlPolicy.symbolPageTitle)
        XCTAssertEqual(numeric.pageTarget, .symbols)
        XCTAssertEqual(numeric.languageTitle, "返回")
        XCTAssertEqual(numeric.languageAction, .returnToLetters)
        // Generic surfaces keep their titles.
        let qwertyNumeric = KeyboardControlPolicy(
            page: .numeric, isEnglishMode: false, hasGlobe: false, isPhoneLayout: false,
            usesASCIIPunctuation: false)
        XCTAssertEqual(qwertyNumeric.pageTitle, "#+=")
        XCTAssertEqual(qwertyNumeric.languageTitle, "中文")
    }

    /// 9-key trailing column (system/mainstream 9-key): delete (row 0) + re-input (row 1) + return/confirm
    /// (row 2 through the bottom row, in the bottom-right corner). The bottom row stops one spacing left of the column and fills exactly.
    func testBundledT9ReturnFillsBottomRightCornerBesideControlRow() {
        for width in [312.0, 367, 382, 430] {
            let m = PhoneKeypadMetrics.resolve(width: width, rowHeight: 54)
            let slots = m.railSlots(.trailing, spans: PhoneKeypadRailPolicy.bundledTrailingSpans)
            XCTAssertEqual(slots.count, 3)
            XCTAssertEqual(slots[0].height, m.rowHeight, accuracy: 0.0001)
            XCTAssertEqual(slots[1].height, m.rowHeight, accuracy: 0.0001)
            let control = m.controlRowRectBesideTrailingRail()
            XCTAssertEqual(slots[2].minY, m.rowY(2), accuracy: 0.0001)
            XCTAssertEqual(
                slots[2].maxY, control.maxY, accuracy: 0.0001,
                "\(width): return must align with the bottom edge of the bottom row (bottom-right corner)")
            XCTAssertEqual(control.maxX + m.spacing, slots[2].minX, accuracy: 0.0001)
            XCTAssertGreaterThanOrEqual(
                slots[2].width * slots[2].height, 60 * m.rowHeight,
                "\(width): return must not be smaller than the historical bottom-row return budget")
            for page in [KeyboardControlPolicy.Page.letters, .numeric, .symbols] {
                let policy = KeyboardControlPolicy(
                    page: page, isEnglishMode: false,
                    hasGlobe: true, isPhoneLayout: true, usesASCIIPunctuation: false,
                    includesBottomEnter: false)
                XCTAssertFalse(
                    policy.slots.contains(.enter), "\(width): the 9-key bottom row must not repeat the confirm key")
                XCTAssertEqual(
                    policy.slots.contains(.utility), page != .symbols,
                    "\(width): letters hold 中/英 and 123 holds 0 there; the symbol page widens space")
                let metrics = policy.metrics(width: control.width)
                let total =
                    policy.slots.reduce(0.0) { $0 + metrics[$1] }
                    + metrics.spacing * Double(max(0, policy.slots.count - 1))
                XCTAssertEqual(total, control.width, accuracy: 0.0001)
            }
        }
    }

    /// 9-key bottom row aligns with the columns above: first key = rail width, second = one digit column, the last
    /// (中/英 or 0) = one digit column, space takes the remainder (two columns on the symbol page).
    func testBundledT9ControlRowAlignsWithColumns() {
        for width in [367.0, 382, 412, 430] {
            let m = PhoneKeypadMetrics.resolve(width: width, rowHeight: 54)
            let columns = KeyboardControlPolicy.PhoneColumns(rail: m.railWidth, digit: m.digitWidth)
            let control = m.controlRowRectBesideTrailingRail().width
            for page in [KeyboardControlPolicy.Page.letters, .numeric, .symbols] {
                let policy = KeyboardControlPolicy(
                    page: page, isEnglishMode: false, hasGlobe: false,
                    isPhoneLayout: true, usesASCIIPunctuation: false,
                    includesBottomEnter: false
                ).aligned(to: columns)
                let metrics = policy.metrics(width: control)
                XCTAssertEqual(metrics.page, m.railWidth, accuracy: 0.0001)
                XCTAssertEqual(metrics.language, m.digitWidth, accuracy: 0.0001)
                let expectedSpace = page == .symbols ? m.digitWidth * 2 + m.spacing : m.digitWidth
                XCTAssertEqual(metrics.space, expectedSpace, accuracy: 0.0001, "\(width) \(page)")
                let total =
                    policy.slots.reduce(0.0) { $0 + metrics[$1] }
                    + metrics.spacing * Double(max(0, policy.slots.count - 1))
                XCTAssertEqual(total, control, accuracy: 0.0001)
            }
        }
    }

    /// Other layouts (including imported keyboards) keep Return in the bottom row; only the builtin 9-key moves confirm into the trailing column.
    func testOnlyBundledT9OmitsBottomEnter() {
        let withEnter = KeyboardControlPolicy(
            page: .letters, isEnglishMode: false,
            hasGlobe: false, isPhoneLayout: false, usesASCIIPunctuation: false)
        XCTAssertTrue(withEnter.slots.contains(.enter))
        XCTAssertGreaterThanOrEqual(withEnter.metrics(width: 382).enter, 60)
        let t9 = KeyboardControlPolicy(
            page: .letters, isEnglishMode: false,
            hasGlobe: false, isPhoneLayout: true, usesASCIIPunctuation: false,
            includesBottomEnter: false)
        XCTAssertEqual(t9.slots, [.page, .language, .space, .utility])
    }

    func testTinyOrInvalidPreviewWidthNeverOverflowsOrProducesNaN() {
        for globe in [false, true] {
            let policy = KeyboardControlPolicy(
                page: .numeric, isEnglishMode: false,
                hasGlobe: globe, isPhoneLayout: false, usesASCIIPunctuation: false)
            for width in [0.0, 44, 180, 250, -1, .nan, .infinity] {
                let metrics = policy.metrics(width: width)
                for slot in policy.slots {
                    XCTAssertTrue(metrics[slot].isFinite)
                    XCTAssertGreaterThanOrEqual(metrics[slot], 0)
                }
                let total =
                    policy.slots.reduce(0) { $0 + metrics[$1] }
                    + Double(policy.slots.count - 1) * metrics.spacing
                XCTAssertEqual(total, width.isFinite ? max(0, width) : 0, accuracy: 0.0001)
            }
        }
    }

    func testT9SeparatorKeyAndAddressFallback() {
        for ascii in [false, true] {
            // The first key while composing still separates syllables; long-press is digit 1 like 2-9 (not cycling, not punctuation).
            let separator = BuiltinLayouts.t9SeparatorKey()
            XCTAssertEqual(separator.action, .init(.code, value: "'"))
            XCTAssertEqual(separator.secondaryLabel, "1")
            XCTAssertEqual(separator.longPress?.compactMap(\.action.value), ["1"])
            XCTAssertEqual(separator.longPress?.first?.action.type, .literal)
            let fallback = BuiltinLayouts.t9PunctuationSymbols()
            XCTAssertFalse(fallback.contains("1"))
            if ascii { XCTAssertTrue(fallback.allSatisfy { $0.utf8.allSatisfy { $0 < 128 } }) }
        }
    }

    /// The first key's long-press must match 2-9: badge 1 + long-press types literal 1.
    /// The persisted declaration must carry it too: the layout manager/resource inspector show the declared key,
    /// and adding it only in a UI callback would make declaration and runtime disagree.
    func testFirstKeyLongPressMatchesDigitKeys() throws {
        let cycle = try XCTUnwrap(BuiltinLayouts.t9CycleKey(["！", "、", "…"]))
        for key in [cycle, BuiltinLayouts.t9SeparatorKey()] {
            XCTAssertEqual(key.secondaryLabel, "1", "badge must match 2-9")
            XCTAssertEqual(key.longPress?.count, 1)
            XCTAssertEqual(key.longPress?.first?.label, "1")
            XCTAssertEqual(key.longPress?.first?.action, .init(.literal, value: "1"))
        }
        // Style baseline of 2-9: the same secondaryLabel + a single literal longPress.
        // Real declared shape of 2-9: letter label + digit badge + code action + a single literal long-press.
        let digits = BuiltinLayouts.phone9.rows.flatMap(\.keys).filter {
            $0.action.type == .code && $0.longPress?.count == 1
        }
        XCTAssertEqual(digits.count, 8, "expected 8 digit keys (2-9)")
        for key in digits {
            let digit = try XCTUnwrap(key.action.value)
            XCTAssertEqual(key.secondaryLabel, digit, "badge = the key's digit")
            XCTAssertEqual(
                key.longPress?.compactMap(\.action.value), [digit],
                "long-press types the same digit directly")
            XCTAssertEqual(key.longPress?.first?.action.type, .literal)
        }
        let digitTwo = try XCTUnwrap(digits.first { $0.action.value == "2" })
        XCTAssertEqual(cycle.longPress?.count, digitTwo.longPress?.count)
        XCTAssertEqual(digitTwo.secondaryLabel, "2")

        // Persisted declaration consistency: the builtin phone9's stored first key also carries 1.
        let stored = BuiltinLayouts.phone9.rows[0].keys[0]
        XCTAssertEqual(stored.secondaryLabel, "1", "the declaration must carry 1 too, not only a runtime substitution")
        XCTAssertEqual(stored.longPress?.compactMap(\.action.value), ["1"])
        XCTAssertEqual(stored.action, .init(.literal, value: "，"))
    }

    /// Rail first three + first-key cycle must exactly partition the saved order: no duplicates, no gaps, same order.
    func testQuickSymbolPartitionCoversSavedOrderExactlyOnce() {
        for ascii in [false, true] {
            for saved in ["，。？！、…：；（）【】", "@/-()…", "@（，,、。.?？!！）…@", "。"] {
                let ordered = BuiltinLayouts.t9QuickSymbolValues(saved: saved, ascii: ascii)
                let rail = BuiltinLayouts.t9QuickRailValues(saved: saved, ascii: ascii)
                let cycle = BuiltinLayouts.t9QuickCycleValues(saved: saved, ascii: ascii)
                XCTAssertEqual(rail + cycle, ordered, "saved=\(saved) ascii=\(ascii)")
                XCTAssertLessThanOrEqual(rail.count, 3)
                XCTAssertEqual(Set(rail).count, rail.count, "the rail must not repeat")
                XCTAssertEqual(Set(cycle).count, cycle.count, "the cycle must not repeat")
                XCTAssertTrue(Set(rail).isDisjoint(with: Set(cycle)), "the two reachability sets must not overlap")
                XCTAssertEqual(cycle, Array(ordered.dropFirst(3)))
                XCTAssertFalse(
                    cycle.isEmpty,
                    "the original first-key marks keep the tail non-empty, so the first key never becomes dead")
            }
        }
    }

    /// Default sequence: the rail is exactly the top three frequent symbols, and the cycle starts at the 4th item and keeps the original first-key marks.
    func testDefaultOrderGivesRailThreeAndCycleFromFourth() {
        let saved = T9QuickSymbolStore.defaultSymbols
        XCTAssertEqual(
            BuiltinLayouts.t9QuickRailValues(saved: saved, ascii: false),
            ["，", "。", "？"])
        XCTAssertEqual(
            BuiltinLayouts.t9QuickCycleValues(saved: saved, ascii: false),
            ["！", "、", "…", "@", "/", ".", ":", "_", "-"])
        // ASCII: map full-width first, then de-duplicate (`、`->`,` and `，`->`,` collide, keeping only the first occurrence's position).
        XCTAssertEqual(BuiltinLayouts.t9QuickRailValues(saved: saved, ascii: true), [",", ".", "?"])
        XCTAssertEqual(
            BuiltinLayouts.t9QuickCycleValues(saved: saved, ascii: true),
            ["!", "...", "@", "/", ":", "_", "-"])
        for ascii in [false, true] {
            let cycle = BuiltinLayouts.t9QuickCycleValues(saved: saved, ascii: ascii)
            let rail = BuiltinLayouts.t9QuickRailValues(saved: saved, ascii: ascii)
            XCTAssertTrue(Set(rail).isDisjoint(with: Set(cycle)), "the first three must not reappear in the cycle")
        }
    }

    /// ASCII mapping must cover all full-width punctuation in the manager's default sequence, or ASCII fields get full-width characters.
    func testASCIIMappingCoversManagedDefaultPunctuation() {
        let managed = "，。？！、…：；（）【】"
        let mapped = BuiltinLayouts.t9QuickSymbolValues(saved: managed, ascii: true)
        XCTAssertEqual(
            Array(mapped.prefix(12)),
            [",", ".", "?", "!", "...", ":", ";", "(", ")", "[", "]", "@"])
        XCTAssertTrue(
            mapped.allSatisfy { $0.utf8.allSatisfy { $0 < 128 } },
            "the ASCII sequence must keep no full-width punctuation: \(mapped)")
        // Chinese mode keeps the user's characters verbatim, with no mapping.
        let chinese = BuiltinLayouts.t9QuickSymbolValues(saved: managed, ascii: false)
        XCTAssertEqual(
            Array(chinese.prefix(12)),
            ["，", "。", "？", "！", "、", "…", "：", "；", "（", "）", "【", "】"])
    }

    /// The address/URL marks are not in the quick bar default set; the cycle tail keeps them reachable.
    func testAddressMarksStayReachableFromTheCycle() {
        let saved = T9QuickSymbolStore.defaultSymbols
        for ascii in [false, true] {
            let cycle = BuiltinLayouts.t9QuickCycleValues(saved: saved, ascii: ascii)
            let rail = BuiltinLayouts.t9QuickRailValues(saved: saved, ascii: ascii)
            let ordered = BuiltinLayouts.t9QuickSymbolValues(saved: saved, ascii: ascii)
            for mark in BuiltinLayouts.t9PunctuationSymbols() {
                XCTAssertTrue(ordered.contains(mark), "\(mark) must still be reachable")
            }
            // `@` and `/` are not in the default quick set, so they land in the cycle (not the first three).
            XCTAssertTrue(cycle.contains("@"), "ascii=\(ascii)")
            XCTAssertTrue(cycle.contains("/"), "ascii=\(ascii)")
            XCTAssertFalse(rail.contains("@"), "ascii=\(ascii)")
            XCTAssertFalse(rail.contains("/"), "ascii=\(ascii)")
            // A mark duplicating an earlier item keeps only its first position.
            XCTAssertEqual(Set(cycle).count, cycle.count)
        }
    }

    /// Cap and first-insert action both derive from the cycle order: the label is the first three items, tap inserts the first.
    func testCycleKeyDerivesLabelAndInsertionFromRealOrder() throws {
        let key = try XCTUnwrap(BuiltinLayouts.t9CycleKey(["！", "、", "…"]))
        XCTAssertEqual(key.label, "！、…")
        XCTAssertEqual(key.action, .init(.literal, value: "！"))
        XCTAssertEqual(
            key.longPress?.compactMap(\.action.value), ["1"],
            "the cycle key has a single long-press alternate, digit 1 (like 2-9), and no symbol menu")
        XCTAssertNil(
            BuiltinLayouts.t9CycleKey([]), "an empty order must not fabricate a key that looks usable but is not")
        // With a single item, label and action are both that item.
        let single = try XCTUnwrap(BuiltinLayouts.t9CycleKey(["！"]))
        XCTAssertEqual(single.label, "！")
        XCTAssertEqual(single.action, .init(.literal, value: "！"))
        // Tied to the real default cycle order: the label must equal the first three items of that order.
        let cycle = BuiltinLayouts.t9QuickCycleValues(
            saved: T9QuickSymbolStore.defaultSymbols,
            ascii: false)
        XCTAssertEqual(
            try XCTUnwrap(BuiltinLayouts.t9CycleKey(cycle)).label,
            cycle.prefix(3).joined())
    }

    /// 9-key digit page: the utility slot is 0; other layouts keep punctuation as usual.
    func testPhoneNumericUtilityIsZero() {
        let qwerty = KeyboardControlPolicy(
            page: .letters, isEnglishMode: false, hasGlobe: false,
            isPhoneLayout: false, usesASCIIPunctuation: false)
        XCTAssertEqual(qwerty.utility, .punctuation("，"))
        let numeric = KeyboardControlPolicy(
            page: .numeric, isEnglishMode: false, hasGlobe: false,
            isPhoneLayout: true, usesASCIIPunctuation: false,
            includesBottomEnter: false)
        XCTAssertEqual(numeric.utility, .digit("0"))
    }

    /// Builtin 9-key 2-9 long-press must work and use the layout's declared digit.
    ///
    /// Uses the real API (not just static LayoutKey assertions): first proves the generic policy returns empty for a
    /// digit-code key with an ABC cap (which is why it cannot go through that path), then that the production
    /// predicate hands them to the declared path and the declared alternate is exactly that digit's literal.
    func testT9DigitKeysTakeDeclaredAlternatesBecausePolicyDropsThem() throws {
        let digits = BuiltinLayouts.phone9.rows.flatMap(\.keys).filter {
            $0.action.type == .code && ("2"..."9").contains($0.action.value ?? "")
        }
        XCTAssertEqual(digits.count, 8, "the builtin 9-key should have 8 digit keys (2-9)")

        for key in digits {
            let digit = try XCTUnwrap(key.action.value)

            // The generic policy returns empty for these keys (reproduces the request the panel really builds).
            let policyOptions = AlternateKeyPolicy.options(
                for: .init(
                    keyLabel: digit,
                    mergedGroup: key.label.lowercased(),
                    secondaryLiterals: (key.longPress ?? []).compactMap {
                        $0.action.type == .literal ? $0.action.value : nil
                    },
                    page: .letters,
                    language: .chinese,
                    schemaAlphabet: "abcdefghijklmnopqrstuvwxyz"))
            XCTAssertTrue(
                policyOptions.isEmpty,
                "\(digit) generic policy must return empty, otherwise this regression is moot (root cause changed; revisit)"
            )

            // The production predicate must route these keys to the declared path.
            XCTAssertTrue(
                BuiltinLayouts.t9DigitKeyUsesDeclaredAlternates(key),
                "\(digit) must take the declared path, otherwise the long-press digit is lost")

            // The declared alternate is exactly that digit's literal (long-press types it directly, not a code).
            let declared = try XCTUnwrap(key.longPress)
            XCTAssertEqual(declared.count, 1, "\(digit) should have exactly one declared long-press alternate")
            XCTAssertEqual(declared.first?.action, .init(.literal, value: digit))
            XCTAssertEqual(declared.first?.label, digit)
        }
    }

    /// The predicate must not hit control keys, auxiliary keys, letter keys or DIY definitions (that would open the
    /// fixed letter menu or rewrite other layouts' alternate policy).
    func testDeclaredAlternatesPredicateOnlyCoversBundledT9Digits() {
        for key in BuiltinLayouts.phone9.rows.flatMap(\.keys) {
            let value = key.action.value ?? ""
            let isDigit = key.action.type == .code && ("2"..."9").contains(value) && value.count == 1
            XCTAssertEqual(
                BuiltinLayouts.t9DigitKeyUsesDeclaredAlternates(key), isDigit,
                "\(key.label) predicate disagrees with \"is a digit-code key\"")
        }
        // Control row (layout/space/globe) and auxiliary area (delete/separator/return) are all excluded.
        for area in BuiltinLayouts.phone9.auxiliaryAreas ?? [] {
            for key in area.keys {
                XCTAssertFalse(
                    BuiltinLayouts.t9DigitKeyUsesDeclaredAlternates(key),
                    "auxiliary key \(key.label)  must not take the declared path")
            }
        }
        // 26-key letter keys are unaffected (their generic policy path is valid and must stay).
        let letter = BuiltinLayouts.qwerty26.rows.flatMap(\.keys)
            .first { $0.action.type == .code && $0.label == "a" }
        if let letter {
            XCTAssertFalse(
                BuiltinLayouts.t9DigitKeyUsesDeclaredAlternates(letter),
                "letter keys must keep going through AlternateKeyPolicy")
            let options = AlternateKeyPolicy.options(
                for: .init(
                    keyLabel: "a", secondaryLiterals: ["，", ","], page: .letters, language: .chinese))
            XCTAssertEqual(options.map(\.label), ["，", ","], "the 26-key letter key alternate policy must not change")
        }
        // Digit-code keys without declared long-press alternates fall back to the generic policy (no new behavior).
        let bare = LayoutKey(label: "ABC", secondaryLabel: "2", action: .init(.code, value: "2"))
        XCTAssertFalse(BuiltinLayouts.t9DigitKeyUsesDeclaredAlternates(bare))
    }
}
