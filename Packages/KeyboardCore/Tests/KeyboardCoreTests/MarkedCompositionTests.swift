import XCTest

@testable import KeyboardCore

/// Multi-character regressions compare complete values. A limited document proxy
/// context is visibility evidence only, not proof that the document was truncated.
final class MarkedCompositionTests: XCTestCase {
    private let unit = "汉𠮷👨‍👩‍👧‍👦👍🏽🇨🇳e\u{301}\n"

    func testLongUnicodeMarkKeepsBytesAndUsesUTF16Caret() {
        let text = String(repeating: unit, count: 512)
        XCTAssertNotEqual(text.count, text.utf16.count)
        XCTAssertNotEqual(text.utf16.count, text.utf8.count)
        let marked = MarkedComposition(text: text)
        XCTAssertEqual(Array(marked.text.utf8), Array(text.utf8))
        XCTAssertEqual(marked.selection, NSRange(location: text.utf16.count, length: 0))
        XCTAssertTrue(marked.isEchoed(before: "正文" + text, after: "尾文", selectedText: nil))
    }

    func testLongWholeCompositionPreviewDoesNotBecomeLastCandidate() {
        let whole = String(repeating: "已经确认的长中文候选𠮷", count: 256) + unit
        var snapshot = EngineSnapshot(
            candidates: [.init(index: 0, text: "尾词")],
            preedit: "wei ci", rawInput: "weici", isComposing: true)
        snapshot.commitTextPreview = whole
        let marked = MarkedComposition(snapshot: snapshot, chinesePreview: true)
        XCTAssertEqual(Array(marked.text.utf8), Array(whole.utf8))
        XCTAssertEqual(marked.selection.location, whole.utf16.count)
        XCTAssertEqual(snapshot.rawInput, "weici")
        XCTAssertEqual(snapshot.candidates[0].text, "尾词")
    }

    func testUntranslatedExactTokenFallsBackToItsLetter() {
        var snapshot = EngineSnapshot(candidates: [], preedit: ">", rawInput: ">", isComposing: true)
        snapshot.preeditSelection = NSRange(location: 1, length: 0)
        let marked = MarkedComposition(snapshot: snapshot, exactLetters: [">": "d"])
        XCTAssertEqual(marked.text, "d")
        XCTAssertEqual(marked.selection, snapshot.preeditSelection)
        XCTAssertEqual(MarkedComposition(snapshot: snapshot).text, ">")
    }

    func testLimitedOrLineOnlyProxyContextDoesNotMutateCompleteMark() {
        let text = String(repeating: unit, count: 256) + "最后一行"
        let marked = MarkedComposition(text: text)
        let document = "原有正文\n" + text + "尾文"
        XCTAssertFalse(marked.isEchoed(before: String(text.suffix(50)), after: "尾文", selectedText: nil))
        XCTAssertFalse(marked.isEchoed(before: "最后一行", after: "尾文", selectedText: nil))
        XCTAssertFalse(marked.isEchoed(before: nil, after: nil, selectedText: nil))
        XCTAssertEqual(marked.text, text)
        XCTAssertEqual(document, "原有正文\n" + marked.text + "尾文")
        XCTAssertTrue(marked.isEchoed(before: "原有正文\n" + text, after: "尾文", selectedText: nil))
    }

    func testUTF8SegmentRewriteKeepsLongConfirmedPrefixEmojiAndTail() throws {
        let prefix = String(repeating: unit, count: 128)
        let code = "bu gc"
        let tail = "，未确认尾文👩🏽‍💻"
        let preedit = prefix + code + tail
        let result = try XCTUnwrap(
            SpellingDisplay.rewrite(
                preedit: preedit, selStart: prefix.utf8.count,
                selEnd: (prefix + code).utf8.count, caretByte: preedit.utf8.count,
                spelling: "ni hao"))
        XCTAssertEqual(Array(result.text.utf8), Array((prefix + "ni hao" + tail).utf8))
        XCTAssertEqual(result.caret, result.text.utf16.count)
        let inSegment = try XCTUnwrap(
            SpellingDisplay.rewrite(
                preedit: preedit, selStart: prefix.utf8.count,
                selEnd: (prefix + code).utf8.count, caretByte: prefix.utf8.count + 1,
                spelling: "ni hao"))
        XCTAssertEqual(inSegment.caret, (prefix + "ni hao").utf16.count)
    }

    func testEmojiSelectionEchoUsesUTF16WithoutDroppingSurroundingText() {
        let prefix = String(repeating: "你𠮷", count: 128)
        let selected = "👨‍👩‍👧‍👦👍🏽e\u{301}"
        let suffix = "后续文字\n第二行"
        var snapshot = EngineSnapshot(preedit: prefix + selected + suffix, isComposing: true)
        snapshot.preeditSelection = NSRange(location: prefix.utf16.count, length: selected.utf16.count)
        let mark = MarkedComposition(snapshot: snapshot)
        XCTAssertTrue(mark.isEchoed(before: "正文" + prefix, after: suffix + "尾文", selectedText: selected))
        XCTAssertFalse(mark.isEchoed(before: prefix, after: suffix, selectedText: "👨"))
        XCTAssertEqual(mark.text, prefix + selected + suffix)
    }

    func testInvalidByteBoundaryFallsBackToFullNativeText() {
        let preedit = "𠮷👩🏽‍💻你好bu gc尾文"
        var snapshot = EngineSnapshot(preedit: preedit, rawInput: "bugc", isComposing: true)
        snapshot.preeditSelection = NSRange(location: preedit.utf16.count, length: 0)
        snapshot.highlightedSpelling = "ni hao"
        snapshot.preeditSelStart = 1  // inside the four-byte CJK scalar
        snapshot.preeditSelEnd = preedit.utf8.count
        snapshot.preeditCaretByte = preedit.utf8.count
        let mark = MarkedComposition(snapshot: snapshot, spellingPreedit: true)
        XCTAssertEqual(Array(mark.text.utf8), Array(preedit.utf8))
        XCTAssertEqual(mark.selection, snapshot.preeditSelection)
    }
}
