import XCTest

@testable import KeyboardCore

/// Scripted fake engine for the ambiguity session contract. Reports a fixed
/// report; apply/restore outcomes are scripted and record calls.
private final class ScriptedAmbiguityEngine: EngineBackend {
    let kind: EngineBackendKind = .demoSimulator("ambiguity-test")
    var snapshot = EngineSnapshot(rawInput: "ug", isComposing: true)
    var report: AmbiguitySpellingsReport?
    var applyOutcome: AmbiguityApplyOutcome = .applied
    var restoreOutcome: AmbiguityApplyOutcome = .applied
    var postApplyInput = "9084"
    private(set) var applied: [(String, Range<Int>, String)] = []
    private(set) var restored: [(String, Range<Int>, String, String)] = []

    func setup(sharedDirectory: URL, userDirectory: URL) throws {}
    func selectSchema(_ schemaID: String) throws {}
    func processKey(_ keyValue: String) throws -> EngineSnapshot { snapshot }
    func cancelComposition() throws -> EngineSnapshot { EngineSnapshot() }
    func selectCandidate(_ index: Int) throws -> EngineSnapshot { snapshot }
    func nextPage() throws -> EngineSnapshot { snapshot }
    func previousPage() throws -> EngineSnapshot { snapshot }
    func currentSnapshot() -> EngineSnapshot { snapshot }
    func shutdown() {}
    var statusSummary: String { "scripted" }

    func ambiguitySpellings() throws -> AmbiguitySpellingsReport? { report }
    func applyAmbiguitySpelling(
        expectedInput: String, segment: Range<Int>,
        option: String
    ) throws -> AmbiguityApplyOutcome {
        applied.append((expectedInput, segment, option))
        if applyOutcome == .applied { snapshot = EngineSnapshot(rawInput: postApplyInput, isComposing: true) }
        return applyOutcome
    }
    func restoreAmbiguitySpelling(
        expectedInput: String, segment: Range<Int>,
        expectedOption: String,
        reducedCode: String
    ) throws -> AmbiguityApplyOutcome {
        restored.append((expectedInput, segment, expectedOption, reducedCode))
        if restoreOutcome == .applied { snapshot = EngineSnapshot(rawInput: "ug", isComposing: true) }
        return restoreOutcome
    }
}

@MainActor
final class AmbiguitySessionTests: XCTestCase {

    private func makeSession() -> (InputSession, ScriptedAmbiguityEngine) {
        let engine = ScriptedAmbiguityEngine()
        let session = InputSession(engine: engine, layout: .merged14)
        // The physical-structure gate fails closed by default; these cases cover the report/apply/restore
        // contract of an *authorized* compact-spelling layout (14-key merged keys), so the capability is granted explicitly.
        session.compactSpellingLayout = true
        session.refresh()
        return (session, engine)
    }

    func testReportForwarded() {
        let (session, engine) = makeSession()
        engine.report = AmbiguitySpellingsReport(
            revisionInput: "ug", segment: 0..<2,
            options: ["chang", "shang"], allSpellings: ["chang", "shang"],
            lockMode: .tokenAlias, isComplete: true)
        let report = session.ambiguitySpellings()
        XCTAssertEqual(report?.options, ["chang", "shang"])
        XCTAssertEqual(report?.segment, 0..<2)
    }

    func testApplyForwardsCASAndRefreshesOnSuccess() {
        let (session, engine) = makeSession()
        engine.report = AmbiguitySpellingsReport(
            revisionInput: "ug", segment: 0..<2,
            options: ["shang"], allSpellings: ["shang"],
            lockMode: .tokenAlias, isComplete: true)
        let outcome = session.applyAmbiguityOption("shang", expectedInput: "ug", segment: 0..<2)
        XCTAssertEqual(outcome, .applied)
        XCTAssertEqual(engine.applied.count, 1)
        XCTAssertEqual(engine.applied.first?.2, "shang")
        XCTAssertEqual(session.snapshot.rawInput, "9084", "refreshed from real post-state")
    }

    func testApplyFailureDoesNotRefreshAndIsReported() {
        let (session, engine) = makeSession()
        engine.applyOutcome = .stale
        let outcome = session.applyAmbiguityOption("shang", expectedInput: "ug", segment: 0..<2)
        XCTAssertEqual(outcome, .stale)
        XCTAssertEqual(session.snapshot.rawInput, "ug", "no state change on failure")
    }

    func testRestoreForwardsAndRefreshes() {
        let (session, engine) = makeSession()
        let outcome = session.restoreAmbiguity(
            expectedInput: "9084", segment: 0..<4,
            expectedOption: "shang", reducedCode: "ug")
        XCTAssertEqual(outcome, .applied)
        XCTAssertEqual(engine.restored.count, 1)
        XCTAssertEqual(engine.restored.first?.0, "9084")
        XCTAssertEqual(engine.restored.first?.3, "ug")
        XCTAssertEqual(session.snapshot.rawInput, "ug")
    }

    func testRollbackUnverifiedSurfacesDistinctly() {
        let (session, engine) = makeSession()
        engine.restoreOutcome = .failedRollbackUnverified
        let outcome = session.restoreAmbiguity(
            expectedInput: "9084", segment: 0..<4,
            expectedOption: "shang", reducedCode: "ug")
        XCTAssertEqual(outcome, .failedRollbackUnverified)
    }

    /// BN+UI merged trajectory (raw "bu"): the session forwards both live-prism-proven
    /// options and selects NI through the alias CAS without committing.
    func testMergedBuForwardsAndAppliesNi() {
        let (session, engine) = makeSession()
        engine.snapshot = EngineSnapshot(rawInput: "bu", isComposing: true)
        session.refresh()
        engine.report = AmbiguitySpellingsReport(
            revisionInput: "bu", segment: 0..<2,
            options: ["bu", "ni"], allSpellings: ["bu", "ni"],
            lockMode: .tokenAlias, isComplete: true)
        let report = session.ambiguitySpellings()
        XCTAssertEqual(report?.options, ["bu", "ni"])
        XCTAssertEqual(report?.segment, 0..<2)
        engine.postApplyInput = "9070"
        let outcome = session.applyAmbiguityOption("ni", expectedInput: "bu", segment: 0..<2)
        XCTAssertEqual(outcome, .applied)
        XCTAssertEqual(engine.applied.count, 1)
        XCTAssertEqual(engine.applied.first?.2, "ni")
        XCTAssertEqual(session.snapshot.rawInput, "9070", "refreshed from real post-state")
    }

    /// Prefix mode (v4): the session forwards the bounded narrowing keys and their
    /// semantic labels verbatim, and applies a key through the same CAS path.
    func testPrefixReportForwardsNarrowingKeysAndSemantics() {
        let (session, engine) = makeSession()
        engine.snapshot = EngineSnapshot(rawInput: "2", isComposing: true)
        session.refresh()
        engine.report = AmbiguitySpellingsReport(
            revisionInput: "2", segment: 0..<1,
            options: ["a", "b", "c"], allSpellings: ["a"],
            lockMode: .prefixToken, isComplete: true,
            prefixOptions: ["a", "b", "c"],
            optionSemantics: ["a": "mixed", "b": "initial", "c": "initial"])
        let report = session.ambiguitySpellings()
        XCTAssertEqual(report?.lockMode, .prefixToken)
        XCTAssertEqual(report?.prefixOptions, ["a", "b", "c"])
        XCTAssertEqual(report?.optionSemantics["b"], "initial")
        XCTAssertEqual(report?.options, ["a", "b", "c"])
        engine.postApplyInput = "b"
        let outcome = session.applyAmbiguityOption("b", expectedInput: "2", segment: 0..<1)
        XCTAssertEqual(outcome, .applied)
        XCTAssertEqual(engine.applied.first?.2, "b")
        XCTAssertEqual(session.snapshot.rawInput, "b", "refreshed from real post-state")
        // Restore is the ordinary first-Backspace contract, unchanged.
        let restore = session.restoreAmbiguity(
            expectedInput: "b", segment: 0..<1,
            expectedOption: "b", reducedCode: "2")
        XCTAssertEqual(restore, .applied)
        XCTAssertEqual(engine.restored.first?.3, "2")
    }
}
