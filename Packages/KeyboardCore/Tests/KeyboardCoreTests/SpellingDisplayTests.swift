import XCTest

@testable import KeyboardCore

/// The display path must trust only engine evidence: the composition's highlighted
/// byte range plus the highlighted candidate's decoded spelling. These tests pin the
/// counterexamples the earlier last-CJK heuristic got wrong (dropped tail / punctuation,
/// caret forced to the end) and the exact fallback when evidence is missing or invalid.
final class SpellingDisplayTests: XCTestCase {

    // MARK: - Range rewrite

    func testReplacesOnlyTheEvidencedSegment() {
        // 14-key merged "bu" -> highlighted 你 is spelled "ni".
        XCTAssertEqual(rewrite("bu", 0, 2, 2, "ni").text, "ni")
        XCTAssertEqual(rewrite("64", 0, 2, 2, "ni").text, "ni")
        XCTAssertEqual(rewrite("bu g c", 0, 6, 6, "bu gou cheng").text, "bu gou cheng")
    }

    func testTailCodeAfterTheHighlightedSegmentIsPreserved() {
        // Counterexample: preedit "bu gc" with the highlighted candidate covering only "bu".
        // The old last-CJK split produced "ni" and dropped " gc"; the engine range keeps it.
        let result = rewrite("bu gc", 0, 2, 2, "ni")
        XCTAssertEqual(result.text, "ni gc")
        XCTAssertEqual(result.caret, ("ni" as NSString).length)  // caret stays after the typed code
    }

    func testConfirmedTextAndPunctuationBeforeTheSegmentArePreserved() {
        // Counterexample: "你，gc" with only the trailing raw "gc" unconfirmed ->
        // must become "你，hao", never "你hao".
        let preedit = "你，gc"
        let start = "你，".utf8.count  // 6
        let end = preedit.utf8.count  // 8
        let result = rewrite(preedit, start, end, end, "hao")
        XCTAssertEqual(result.text, "你，hao")
        XCTAssertEqual(
            result.text.utf16.count,
            ("你，hao" as NSString).length)
    }

    func testSegmentedConfirmedPrefixIsPreserved() {
        // librime: converted segments contribute their Chinese text, the highlighted one its code.
        XCTAssertEqual(rewrite("你hao", 3, 6, 6, "hao").text, "你hao")
        XCTAssertEqual(rewrite("你好shij", 6, 10, 10, "shi jian").text, "你好shi jian")
    }

    // MARK: - Caret remapping (mid selection)

    func testCaretBeforeTheSegmentIsUnchanged() {
        XCTAssertEqual(rewrite("bu gc", 0, 2, 0, "ni").caret, 0)
    }

    func testCaretInTheTailShiftsByTheDelta() {
        // "bu"(2) -> "ni hao"(6): delta +4. A caret at byte 4 ("g" of the tail) becomes 8.
        let result = rewrite("bu gc", 0, 2, 4, "ni hao")
        XCTAssertEqual(result.text, "ni hao gc")
        XCTAssertEqual(result.caret, 8)
    }

    func testCaretInsideTheSegmentMovesToItsEnd() {
        // Mid selection inside the replaced span is not silently kept inside the new spelling.
        XCTAssertEqual(rewrite("bu gc", 0, 2, 1, "ni hao").caret, 6)
    }

    func testMultibyteCaretMapsThroughUTF16() {
        // Covered span is multi-byte CJK; the caret sits after it and shifts correctly.
        let result = rewrite("你好x", "你好".utf8.count, "你好x".utf8.count, "你好x".utf8.count, "hao")
        XCTAssertEqual(result.text, "你好hao")
        XCTAssertEqual(result.caret, ("你好hao" as NSString).length)
    }

    // MARK: - Precise fallback

    func testInvalidRangesReturnNilAndFallBackToRawPreedit() {
        XCTAssertNil(SpellingDisplay.rewrite(preedit: "bu", selStart: 2, selEnd: 1, caretByte: 2, spelling: "ni"))
        XCTAssertNil(SpellingDisplay.rewrite(preedit: "bu", selStart: 0, selEnd: 9, caretByte: 2, spelling: "ni"))
        XCTAssertNil(SpellingDisplay.rewrite(preedit: "bu", selStart: -1, selEnd: 2, caretByte: 2, spelling: "ni"))
        XCTAssertNil(SpellingDisplay.rewrite(preedit: "bu", selStart: 0, selEnd: 2, caretByte: 9, spelling: "ni"))
        // A byte offset inside a multi-byte scalar is not a character boundary.
        XCTAssertNil(SpellingDisplay.rewrite(preedit: "你好", selStart: 1, selEnd: 6, caretByte: 6, spelling: "ni"))
    }

    func testMarkedCompositionFallsBackWhenNoTrustedSpelling() {
        var snapshot = EngineSnapshot(
            candidates: [Candidate(index: 0, text: "你", comment: "［ni］")],
            preedit: "bu", rawInput: "bu", isComposing: true)
        snapshot.highlightedSpelling = ""  // engine offered no decode
        snapshot.preeditSelStart = 0
        snapshot.preeditSelEnd = 2
        snapshot.preeditCaretByte = 2
        snapshot.preeditSelection = NSRange(location: 2, length: 0)
        let marked = MarkedComposition(snapshot: snapshot, spellingPreedit: true)
        XCTAssertEqual(marked.text, "bu")  // raw preedit preserved
        XCTAssertEqual(marked.selection, NSRange(location: 2, length: 0))

        // The comment must never be parsed as pinyin: a polluted comment changes nothing.
        snapshot.highlightedSpelling = ""
        var polluted = snapshot
        polluted.candidates = [Candidate(index: 0, text: "你", comment: "英语 hello 你好")]
        XCTAssertEqual(MarkedComposition(snapshot: polluted, spellingPreedit: true).text, "bu")
    }

    // MARK: - Using the engine evidence

    func testFourteenAndNineKeyMarkedTextFollowTheCandidate() {
        var snapshot = EngineSnapshot(
            candidates: [Candidate(index: 0, text: "你")],
            preedit: "bu", rawInput: "bu", isComposing: true)
        snapshot.highlightedSpelling = "ni"
        snapshot.preeditSelStart = 0
        snapshot.preeditSelEnd = 2
        snapshot.preeditCaretByte = 2
        snapshot.preeditSelection = NSRange(location: 2, length: 0)
        XCTAssertEqual(MarkedComposition(snapshot: snapshot, spellingPreedit: true).text, "ni")
        XCTAssertEqual(
            MarkedComposition(snapshot: snapshot, spellingPreedit: true).selection,
            NSRange(location: 2, length: 0))

        var nineKey = snapshot
        nineKey.preedit = "64"
        nineKey.rawInput = "64"
        nineKey.preeditSelStart = 0
        nineKey.preeditSelEnd = 2
        XCTAssertEqual(MarkedComposition(snapshot: nineKey, spellingPreedit: true).text, "ni")
        // Raw engine state is untouched by presentation.
        XCTAssertEqual(nineKey.rawInput, "64")
        XCTAssertEqual(nineKey.preedit, "64")
    }

    func testTwentySixFullPinyinDoesNotUseTheSpellingPath() {
        var snapshot = EngineSnapshot(
            candidates: [Candidate(index: 0, text: "你好")],
            preedit: "ni hao", rawInput: "nihao", isComposing: true)
        snapshot.highlightedSpelling = "ni hao"
        snapshot.preeditSelStart = 0
        snapshot.preeditSelEnd = 6
        snapshot.preeditCaretByte = 6
        snapshot.preeditSelection = NSRange(location: 6, length: 0)
        XCTAssertEqual(MarkedComposition(snapshot: snapshot, spellingPreedit: false).text, "ni hao")
    }

    private func rewrite(_ preedit: String, _ start: Int, _ end: Int, _ caret: Int, _ spelling: String)
        -> (text: String, caret: Int)
    {
        guard
            let result = SpellingDisplay.rewrite(
                preedit: preedit, selStart: start, selEnd: end,
                caretByte: caret, spelling: spelling)
        else {
            return ("<nil>", -1)
        }
        return result
    }
}
