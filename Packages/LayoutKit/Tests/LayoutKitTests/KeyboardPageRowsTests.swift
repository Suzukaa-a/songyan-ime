import XCTest

@testable import LayoutKit

/// The 123 and row-shaped #+= pages share one ten-column grid. Their third row
/// carries one character per column with Delete in the last one, so its caps are
/// exactly as wide as the rows above instead of a few wide caps standing out.
final class KeyboardPageRowsTests: XCTestCase {
    private let spacing = 4.0

    func testBothPagesKeepTenColumnRowsWithANineCharacterThirdRow() {
        for ascii in [false, true] {
            for rows in [
                BuiltinLayouts.numericPageRows(ascii: ascii),
                BuiltinLayouts.symbolPageRows(ascii: ascii),
            ] {
                XCTAssertEqual(rows.count, 3)
                XCTAssertEqual(rows.map(\.count), [10, 10, 9])
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

    /// A nine-cap third row plus Delete fills the same width as a ten-cap letter
    /// row: 9*keyWidth + 8 gaps + one gap + keyWidth == 10*keyWidth + 9 gaps.
    func testThirdRowPlusDeleteFillsTheTenColumnWidth() {
        for width in [280.0, 320, 382, 422, 768, 1024] {
            for split in [nil, LayoutSplitConfiguration(rowBreaks: [5, 4, 3], gapFraction: 0.24)] {
                let geometry = StandardKeyRowGeometry(width: width, split: split)
                let contentWidth = width - geometry.gap
                let letterRow = geometry.keyWidth * 10 + spacing * 9
                let thirdRow = geometry.keyWidth * 9 + spacing * 8
                let rowPlusDelete = thirdRow + spacing + geometry.keyWidth
                XCTAssertEqual(letterRow, contentWidth, accuracy: 0.001)
                XCTAssertEqual(rowPlusDelete, letterRow, accuracy: 0.001)
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

    /// Every letter page opens the symbol page from the bottom row's utility slot,
    /// where a comma/period used to sit, while 123 and #+= keep their own actions.
    func testLetterPagesOpenSymbolsAndNumberPagesKeepTheirUtility() {
        for phone in [false, true] {
            for english in [false, true] {
                for globe in [false, true] {
                    let letters = KeyboardControlPolicy(
                        page: .letters, isEnglishMode: english, hasGlobe: globe,
                        isPhoneLayout: phone, usesASCIIPunctuation: english)
                    XCTAssertEqual(letters.key(at: .utility), .symbolPage)
                    let numeric = KeyboardControlPolicy(
                        page: .numeric, isEnglishMode: english, hasGlobe: globe,
                        isPhoneLayout: phone, usesASCIIPunctuation: english)
                    XCTAssertNotEqual(numeric.key(at: .utility), .symbolPage)
                    let symbols = KeyboardControlPolicy(
                        page: .symbols, isEnglishMode: english, hasGlobe: globe,
                        isPhoneLayout: phone, usesASCIIPunctuation: english,
                        usesCategorySymbolPage: false)
                    XCTAssertNotEqual(symbols.key(at: .utility), .symbolPage)
                }
            }
        }
        let digitPage = KeyboardControlPolicy(
            page: .numeric, isEnglishMode: false, hasGlobe: true,
            isPhoneLayout: true, usesASCIIPunctuation: false, includesBottomEnter: false)
        XCTAssertEqual(digitPage.utility, .digit("0"))
        let categorised = KeyboardControlPolicy(
            page: .symbols, isEnglishMode: false, hasGlobe: true,
            isPhoneLayout: true, usesASCIIPunctuation: false, includesBottomEnter: false)
        XCTAssertEqual(categorised.key(at: .utility), .symbolLock)
    }

    /// The utility key on the row pages must not repeat a mark its own rows type.
    func testUtilityKeyAndItsLongPressStayClearOfThePageRows() {
        for ascii in [false, true] {
            for page in [KeyboardControlPolicy.Page.numeric, .symbols] {
                let policy = KeyboardControlPolicy(
                    page: page, isEnglishMode: ascii, hasGlobe: true,
                    isPhoneLayout: false, usesASCIIPunctuation: ascii, usesCategorySymbolPage: false)
                guard case .punctuation(let text) = policy.utility else {
                    return XCTFail("row pages keep a punctuation utility key")
                }
                let rows =
                    page == .numeric
                    ? BuiltinLayouts.numericPageRows(ascii: ascii)
                    : BuiltinLayouts.symbolPageRows(ascii: ascii)
                let visible = Set(rows.flatMap { $0 })
                XCTAssertFalse(visible.contains(text), "\(page) utility repeats \(text)")
                for alternate in policy.utilityAlternates {
                    XCTAssertFalse(visible.contains(alternate), "\(page) long press repeats \(alternate)")
                }
            }
        }
    }

    private func presetRows(_ page: KeyboardPageDefinition) -> [[String]] {
        page.rows.map { $0.keys.map(\.label) }
    }
}
