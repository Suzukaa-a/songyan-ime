import XCTest

@testable import KeyboardCore

/// Long ambiguous compositions decode code keys on the engine queue; every other
/// action still sees exactly the composition a synchronous engine would have had.
@MainActor
final class DeferredCodeKeyTests: XCTestCase {
    private final class SlowEngine: EngineBackend {
        let kind: EngineBackendKind = .demoSimulator("slow-decode-test")
        var decodeDelay: TimeInterval = 0
        private let lock = NSLock()
        private var input = ""
        private(set) var processed: [String] = []

        func setup(sharedDirectory: URL, userDirectory: URL) throws {}
        func selectSchema(_ schemaID: String) throws {}
        func processKey(_ keyValue: String) throws -> EngineSnapshot {
            lock.lock()
            defer { lock.unlock() }
            processed.append(keyValue)
            var committed = ""
            switch keyValue {
            case "\u{08}": if !input.isEmpty { input.removeLast() }
            case " ":
                committed = input
                input = ""
            default:
                input += keyValue
                if decodeDelay > 0 { Thread.sleep(forTimeInterval: decodeDelay) }
            }
            var snapshot = state()
            snapshot.committed = committed
            return snapshot
        }
        private(set) var selections: [Int] = []
        func selectCandidate(_ index: Int) throws -> EngineSnapshot {
            selections.append(index)
            return currentSnapshot()
        }
        func nextPage() throws -> EngineSnapshot { currentSnapshot() }
        func previousPage() throws -> EngineSnapshot { currentSnapshot() }
        func currentSnapshot() -> EngineSnapshot {
            lock.lock()
            defer { lock.unlock() }
            return state()
        }
        /// When > 0 the composition offers `menuCount` candidates in pages of `pageSize`.
        var pageSize = 0
        var menuCount = 0
        private(set) var candidateReads: [Range<Int>] = []
        private func menu() -> [Candidate] {
            (0..<menuCount).map { Candidate(index: $0, text: "\(input)-\($0)") }
        }
        private func state() -> EngineSnapshot {
            guard pageSize > 0, !input.isEmpty else {
                return EngineSnapshot(
                    candidates: input.isEmpty ? [] : [Candidate(index: 0, text: input)],
                    preedit: input, rawInput: input, isComposing: !input.isEmpty)
            }
            let all = menu()
            return EngineSnapshot(
                candidates: Array(all.prefix(pageSize)), preedit: input, rawInput: input,
                isComposing: true, pageSize: pageSize, isLastPage: all.count <= pageSize)
        }
        func readCandidates(fromIndex: Int, count: Int) throws -> [Candidate] {
            lock.lock()
            defer { lock.unlock() }
            candidateReads.append(fromIndex..<(fromIndex + count))
            return Array(menu().dropFirst(fromIndex).prefix(count))
        }
        func shutdown() {}
        var statusSummary: String { "slow" }
    }

    /// Holds work until the test runs it, like a busy serial engine queue.
    private final class ManualQueue: EngineWorkQueue {
        private(set) var queued: [@Sendable () -> Void] = []
        func async(_ work: @escaping @Sendable () -> Void) { queued.append(work) }
        func runAll() {
            while !queued.isEmpty { queued.removeFirst()() }
        }
    }

    private func makeSession(delay: TimeInterval) -> (InputSession, SlowEngine, ManualQueue) {
        let engine = SlowEngine()
        engine.decodeDelay = delay
        let session = InputSession(engine: engine, layout: .phone9)
        let queue = ManualQueue()
        session.codeKeyQueue = queue
        return (session, engine, queue)
    }

    /// The main-queue hop that applies a finished batch.
    private func deliverMainQueue() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    func testOnlyTheFirstKeyOfACompositionDecodesSynchronously() {
        let (session, engine, queue) = makeSession(delay: 0)
        session.tap(.code("6"))
        XCTAssertEqual(session.snapshot.rawInput, "6", "a new composition starts synchronously")
        XCTAssertTrue(queue.queued.isEmpty)
        session.tap(.code("4"))
        session.tap(.code("4"))
        XCTAssertEqual(session.snapshot.rawInput, "6", "even a fast decode stays off the main thread")
        XCTAssertEqual(session.pendingCodes, ["4", "4"])
        queue.runAll()
        deliverMainQueue()
        queue.runAll()
        deliverMainQueue()
        XCTAssertEqual(session.snapshot.rawInput, "644")
        XCTAssertTrue(session.pendingCodes.isEmpty)
        XCTAssertEqual(engine.processed, ["6", "4", "4"])
    }

    func testKeysTypedDuringADecodeGoInOneBatch() {
        let (session, engine, queue) = makeSession(delay: 0.03)
        session.tap(.code("6"))  // starts the composition synchronously
        XCTAssertEqual(session.snapshot.rawInput, "6")
        session.tap(.code("4"))  // composing: decodes off the main thread
        XCTAssertEqual(session.snapshot.rawInput, "6", "the snapshot waits for the engine")
        XCTAssertEqual(session.pendingCodes, ["4"])
        session.tap(.code("2"))
        session.tap(.code("6"))
        XCTAssertEqual(session.pendingCodes, ["4", "2", "6"], "keys typed meanwhile wait in order")

        queue.runAll()
        deliverMainQueue()
        XCTAssertEqual(session.snapshot.rawInput, "64")
        XCTAssertEqual(session.pendingCodes, ["2", "6"])
        XCTAssertEqual(queue.queued.count, 1, "the keys typed meanwhile go in one batch")

        queue.runAll()
        deliverMainQueue()
        XCTAssertEqual(session.snapshot.rawInput, "6426")
        XCTAssertTrue(session.pendingCodes.isEmpty)
        XCTAssertEqual(engine.processed, ["6", "4", "2", "6"])
    }

    func testABatchReadsTheNextPagesWithItsDecode() {
        let (session, engine, queue) = makeSession(delay: 0)
        engine.pageSize = 2
        engine.menuCount = 5
        session.codeBatchLookaheadPages = 2
        var seen: [(rawInput: String, pageSize: Int, candidates: [Candidate])?] = []
        session.onUpdate = { seen.append(session.candidateLookahead) }
        session.tap(.code("6"))  // synchronous: no lookahead
        XCTAssertNil(seen.last ?? nil)
        session.tap(.code("4"))
        queue.runAll()
        deliverMainQueue()
        XCTAssertEqual(session.snapshot.rawInput, "64")
        XCTAssertEqual(engine.candidateReads, [2..<6], "the pages after the first, in the decode's hop")
        let lookahead = seen.last ?? nil
        XCTAssertEqual(lookahead?.rawInput, "64")
        XCTAssertEqual(lookahead?.pageSize, 2)
        XCTAssertEqual(lookahead?.candidates.map(\.text), ["64-2", "64-3", "64-4"])
        XCTAssertNil(session.candidateLookahead, "only visible while the batch's update runs")
    }

    func testOtherActionsDrainDeferredKeysFirst() {
        let (session, engine, _) = makeSession(delay: 0.03)
        var committed: [String] = []
        session.onCommitted = { committed.append($0) }
        session.tap(.code("6"))
        session.tap(.code("4"))
        session.tap(.code("2"))
        XCTAssertEqual(session.pendingCodes, ["4", "2"])
        session.tap(.space)
        XCTAssertEqual(engine.processed, ["6", "4", "2", " "], "space reaches the engine after every typed key")
        XCTAssertEqual(committed, ["642"])
        XCTAssertTrue(session.pendingCodes.isEmpty)
        deliverMainQueue()
        XCTAssertEqual(committed, ["642"], "the batch's late main-queue hop applies nothing twice")
        XCTAssertFalse(session.snapshot.isComposing)
    }

    func testBackspaceTakesBackAKeyTheEngineHasNotSeen() {
        let (session, engine, queue) = makeSession(delay: 0.03)
        session.tap(.code("6"))
        session.tap(.code("4"))  // decoding
        session.tap(.code("2"))  // waiting
        let revision = session.pendingCodesRevision
        XCTAssertTrue(session.removeLastPendingCode())
        XCTAssertEqual(session.pendingCodes, ["4"])
        XCTAssertNotEqual(session.pendingCodesRevision, revision, "the removal is an effect")
        XCTAssertFalse(session.removeLastPendingCode(), "a key already decoding goes through the engine")
        queue.runAll()
        deliverMainQueue()
        XCTAssertEqual(session.snapshot.rawInput, "64")
        XCTAssertEqual(engine.processed, ["6", "4"])
    }

    func testCandidateTappedDuringDecodingIsFoundAgainOrNotSelected() {
        let (session, engine, _) = makeSession(delay: 0.03)
        session.tap(.code("6"))
        session.tap(.code("4"))
        XCTAssertEqual(session.snapshot.candidates.first?.text, "6", "the list on screen")
        session.selectCandidate(0)
        XCTAssertEqual(session.snapshot.rawInput, "64", "the deferred key landed first")
        XCTAssertTrue(engine.selections.isEmpty, "「6」 is gone; the 「64」 now in its place is not selected")
        session.selectCandidate(0)
        XCTAssertEqual(engine.selections, [0], "without deferred keys the tap selects as before")
    }

    func testCancelDropsDeferredKeysBeforeTheEngineSeesThem() {
        let (session, engine, queue) = makeSession(delay: 0.03)
        session.tap(.code("6"))
        session.tap(.code("4"))
        session.tap(.code("2"))
        session.cancelPendingCodes()
        XCTAssertTrue(session.pendingCodes.isEmpty)
        queue.runAll()  // the queued batch starts after the cancel
        deliverMainQueue()
        XCTAssertEqual(engine.processed, ["6"], "no cancelled key reaches the engine")
        XCTAssertEqual(session.snapshot.rawInput, "6")
    }

    func testDrainTakesBackABatchTheQueueHasNotStarted() {
        let (session, engine, queue) = makeSession(delay: 0.03)
        session.tap(.code("6"))
        session.tap(.code("4"))  // queued behind other engine work
        session.nextPage()  // drains without waiting for that queue
        XCTAssertEqual(engine.processed, ["6", "4"])
        XCTAssertEqual(session.snapshot.rawInput, "64")
        queue.runAll()
        deliverMainQueue()
        XCTAssertEqual(engine.processed, ["6", "4"], "the taken-back batch never runs")
    }
}
