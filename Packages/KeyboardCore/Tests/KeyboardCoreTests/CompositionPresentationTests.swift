import XCTest

@testable import KeyboardCore

@MainActor
final class CompositionPresentationTests: XCTestCase {
    func testDefaultMarkPreservesSchemaPreeditInsteadOfUnselectedCandidate() {
        var snapshot = EngineSnapshot(
            candidates: [.init(index: 0, text: "你好")],
            preedit: "ni hao", isComposing: true)
        snapshot.rawInput = "nihao"
        snapshot.commitTextPreview = "你好"
        snapshot.preeditSelection = NSRange(location: 6, length: 0)
        let marked = MarkedComposition(snapshot: snapshot)
        XCTAssertEqual(marked.text, "ni hao")
        XCTAssertEqual(marked.selection, snapshot.preeditSelection)
        XCTAssertEqual(snapshot.candidates.first?.text, "你好")
        XCTAssertTrue(snapshot.committed.isEmpty)

        // Rime may explicitly select a segment while leaving the rest unconfirmed.
        snapshot.preedit = "你 hao"
        snapshot.preeditSelection = NSRange(location: 1, length: 4)
        XCTAssertEqual(MarkedComposition(snapshot: snapshot).text, "你 hao")
        XCTAssertEqual(MarkedComposition(snapshot: snapshot).selection, snapshot.preeditSelection)
    }

    func testTypingThenSelectingCommitsOnceAndCancellationDoesNotReplay() {
        let session = InputSession(engine: EngineProvider.makeDemoEngine(), layout: .qwerty26)
        var commits: [String] = []
        session.onCommitted = { commits.append($0) }
        for key in "nihao" { session.tap(.code(String(key))) }
        XCTAssertTrue(commits.isEmpty)
        XCTAssertEqual(MarkedComposition(snapshot: session.snapshot).text, session.snapshot.preedit)
        XCTAssertEqual(session.snapshot.candidates.first?.text, "你好")
        session.selectCandidate(0)
        XCTAssertEqual(commits, ["你好"])
        XCTAssertFalse(session.snapshot.isComposing)
        session.refresh()
        for key in "nihao" { session.tap(.code(String(key))) }
        XCTAssertTrue(session.discardComposition())
        XCTAssertFalse(session.snapshot.isComposing)
        XCTAssertEqual(commits, ["你好"])
    }

    func testWholeCompositionPreviewDoesNotUseOnlyCurrentCandidate() {
        var snapshot = EngineSnapshot(candidates: [.init(index: 0, text: "天气")], preedit: "tian qi", isComposing: true)
        snapshot.commitTextPreview = "今天的天气"
        let marked = MarkedComposition(snapshot: snapshot, chinesePreview: true)
        XCTAssertEqual(marked.text, "今天的天气")
        XCTAssertEqual(marked.selection, NSRange(location: 5, length: 0))
        XCTAssertFalse(marked.isEchoed(before: nil, after: nil, selectedText: nil))
        XCTAssertFalse(marked.isEchoed(before: "天气", after: "", selectedText: nil))
        XCTAssertTrue(marked.isEchoed(before: "正文今天的天气", after: "", selectedText: nil))
    }

    func testUTF16CaretRequiresBothSidesOfCompleteComposition() {
        var snapshot = EngineSnapshot(preedit: "你😀好", isComposing: true)
        snapshot.preeditSelection = NSRange(location: 3, length: 0)
        let marked = MarkedComposition(snapshot: snapshot, chinesePreview: false)
        XCTAssertTrue(marked.isEchoed(before: "正文你😀", after: "好尾文", selectedText: nil))
        XCTAssertFalse(marked.isEchoed(before: "正文你😀", after: nil, selectedText: nil))
        XCTAssertFalse(marked.isEchoed(before: "正文你", after: "好尾文", selectedText: nil))
    }

    func testSelectionMustAlsoEchoAndInvalidOffsetsAreRejected() {
        var snapshot = EngineSnapshot(preedit: "你😀好", isComposing: true)
        snapshot.preeditSelection = NSRange(location: 1, length: 2)
        var marked = MarkedComposition(snapshot: snapshot, chinesePreview: false)
        XCTAssertTrue(marked.isEchoed(before: "你", after: "好", selectedText: "😀"))
        XCTAssertFalse(marked.isEchoed(before: "你", after: "好", selectedText: nil))
        snapshot.preeditSelection = NSRange(location: 100, length: 0)
        marked = MarkedComposition(snapshot: snapshot, chinesePreview: false)
        XCTAssertFalse(marked.isEchoed(before: "你😀好", after: "", selectedText: nil))
    }
}
