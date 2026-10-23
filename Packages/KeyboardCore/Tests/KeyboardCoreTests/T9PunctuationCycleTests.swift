import XCTest

@testable import KeyboardCore

final class T9PunctuationCycleTests: XCTestCase {
    private let symbols = ["，", "。", "？", "！", "、", "；", "：", "……"]

    func testRepeatedTapsReplaceAndWrapIncludingFullEllipsis() throws {
        var cycle = T9PunctuationCycle()
        var context = "正文"
        for index in 0...symbols.count {
            let edit = try XCTUnwrap(
                cycle.next(symbols: symbols, context: context, now: Double(index) * 0.1, revision: index))
            XCTAssertEqual(edit.text, symbols[index % symbols.count])
            if index > 0 {
                XCTAssertEqual(edit.replacing, symbols[(index - 1) % symbols.count])
                context.removeLast(edit.replacing!.count)
            } else {
                XCTAssertNil(edit.replacing)
            }
            context += edit.text
            cycle.record(edit, symbols: symbols, context: context, now: Double(index) * 0.1, revision: index + 1)
        }
        XCTAssertEqual(context, "正文，")
    }

    func testTimeoutCursorChangeUnknownContextAndOtherCommitStartFresh() throws {
        var cycle = T9PunctuationCycle()
        let edit = try XCTUnwrap(cycle.next(symbols: symbols, context: "正文", now: 1, revision: 0))
        cycle.record(edit, symbols: symbols, context: "正文，", now: 1, revision: 1)
        for (context, now, revision) in [
            ("正文，" as String?, 1.8, 1), ("其他，", 1.1, 1),
            (nil, 1.1, 1), ("正文，", 1.1, 2), ("正文，", 0.9, 1),
        ] {
            let fresh = try XCTUnwrap(cycle.next(symbols: symbols, context: context, now: now, revision: revision))
            XCTAssertEqual(fresh.text, "，")
            XCTAssertNil(fresh.replacing)
        }
    }

    func testWidthChangeResetAndFailedInsertNeverReplace() throws {
        var cycle = T9PunctuationCycle()
        let edit = try XCTUnwrap(cycle.next(symbols: symbols, context: "", now: 0, revision: 0))
        cycle.record(edit, symbols: symbols, context: "，", now: 0, revision: 1)
        XCTAssertNil(cycle.next(symbols: [",", ".", "?"], context: "，", now: 0.1, revision: 1)?.replacing)
        cycle.reset()
        XCTAssertNil(cycle.next(symbols: symbols, context: "，", now: 0.1, revision: 1)?.replacing)
        cycle.record(edit, symbols: symbols, context: "not inserted", now: 0, revision: 1)
        XCTAssertNil(cycle.next(symbols: symbols, context: "，", now: 0.1, revision: 1)?.replacing)
        XCTAssertNil(cycle.next(symbols: [], context: "", now: 0, revision: 0))
    }

    func testUnchangedOrUnverifiedHostReceiptNeverArmsReplacement() throws {
        for before in ["正文，" as String?, nil, String(repeating: "，", count: 200)] {
            var cycle = T9PunctuationCycle()
            let edit = try XCTUnwrap(cycle.next(symbols: symbols, context: before, now: 0, revision: 0))
            let after = before ?? "原有，"
            cycle.record(edit, symbols: symbols, context: after, now: 0, revision: 1)
            XCTAssertNil(cycle.next(symbols: symbols, context: after, now: 0.1, revision: 1)?.replacing)
        }
    }

    func testContextIsBoundedWithoutSplittingEmoji() throws {
        var cycle = T9PunctuationCycle()
        let text = String(repeating: "👩🏽‍💻", count: 200) + "，"
        let edit = try XCTUnwrap(cycle.next(symbols: symbols, context: String(text.dropLast()), now: 0, revision: 0))
        cycle.record(edit, symbols: symbols, context: text, now: 0, revision: 1)
        let next = try XCTUnwrap(cycle.next(symbols: symbols, context: text, now: 0.1, revision: 1))
        XCTAssertEqual(next.expectedContext?.count, T9PunctuationCycle.contextLimit)
        XCTAssertEqual(next.replacing, "，")
    }

    /// The document context read right after an extension write is often the stale pre-write value; the next tap should still cycle.
    func testStaleReceiptArmsWhenNextTapSeesTheWrite() throws {
        var cycle = T9PunctuationCycle()
        let edit = try XCTUnwrap(cycle.next(symbols: symbols, context: "正文", now: 0, revision: 0))
        cycle.record(edit, symbols: symbols, context: "正文", now: 0, revision: 1)
        let next = try XCTUnwrap(cycle.next(symbols: symbols, context: "正文，", now: 0.3, revision: 1))
        XCTAssertEqual(next.replacing, "，")
        XCTAssertEqual(next.text, "。")
        cycle.record(next, symbols: symbols, context: "正文，", now: 0.3, revision: 2)
        let third = try XCTUnwrap(cycle.next(symbols: symbols, context: "正文。", now: 0.6, revision: 2))
        XCTAssertEqual(third.replacing, "。")
        XCTAssertEqual(third.text, "？")
    }

    /// Empty field: the controller reads a nil context as "", so the first tap on the first key can start cycling.
    func testEmptyFieldArmsOnTheFirstTap() throws {
        var cycle = T9PunctuationCycle()
        let edit = try XCTUnwrap(cycle.next(symbols: symbols, context: "", now: 0, revision: 0))
        cycle.record(edit, symbols: symbols, context: "", now: 0, revision: 1)
        let next = try XCTUnwrap(cycle.next(symbols: symbols, context: "，", now: 0.3, revision: 1))
        XCTAssertEqual(next.replacing, "，")
        XCTAssertEqual(next.text, "。")
    }
}
