import XCTest

@testable import LayoutKit

/// The two-line syllable-hint policy: long shuangpin hints stay meaningful,
/// everything else keeps its current single-line semantics.
final class KeyHintLayoutPolicyTests: XCTestCase {

    /// Deterministic stand-in for `NSString.size(withAttributes:)`: a fixed
    /// advance per character. The policy only consumes the resulting width.
    private func width(_ text: String, advance: Double = 5) -> Double {
        Double(text.count) * advance
    }

    // MARK: Shuangpin syllable hints

    func testLongShuangpinHintsWrapToTwoLines() {
        // Real Xiaohe hints, measured in the 9pt corner font (~5pt advance).
        for hint in ["ong/iong", "ing/uai", "iang/uang", "ia/ua", "zh/ui"] {
            let measured = width(hint)
            XCTAssertEqual(
                KeyHintLayoutPolicy.lineCount(
                    kind: .syllableHint,
                    measuredWidth: measured,
                    availableWidth: 24),
                2, "\(hint) must not be truncated to meaninglessness")
        }
    }

    func testShortShuangpinHintsStayOnOneLine() {
        for hint in ["iu", "ei", "sh", "ch", "an", "ou"] {
            XCTAssertEqual(
                KeyHintLayoutPolicy.lineCount(
                    kind: .syllableHint,
                    measuredWidth: width(hint),
                    availableWidth: 24),
                1, "\(hint) stays a single line")
        }
    }

    func testShuangpinHintWrapsOnlyOnceTheWidthIsActuallyTooSmall() {
        let measured = width("ong/iong")  // 40pt
        XCTAssertEqual(
            KeyHintLayoutPolicy.lineCount(
                kind: .syllableHint,
                measuredWidth: measured, availableWidth: 44), 1)
        XCTAssertEqual(
            KeyHintLayoutPolicy.lineCount(
                kind: .syllableHint,
                measuredWidth: measured, availableWidth: 40), 1,
            "exactly fitting is not a reason to wrap")
        XCTAssertEqual(
            KeyHintLayoutPolicy.lineCount(
                kind: .syllableHint,
                measuredWidth: measured, availableWidth: 39), 2)
    }

    func testNarrowKeyWidthStillYieldsAReadableTwoLineHint() {
        // A 26-key on a 320pt-wide keyboard: ~24pt of content width.
        let advance = 6.0
        let text = "iang/uang"  // 9 characters, Xiaohe's longest hint
        let measured = width(text, advance: advance)  // 54pt
        XCTAssertEqual(
            KeyHintLayoutPolicy.lineCount(
                kind: .syllableHint,
                measuredWidth: measured, availableWidth: 24), 2)
        let scale = KeyHintLayoutPolicy.requiredScaleFactor(
            measuredWidth: measured,
            availableWidth: 24, lines: 2)
        XCTAssertLessThan(scale, 1)
        XCTAssertGreaterThanOrEqual(
            scale, KeyHintLayoutPolicy.minimumScaleFactor,
            "the hint stays legible instead of shrinking without limit")
        XCTAssertLessThanOrEqual(
            measured * scale, 24 * 2 + 0.0001,
            "two scaled lines can hold the whole hint")

        // Character wrapping is discrete: the longest line holds half the hint,
        // and the policy floor must be enough to fit that line.
        let longestLineWidth = Double((text.count + 1) / 2) * advance * KeyHintLayoutPolicy.minimumScaleFactor
        XCTAssertLessThanOrEqual(
            longestLineWidth, 24 + 0.0001,
            "even the floor scale keeps the wrapped line inside a narrow key")
    }

    func testVeryLongHintNeverShrinksBelowTheFloor() {
        let measured = width("这是一个超长的提示文本不会出现")
        let scale = KeyHintLayoutPolicy.requiredScaleFactor(
            measuredWidth: measured,
            availableWidth: 20, lines: 2)
        XCTAssertEqual(scale, KeyHintLayoutPolicy.minimumScaleFactor, accuracy: 0.0001)
    }

    // MARK: Non-syllable hints keep their current semantics

    func testAlternateAndPhoneHintsNeverWrap() {
        for kind in [KeyHintLayoutPolicy.Kind.alternate, .phoneLetters] {
            XCTAssertFalse(KeyHintLayoutPolicy.allowsWrapping(kind))
            XCTAssertEqual(
                KeyHintLayoutPolicy.lineCount(
                    kind: kind,
                    measuredWidth: 200,
                    availableWidth: 10), 1,
                "a long-press digit / phone label is never split across lines")
        }
        XCTAssertTrue(KeyHintLayoutPolicy.allowsWrapping(.syllableHint))
    }

    func testAlternateHintsAreUnaffectedEvenWhenTheyLookLikeAHint() {
        // The 14-key merged key's "1 !" and "合并键" are secondary labels, but the
        // label that draws the first long-press alternate must stay one line.
        XCTAssertEqual(
            KeyHintLayoutPolicy.lineCount(
                kind: .alternate,
                measuredWidth: width("1 !"), availableWidth: 12), 1)
        XCTAssertEqual(
            KeyHintLayoutPolicy.lineCount(
                kind: .phoneLetters,
                measuredWidth: width("2"), availableWidth: 8), 1)
    }

    // MARK: Geometry

    func testSingleLineHeightIsUnchanged() {
        XCTAssertEqual(KeyHintLayoutPolicy.height(lines: 1, lineHeight: 12), 12)
        XCTAssertEqual(
            KeyHintLayoutPolicy.height(lines: 1, lineHeight: 99), 12,
            "a one-line hint keeps the existing 12pt band")
    }

    func testWrappedHeightGrowsToFitTwoLines() {
        let height = KeyHintLayoutPolicy.height(lines: 2, lineHeight: 11)
        XCTAssertGreaterThan(height, 12)
        XCTAssertEqual(height, 2 * 11 + KeyHintLayoutPolicy.wrappedLineSpacing, accuracy: 0.0001)
        XCTAssertEqual(KeyHintLayoutPolicy.height(lines: 0, lineHeight: 11), 12)
        XCTAssertEqual(
            KeyHintLayoutPolicy.height(lines: 2, lineHeight: 0), 12,
            "a degenerate font metric can never produce a zero-height label")
    }

    func testWrappedHintsStepDownInSizeButShortHintsDoNot() {
        XCTAssertEqual(KeyHintLayoutPolicy.fontScale(lines: 1), 1)
        XCTAssertEqual(
            KeyHintLayoutPolicy.fontScale(lines: 2), KeyHintLayoutPolicy.wrappedFontScale,
            accuracy: 0.0001)
        XCTAssertLessThan(KeyHintLayoutPolicy.wrappedFontScale, 1)
        XCTAssertGreaterThan(KeyHintLayoutPolicy.wrappedFontScale, KeyHintLayoutPolicy.minimumScaleFactor)
        // Two wrapped lines at the stepped-down size still fit the corner band of
        // a 54pt key (top ~24pt before the centred 18pt letter's cap height).
        let block = KeyHintLayoutPolicy.height(lines: 2, lineHeight: 11 * KeyHintLayoutPolicy.wrappedFontScale)
        XCTAssertLessThanOrEqual(block, 24)
    }

    func testRequiredScaleFactorIsOneWhenTheTextFits() {
        XCTAssertEqual(KeyHintLayoutPolicy.requiredScaleFactor(measuredWidth: 10, availableWidth: 24, lines: 1), 1)
        XCTAssertEqual(KeyHintLayoutPolicy.requiredScaleFactor(measuredWidth: 48, availableWidth: 24, lines: 2), 1)
        XCTAssertEqual(
            KeyHintLayoutPolicy.requiredScaleFactor(measuredWidth: 60, availableWidth: 24, lines: 2), 0.8,
            accuracy: 0.0001)
    }

    func testDegenerateInputsAreSafe() {
        XCTAssertEqual(KeyHintLayoutPolicy.lineCount(kind: .syllableHint, measuredWidth: 40, availableWidth: 0), 1)
        XCTAssertEqual(
            KeyHintLayoutPolicy.lineCount(kind: .syllableHint, measuredWidth: .infinity, availableWidth: 24), 1)
        XCTAssertEqual(KeyHintLayoutPolicy.lineCount(kind: .syllableHint, measuredWidth: 40, availableWidth: .nan), 1)
        XCTAssertEqual(KeyHintLayoutPolicy.requiredScaleFactor(measuredWidth: 0, availableWidth: 0, lines: 2), 1)
    }

    // MARK: Per-letter columns on merged keys

    func testMergedKeyColumnsKeepLongHintsReadable() {
        // A pair cap on a 390pt-wide keyboard: 14-key splits the row into five equal caps,
        // 18-key spans two 26-key units plus their gap; both are ~75pt, ~69pt of content.
        let fourteen = (390.0 - 4 * 4) / 5
        let unit = (390.0 - 9 * 4) / 10
        let eighteen = 2 * unit + 4
        for cap in [fourteen, eighteen] {
            let column = KeyHintLayoutPolicy.columnWidth(total: cap - 6, columns: 2)
            XCTAssertGreaterThan(column, 30)
            for hint in ["ing/uai", "iang/uang", "ong/iong"] {
                let measured = width(hint)
                let lines = KeyHintLayoutPolicy.lineCount(
                    kind: .syllableHint,
                    measuredWidth: measured, availableWidth: column)
                XCTAssertLessThanOrEqual(lines, 2)
                let scale = KeyHintLayoutPolicy.requiredScaleFactor(
                    measuredWidth: measured,
                    availableWidth: column, lines: lines)
                XCTAssertGreaterThanOrEqual(
                    scale, KeyHintLayoutPolicy.minimumScaleFactor,
                    "\(hint) fits its column without truncation")
            }
        }
    }

    func testColumnSplitLeavesTheGapBetweenColumns() {
        XCTAssertEqual(KeyHintLayoutPolicy.columnWidth(total: 70, columns: 2), 34)
        XCTAssertEqual(KeyHintLayoutPolicy.columnWidth(total: 70, columns: 1), 70)
        XCTAssertEqual(KeyHintLayoutPolicy.columnWidth(total: 70, columns: 0), 0)
    }
}
