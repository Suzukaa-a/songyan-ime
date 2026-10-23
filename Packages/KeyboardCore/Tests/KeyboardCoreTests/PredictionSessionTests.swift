import XCTest

@testable import KeyboardCore

/// Post-commit prediction (`EngineSnapshot.isPrediction`): candidates the engine offers with
/// no input code, whatever produced them. The session must let them be selected (and chain),
/// never confirm one implicitly, and give every other key its idle meaning.
@MainActor
final class PredictionSessionTests: XCTestCase {

    /// Model of librime + a prediction component: committing a word opens an empty-input
    /// candidate list; Esc closes it without committing.
    private final class PredictingEngine: EngineBackend {
        let kind: EngineBackendKind = .demoSimulator("predicting")
        var statusSummary: String { "predicting" }
        private let next: [String: [String]] = ["你": ["好", "们"], "好": ["的"]]
        private var input = ""
        private var predictions: [String] = []
        var escapes = 0

        func setup(sharedDirectory: URL, userDirectory: URL) throws {}
        func selectSchema(_ schemaID: String) throws {}
        func processKey(_ keyValue: String) throws -> EngineSnapshot {
            if keyValue == "Esc" {
                escapes += 1
                input = ""
                predictions = []
                return currentSnapshot()
            }
            if keyValue == " " || keyValue == "\n" || keyValue == "\u{08}" {
                // Real librime releases these to the host when nothing is composing.
                guard !input.isEmpty else { return currentSnapshot() }
                if keyValue == "\u{08}" {
                    input.removeLast()
                    return currentSnapshot()
                }
                return commit("你")
            }
            predictions = []
            input.append(keyValue)
            return currentSnapshot()
        }
        func selectCandidate(_ index: Int) throws -> EngineSnapshot {
            if !predictions.isEmpty { return commit(predictions[index]) }
            return commit("你")
        }
        func selectCandidateAbsolute(_ index: Int) throws -> EngineSnapshot { try selectCandidate(index) }
        private func commit(_ text: String) -> EngineSnapshot {
            input = ""
            predictions = next[text] ?? []
            var snapshot = currentSnapshot()
            snapshot.committed = text
            return snapshot
        }
        func nextPage() throws -> EngineSnapshot { currentSnapshot() }
        func previousPage() throws -> EngineSnapshot { currentSnapshot() }
        func currentSnapshot() -> EngineSnapshot {
            if !predictions.isEmpty {
                var snapshot = EngineSnapshot(
                    candidates: predictions.enumerated().map { Candidate(index: $0.offset, text: $0.element) },
                    preedit: "", rawInput: "", isComposing: false)
                snapshot.isPrediction = true
                return snapshot
            }
            return EngineSnapshot(
                candidates: input.isEmpty ? [] : [Candidate(index: 0, text: "你")],
                preedit: input, rawInput: input, isComposing: !input.isEmpty)
        }
        func shutdown() {}
    }

    private func typedNi() -> (InputSession, PredictingEngine, () -> [String]) {
        let engine = PredictingEngine()
        let session = InputSession(engine: engine, layout: .qwerty26)
        var commits: [String] = []
        session.onCommitted = { commits.append($0) }
        session.tap(.code("n"))
        session.tap(.code("i"))
        session.tap(.space)
        return (session, engine, { commits })
    }

    func testPredictionIsSelectableAndChains() {
        let (session, _, commits) = typedNi()
        XCTAssertEqual(commits(), ["你"])
        XCTAssertTrue(session.snapshot.isPrediction)
        XCTAssertFalse(session.snapshot.isComposing, "a prediction never becomes marked text")
        XCTAssertEqual(session.snapshot.preedit, "")
        XCTAssertEqual(session.confirmCandidateAbsolute(0), .completed)
        XCTAssertEqual(commits(), ["你", "好"])
        XCTAssertTrue(session.snapshot.isPrediction)
        XCTAssertEqual(session.snapshot.candidates.map(\.text), ["的"])
    }

    func testConfirmOnlyDismissesAndNeverPicksAPrediction() {
        let (session, engine, commits) = typedNi()
        XCTAssertTrue(session.commitComposition())
        XCTAssertEqual(commits(), ["你"], "confirming must not commit a prediction")
        XCTAssertFalse(session.snapshot.isPrediction)
        XCTAssertEqual(engine.escapes, 1)
    }

    func testLiteralInsertClosesPredictionThenInserts() {
        let (session, _, commits) = typedNi()
        XCTAssertTrue(session.insertLiteral(" "))
        XCTAssertEqual(commits(), ["你", " "])
        XCTAssertFalse(session.snapshot.isPrediction)
    }

    func testSwitchingToABCKeepsPredictionsSelectable() {
        let (session, engine, commits) = typedNi()
        var updates = 0
        session.onUpdate = { updates += 1 }
        session.setMode(.english)
        XCTAssertGreaterThan(updates, 0, "the page switch is published")
        XCTAssertEqual(session.mode, .english)
        XCTAssertTrue(session.snapshot.isPrediction, "predictions survive the switch to ABC")
        XCTAssertEqual(engine.escapes, 0, "switching pages never dismisses or picks a prediction")
        let slots = ABCSuggestionSlots.enginePredictions(session.snapshot, limit: 3)
        XCTAssertEqual(slots.map(\.text), ["好", "们"])
        session.selectCandidate(slots[0].index)
        XCTAssertEqual(commits(), ["你", "好"])
        XCTAssertEqual(ABCSuggestionSlots.enginePredictions(session.snapshot, limit: 3).map(\.text), ["的"])
        // A letter typed on ABC closes the predictions first, then goes to the host as is.
        session.tap(.code("a"))
        XCTAssertFalse(session.snapshot.isPrediction)
        XCTAssertEqual(commits(), ["你", "好", "a"])
    }

    func testABCSlotsAreDistinctAndOnlyForPredictions() {
        var snapshot = EngineSnapshot(
            candidates: ["的", "", "的", "了", "是", "在"].enumerated().map { Candidate(index: $0.offset, text: $0.element) }
        )
        XCTAssertTrue(
            ABCSuggestionSlots.enginePredictions(snapshot, limit: 3).isEmpty, "ordinary candidates are not predictions")
        snapshot.isPrediction = true
        let slots = ABCSuggestionSlots.enginePredictions(snapshot, limit: 3)
        XCTAssertEqual(slots.map(\.text), ["的", "了", "是"])
        XCTAssertEqual(slots.map(\.index), [0, 3, 4])
    }

    func testDismissIsNoOpWithoutPrediction() {
        let engine = PredictingEngine()
        let session = InputSession(engine: engine, layout: .qwerty26)
        XCTAssertTrue(session.dismissPrediction())
        XCTAssertEqual(engine.escapes, 0)
    }

    func testDefaultBackendDismissUsesEscAndDropsCommit() throws {
        let engine = PredictingEngine()
        _ = try engine.processKey("n")
        _ = try engine.processKey(" ")
        XCTAssertTrue(engine.currentSnapshot().isPrediction)
        let closed = try engine.dismissPrediction()
        XCTAssertFalse(closed.isPrediction)
        XCTAssertEqual(closed.committed, "")
    }
}
