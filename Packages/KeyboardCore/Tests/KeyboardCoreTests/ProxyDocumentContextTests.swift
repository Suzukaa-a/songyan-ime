import XCTest

@testable import KeyboardCore

final class ProxyDocumentContextTests: XCTestCase {
    func testLongDocumentWindowLengthChangesKeepBothCaretAnchors() {
        let before = String(repeating: "原文", count: 1024) + "光标前的文字👩🏽‍💻"
        let after = "光标后的文字𠮷" + String(repeating: "尾文", count: 1024)
        let full = ProxyDocumentContext(before: before, after: after, selected: nil)
        let window = ProxyDocumentContext(
            before: String(before.suffix(80)),
            after: String(after.prefix(80)), selected: "")
        XCTAssertEqual(full, window)
        XCTAssertLessThanOrEqual(full.before!.utf16.count, ProxyDocumentContext.windowUTF16)
        XCTAssertLessThanOrEqual(full.after!.utf16.count, ProxyDocumentContext.windowUTF16)
    }

    func testChangesOnEitherSideOrInSelectionRemainExternal() {
        let before = String(repeating: "正文", count: 100)
        let after = String(repeating: "尾文", count: 100)
        let context = ProxyDocumentContext(before: before, after: after, selected: nil)
        XCTAssertNotEqual(context, ProxyDocumentContext(before: before + "移", after: after, selected: nil))
        XCTAssertNotEqual(context, ProxyDocumentContext(before: before, after: "移" + after, selected: nil))
        XCTAssertNotEqual(context, ProxyDocumentContext(before: before, after: after, selected: "正文"))
        XCTAssertNotEqual(context, ProxyDocumentContext(before: nil, after: after, selected: nil))
        XCTAssertNotEqual(
            context, ProxyDocumentContext(before: String(before.suffix(8)), after: after, selected: nil),
            "A shorter overlapping suffix does not prove the same insertion point")
    }

    func testEmojiAndCombiningCharactersAreNeverSplitOrReplacedByEmptyAnchors() {
        let unit = "👨‍👩‍👧‍👦𠮷e\u{301}"
        let value = String(repeating: unit, count: 10)
        let context = ProxyDocumentContext(before: value, after: value, selected: nil)
        XCTAssertTrue(value.hasSuffix(context.before!))
        XCTAssertTrue(value.hasPrefix(context.after!))
        XCTAssertFalse(context.before!.isEmpty)
        XCTAssertFalse(context.after!.isEmpty)
        let oversizedCharacter = "e" + String(repeating: "\u{301}", count: 64)
        let oversized = ProxyDocumentContext(
            before: "原文" + oversizedCharacter,
            after: oversizedCharacter + "尾文", selected: nil)
        XCTAssertEqual(oversized.before, oversizedCharacter)
        XCTAssertEqual(oversized.after, oversizedCharacter)
    }

    func testLongAndMultilineMarksKeepWholeTextOutsideInlineBudget() {
        for text in [
            String(repeating: "汉", count: 33), "第一行\n第二行", "第一行\r第二行",
            String(repeating: "👨‍👩‍👧‍👦", count: 10),
        ] {
            let mark = MarkedComposition(text: text)
            XCTAssertFalse(mark.isWithinProxyInlineBudget)
            XCTAssertEqual(mark.text, text)
            XCTAssertEqual(mark.selection.location, text.utf16.count)
        }
        XCTAssertTrue(MarkedComposition(text: String(repeating: "汉", count: 32)).isWithinProxyInlineBudget)
    }
}
