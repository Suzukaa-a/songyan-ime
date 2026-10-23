import XCTest

@testable import KeyboardCore

@MainActor
final class CompositionTransitionTests: XCTestCase {
    private final class Backend: EngineBackend {
        let base = EngineProvider.makeDemoEngine()
        var rejectConfirmation = false
        var rejectCancellation = false
        var rejectSchema = false
        var keepCompositionOnConfirm = false
        var schemaSelections = 0
        var cancellationCommit = ""
        var partialCommit = ""
        var candidateText: String?
        var failAfterSelection = false
        var inputUnavailableReason: String?
        var kind: EngineBackendKind { base.kind }
        var statusSummary: String { base.statusSummary }
        func setup(sharedDirectory: URL, userDirectory: URL) throws {}
        func validateSchema(_ schemaID: String) throws {
            if rejectSchema { throw EngineBackendError.unsupportedSchema(schemaID) }
        }
        func selectSchema(_ schemaID: String) throws {
            schemaSelections += 1
            try base.selectSchema(schemaID)
            if failAfterSelection {
                inputUnavailableReason = "restore failed; restart required"
                throw EngineBackendError.operationFailed(inputUnavailableReason!)
            }
        }
        func processKey(_ keyValue: String) throws -> EngineSnapshot {
            if keyValue == "Esc" {
                if rejectCancellation { throw EngineBackendError.operationFailed("cancel failed") }
                var state = try base.processKey(keyValue)
                state.committed = cancellationCommit
                return state
            }
            return decorated(try base.processKey(keyValue))
        }
        func selectCandidate(_ index: Int) throws -> EngineSnapshot {
            if rejectConfirmation { throw EngineBackendError.operationFailed("confirm failed") }
            if keepCompositionOnConfirm {
                var state = currentSnapshot()
                state.committed = partialCommit
                return state
            }
            var state = try base.selectCandidate(index)
            if let candidateText, !state.committed.isEmpty { state.committed = candidateText }
            return state
        }
        func nextPage() throws -> EngineSnapshot { try base.nextPage() }
        func previousPage() throws -> EngineSnapshot { try base.previousPage() }
        func currentSnapshot() -> EngineSnapshot { decorated(base.currentSnapshot()) }
        private func decorated(_ original: EngineSnapshot) -> EngineSnapshot {
            var state = original
            if let candidateText, state.isComposing {
                state.candidates = [.init(index: 0, text: candidateText)]
                state.highlightedIndex = 0
            }
            return state
        }
        func shutdown() { base.shutdown() }
    }

    func testComposing26To9AndBackCommitsExactlyOncePerTransition() throws {
        let engine = Backend()
        let session = InputSession(engine: engine, layout: .qwerty26)
        var commits: [String] = []
        session.onCommitted = { commits.append($0) }
        for key in "nihao" { session.tap(.code(String(key))) }
        let first = session.snapshot.candidates[0].text
        session.select(layout: .phone9)
        XCTAssertEqual(session.layout, .phone9)
        XCTAssertEqual(commits, [first])
        for key in "64426" { session.tap(.code(String(key))) }
        let second = session.snapshot.candidates[0].text
        session.select(layout: .qwerty26)
        XCTAssertEqual(commits, [first, second])
        XCTAssertFalse(session.snapshot.isComposing)
        session.select(layout: .qwerty26)
        XCTAssertEqual(commits.count, 2)
    }

    func testFailedOrPartialConfirmationAndUnknownSchemaKeepComposition() {
        let engine = Backend()
        let session = InputSession(engine: engine, layout: .qwerty26)
        var commits: [String] = []
        var errors = 0
        session.onCommitted = { commits.append($0) }
        session.onError = { _ in errors += 1 }
        session.tap(.code("n"))
        let raw = session.snapshot.rawInput
        engine.rejectSchema = true
        session.select(layout: .phone9)
        engine.rejectSchema = false
        engine.rejectConfirmation = true
        session.select(layout: .phone9)
        engine.rejectConfirmation = false
        engine.keepCompositionOnConfirm = true
        session.select(layout: .phone9)
        XCTAssertEqual(session.layout, .qwerty26)
        XCTAssertEqual(session.snapshot.rawInput, raw)
        XCTAssertTrue(session.snapshot.isComposing)
        XCTAssertEqual(engine.schemaSelections, 0)
        XCTAssertTrue(commits.isEmpty)
        XCTAssertEqual(errors, 3)
        XCTAssertNil(session.inputUnavailableReason)
        session.tap(.code("i"))
        XCTAssertEqual(session.snapshot.rawInput, "ni")
    }

    func testDiscardNeverCommitsAndFailureKeepsComposition() {
        let engine = Backend()
        let session = InputSession(engine: engine, layout: .qwerty26)
        var commits: [String] = []
        var errors = 0
        session.onCommitted = { commits.append($0) }
        session.onError = { _ in errors += 1 }
        XCTAssertTrue(session.discardComposition())
        session.tap(.code("n"))
        engine.rejectCancellation = true
        XCTAssertFalse(session.discardComposition())
        XCTAssertEqual(session.snapshot.rawInput, "n")
        XCTAssertTrue(session.snapshot.isComposing)
        XCTAssertEqual(errors, 1)
        engine.rejectCancellation = false
        engine.cancellationCommit = "must not reach document"
        XCTAssertTrue(session.discardComposition())
        XCTAssertFalse(session.snapshot.isComposing)
        XCTAssertTrue(session.snapshot.candidates.isEmpty)
        XCTAssertTrue(commits.isEmpty)
    }

    func testLiteralResultExcludesPartialCommitAndMissingOutlet() {
        let engine = Backend()
        let session = InputSession(engine: engine, layout: .qwerty26)
        XCTAssertFalse(session.insertLiteral("symbol"))
        var sent: [String] = []
        session.onDispatchCommit = {
            sent.append($0)
            return true
        }
        session.tap(.code("n"))
        engine.keepCompositionOnConfirm = true
        engine.partialCommit = "partial"
        XCTAssertFalse(session.insertLiteral("symbol"))
        XCTAssertEqual(sent, ["partial"])
        XCTAssertTrue(session.snapshot.isComposing)
        engine.keepCompositionOnConfirm = false
        XCTAssertTrue(session.insertLiteral("symbol"))
        XCTAssertEqual(sent.last, "symbol")
        session.onDispatchCommit = { _ in false }
        XCTAssertFalse(session.insertLiteral("unavailable"))
    }

    func testRejectedConfirmationStopsLiteralEvenWhenEngineEndsComposition() {
        let session = InputSession(engine: Backend(), layout: .qwerty26)
        session.tap(.code("n"))
        let candidate = session.snapshot.candidates[0].text
        var attempted: [String] = []
        session.onDispatchCommit = { text in
            attempted.append(text)
            // The first rejection may adopt a new host; later writes would succeed.
            return attempted.count > 1
        }
        XCTAssertFalse(session.insertLiteral("symbol"))
        XCTAssertEqual(attempted, [candidate])
        XCTAssertFalse(session.snapshot.isComposing)
    }

    func testRejectedConfirmationStopsCursorEvenWhenEngineEndsComposition() {
        let session = InputSession(engine: Backend(), layout: .qwerty26)
        session.tap(.code("n"))
        var attempted = 0
        var moves: [Int] = []
        session.onDispatchCommit = { _ in
            attempted += 1
            return false
        }
        session.onMoveCursor = { moves.append($0) }
        session.moveCursor(by: -1)
        XCTAssertEqual(attempted, 1)
        XCTAssertFalse(session.snapshot.isComposing)
        XCTAssertEqual(moves, [])
    }

    func testAcceptedConfirmationStillDeliversFollowingLiteralAndCursor() {
        let session = InputSession(engine: Backend(), layout: .qwerty26)
        var attempted: [String] = []
        var moves: [Int] = []
        session.onDispatchCommit = {
            attempted.append($0)
            return true
        }
        session.onMoveCursor = { moves.append($0) }
        session.tap(.code("n"))
        XCTAssertTrue(session.insertLiteral("symbol"))
        XCTAssertEqual(attempted.count, 2)
        XCTAssertEqual(attempted.last, "symbol")
        session.tap(.code("n"))
        session.moveCursor(by: -1)
        XCTAssertEqual(attempted.count, 3)
        XCTAssertEqual(moves, [-1])
    }

    func testFailedRollbackRefreshesActualSchemaWithoutReplayingCommitAndDisablesInput() {
        let engine = Backend()
        let session = InputSession(engine: engine, layout: .qwerty26)
        var sent: [String] = []
        session.onDispatchCommit = {
            sent.append($0)
            return true
        }
        session.tap(.code("n"))
        engine.failAfterSelection = true
        session.select(layout: .phone9)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(session.selectedSchemaID, engine.currentSnapshot().schemaID)
        XCTAssertEqual(session.layout, .qwerty26)
        XCTAssertNotNil(session.inputUnavailableReason)
        session.refresh()
        session.tap(.code("a"))
        XCTAssertFalse(session.insertLiteral("symbol"))
        XCTAssertEqual(sent.count, 1)
    }

    func testMultiCharacterLiteralKeepsWholePayloadAndSubsequentDecoding() {
        let session = InputSession(engine: Backend(), layout: .qwerty26)
        var commits: [String] = []
        session.onDispatchCommit = {
            commits.append($0)
            return true
        }
        let payloads = [
            "一次性输入多个中文字", "𠮷👨‍👩‍👧‍👦👍🏽🇨🇳e\u{301}",
            "第一行\n第二行\r\n第三行\t末尾",
            String(repeating: "长中文𠮷👩🏽‍💻e\u{301}\n", count: 2048),
        ]
        for payload in payloads {
            let countBefore = commits.count
            XCTAssertTrue(session.insertLiteral(payload))
            XCTAssertEqual(commits.count, countBefore + 1, "one whole payload, not a per-key loop")
            XCTAssertEqual(Array(commits.last!.utf8), Array(payload.utf8))
            XCTAssertFalse(session.snapshot.isComposing)
            for key in "nihao" { session.tap(.code(String(key))) }
            XCTAssertEqual(session.snapshot.rawInput, "nihao")
            XCTAssertEqual(session.snapshot.candidates.first?.text, "你好")
            XCTAssertTrue(session.commitComposition())
            XCTAssertEqual(commits.last, "你好")
        }
        XCTAssertNil(session.inputUnavailableReason)
    }

    func testLongChineseCandidateIsDeliveredWholeAndDoesNotLockNextWord() {
        let engine = Backend()
        let phrase = String(repeating: "长中文候选不能截断𠮷", count: 1024) + "👩🏽‍💻e\u{301}"
        engine.candidateText = phrase
        let session = InputSession(engine: engine, layout: .qwerty26)
        var commits: [String] = []
        session.onDispatchCommit = {
            commits.append($0)
            return true
        }
        for key in "nihao" { session.tap(.code(String(key))) }
        XCTAssertEqual(session.snapshot.candidates.first?.text, phrase)
        XCTAssertTrue(session.commitComposition())
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(Array(commits[0].utf8), Array(phrase.utf8))
        session.refresh()
        XCTAssertEqual(commits.count, 1, "refresh must not replay the long commit")
        engine.candidateText = nil
        for key in "ni" { session.tap(.code(String(key))) }
        XCTAssertEqual(session.snapshot.rawInput, "ni")
        XCTAssertTrue(session.commitComposition())
        XCTAssertEqual(commits.count, 2)
        XCTAssertFalse(session.snapshot.isComposing)
    }

    func testPartialUnicodeCommitPreservesRemainingInputAndAllowsContinuation() {
        let engine = Backend()
        let session = InputSession(engine: engine, layout: .qwerty26)
        var commits: [String] = []
        session.onDispatchCommit = {
            commits.append($0)
            return true
        }
        session.tap(.code("n"))
        engine.keepCompositionOnConfirm = true
        engine.partialCommit = String(repeating: "部分确认𠮷👨‍👩‍👧‍👦", count: 32)
        XCTAssertFalse(session.insertLiteral("不得提前插入\n👩🏽‍💻"))
        XCTAssertEqual(commits, [engine.partialCommit])
        XCTAssertTrue(session.snapshot.isComposing)
        XCTAssertEqual(session.snapshot.rawInput, "n")
        for key in "ihao" { session.tap(.code(String(key))) }
        XCTAssertEqual(session.snapshot.rawInput, "nihao")
        engine.keepCompositionOnConfirm = false
        XCTAssertTrue(session.commitComposition())
        XCTAssertEqual(commits, [engine.partialCommit, "你好"])
        session.tap(.code("n"))
        session.tap(.code("i"))
        XCTAssertTrue(session.snapshot.isComposing)
        XCTAssertEqual(session.snapshot.rawInput, "ni")
    }

    func testRepeatedPinyinConfirmationNeverDropsOrReplaysCommittedWords() {
        let session = InputSession(engine: Backend(), layout: .qwerty26)
        var document = "原文𠮷👨‍👩‍👧‍👦\n"
        var expected = document
        session.onDispatchCommit = {
            document += $0
            return true
        }
        for _ in 0..<128 {
            for key in "nihao" { session.tap(.code(String(key))) }
            XCTAssertEqual(session.snapshot.rawInput, "nihao")
            XCTAssertEqual(session.snapshot.candidates.first?.text, "你好")
            XCTAssertTrue(session.commitComposition())
            expected += "你好"
            session.refresh()
            XCTAssertEqual(Array(document.utf8), Array(expected.utf8))
            XCTAssertFalse(session.snapshot.isComposing)
        }
    }

    func testSameSchemaMenuNoopAndExplicitRevalidationAreDistinct() {
        let engine = Backend()
        let session = InputSession(engine: engine, layout: .qwerty26)
        session.selectSchema(session.selectedSchemaID)
        XCTAssertEqual(engine.schemaSelections, 0)
        session.revalidateCurrentSchema()
        XCTAssertEqual(engine.schemaSelections, 1)
    }
}
