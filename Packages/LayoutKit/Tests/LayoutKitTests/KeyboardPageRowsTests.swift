import XCTest

@testable import LayoutKit

/// The 123 and row-shaped #+= pages share one ten-column grid. Their third row is the
/// page switch, seven marks and Delete, with the side keys as wide as Shift and Delete on
/// the ABC page, so the rows end on the same edges.
final class KeyboardPageRowsTests: XCTestCase {
    private let spacing = 4.0

    func testBothPagesKeepTenColumnRowsWithASevenMarkThirdRow() {
        for ascii in [false, true] {
            for rows in [
                BuiltinLayouts.numericPageRows(ascii: ascii),
                BuiltinLayouts.symbolPageRows(ascii: ascii),
            ] {
                XCTAssertEqual(rows.count, 3)
                XCTAssertEqual(rows.map(\.count), [10, 10, 7])
                XCTAssertTrue(rows.allSatisfy { $0.allSatisfy { !$0.isEmpty } })
                if ascii {
                    // Only the third row is checked: the two mark rows above keep
                    // the accepted € £ ¥ • currency/bullet marks, as before.
                    XCTAssertTrue(
                        rows[2].allSatisfy { $0.utf8.allSatisfy { $0 < 128 } },
                        "the ASCII third row must not offer a full-width mark")
                }
            }
        }
    }

    /// Switch + seven marks + Delete fills the same width as a ten-cap letter row, with both
    /// side keys at thirdRowSideWidth (the ABC page's Shift / Delete width).
    func testThirdRowPlusSwitchAndDeleteFillsTheTenColumnWidth() {
        for width in [280.0, 320, 382, 422, 768, 1024] {
            for split in [nil, LayoutSplitConfiguration(activation: .always, rowBreaks: [5, 4, 3], gapFraction: 0.24)] {
                let geometry = StandardKeyRowGeometry(width: width, split: split?.resolved(forWidth: width))
                let contentWidth = width - geometry.gap
                let letterRow = geometry.keyWidth * 10 + spacing * 9
                let marks = geometry.keyWidth * 7 + spacing * 6
                let fullRow = geometry.thirdRowSideWidth * 2 + marks + spacing * 2 + geometry.gap
                XCTAssertEqual(letterRow, contentWidth, accuracy: 0.001)
                XCTAssertEqual(fullRow, letterRow + geometry.gap, accuracy: 0.001)
            }
        }
    }

    func testNoCharacterRepeatsWithinAPage() {
        for ascii in [false, true] {
            for (name, rows) in [
                ("123", BuiltinLayouts.numericPageRows(ascii: ascii)),
                ("#+=", BuiltinLayouts.symbolPageRows(ascii: ascii)),
            ] {
                let characters = rows.flatMap { $0 }
                XCTAssertEqual(
                    characters.count, Set(characters).count,
                    "\(name) page repeats a character, so the cap set has a dead key")
            }
        }
    }

    /// The runtime tables and the editable page presets read the same canonical
    /// rows; otherwise editing a page could silently diverge from the built-in one.
    func testEditablePresetsUseTheCanonicalRows() {
        XCTAssertEqual(presetRows(KeyboardPagePresets.numericChinese), BuiltinLayouts.numericPageRows(ascii: false))
        XCTAssertEqual(presetRows(KeyboardPagePresets.numericEnglish), BuiltinLayouts.numericPageRows(ascii: true))
        XCTAssertEqual(presetRows(KeyboardPagePresets.symbolsChinese), BuiltinLayouts.symbolPageRows(ascii: false))
        XCTAssertEqual(presetRows(KeyboardPagePresets.symbolsEnglish), BuiltinLayouts.symbolPageRows(ascii: true))
        XCTAssertEqual(presetRows(KeyboardPagePresets.symbolsSystem), BuiltinLayouts.symbolPageRows(ascii: false))
    }

    /// A native letter page types a comma from the utility slot (the row page's third row carries
    /// the symbol switch); the 123 and #+= row pages have no utility slot at all. Phone pads
    /// keep their direct symbol key and their 0 / 锁定 actions.
    func testLetterPagesTypeCommaAndRowPagesHaveNoUtilitySlot() {
        for english in [false, true] {
            for globe in [false, true] {
                let letters = KeyboardControlPolicy(
                    page: .letters, isEnglishMode: english, hasGlobe: globe,
                    isPhoneLayout: false, usesASCIIPunctuation: english)
                XCTAssertEqual(letters.key(at: .utility), .utility)
                let phoneLetters = KeyboardControlPolicy(
                    page: .letters, isEnglishMode: english, hasGlobe: globe,
                    isPhoneLayout: true, usesASCIIPunctuation: english)
                XCTAssertEqual(phoneLetters.key(at: .utility), .symbolPage)
                for page in [KeyboardControlPolicy.Page.numeric, .symbols] {
                    let policy = KeyboardControlPolicy(
                        page: page, isEnglishMode: english, hasGlobe: globe,
                        isPhoneLayout: false, usesASCIIPunctuation: english,
                        usesCategorySymbolPage: false)
                    XCTAssertEqual(policy.key(at: .utility), .utility, "\(page) keeps the comma")
                }
            }
        }
        let digitPage = KeyboardControlPolicy(
            page: .numeric, isEnglishMode: false, hasGlobe: true,
            isPhoneLayout: true, usesASCIIPunctuation: false, includesBottomEnter: false)
        XCTAssertEqual(digitPage.utility, .digit("0"))
        let categorized = KeyboardControlPolicy(
            page: .symbols, isEnglishMode: false, hasGlobe: true,
            isPhoneLayout: true, usesASCIIPunctuation: false, includesBottomEnter: false)
        XCTAssertEqual(categorized.key(at: .utility), .symbolLock)
    }

    /// The letter page's comma and its long-press marks are the sentence marks, so the
    /// ASCII branch must stay ASCII.
    func testLetterCommaAndItsLongPressFollowTheSymbolBranch() {
        for ascii in [false, true] {
            let policy = KeyboardControlPolicy(
                page: .letters, isEnglishMode: ascii, hasGlobe: true,
                isPhoneLayout: false, usesASCIIPunctuation: ascii)
            XCTAssertEqual(policy.utility, .punctuation(ascii ? "," : "，"))
            if ascii {
                XCTAssertTrue(policy.utilityAlternates.allSatisfy { $0.utf8.allSatisfy { $0 < 128 } })
            }
        }
    }

    private func presetRows(_ page: KeyboardPageDefinition) -> [[String]] {
        page.rows.map { $0.keys.map(\.label) }
    }
}
