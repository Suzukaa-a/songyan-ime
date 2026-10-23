import XCTest

@testable import KeyboardCore

/// The production `InputSession` installs the engine's `spellingDemand` gate from
/// the PHYSICAL layout proof (`compactSpellingLayout`), not from the layout KIND.
/// A 26-key definition mislabeled `merged14` therefore performs zero decodes until
/// the panel injects the proof; a real 14-key definition decodes only once
/// authorized. These tests exercise the real closure installed by `InputSession`,
/// not a harness-set one.
private final class GateEngine: EngineBackend {
    let kind: EngineBackendKind = .demoSimulator("spelling-demand-gate-test")
    var spellingDemand: (@Sendable () -> Bool)?
    /// Number of candidate decodes (demand true while composing).
    private(set) var decodeCount = 0
    private var input = ""
    private var composing = false

    func setup(sharedDirectory: URL, userDirectory: URL) throws {}
    func selectSchema(_ schemaID: String) throws {
        input = ""
        composing = false
    }
    func processKey(_ keyValue: String) throws -> EngineSnapshot {
        if keyValue == "\u{08}" { if !input.isEmpty { input.removeLast() } } else { input += keyValue }
        composing = !input.isEmpty
        return produce()
    }
    func selectCandidate(_ index: Int) throws -> EngineSnapshot { produce() }
    func nextPage() throws -> EngineSnapshot { currentSnapshot() }
    func previousPage() throws -> EngineSnapshot { currentSnapshot() }
    func currentSnapshot() -> EngineSnapshot { produce() }
    func shutdown() {}
    var statusSummary: String { "spelling-demand-gate" }

    /// The engine's demand evaluation, exactly as the production engine reads it.
    func evaluateDemand() -> Bool { spellingDemand?() ?? false }

    private func produce() -> EngineSnapshot {
        let request = composing && evaluateDemand()
        if request { decodeCount += 1 }
        var s = EngineSnapshot(
            candidates: composing ? [Candidate(index: 0, text: "你")] : [],
            preedit: input, rawInput: input, isComposing: composing,
            highlightedIndex: composing ? 0 : -1, pageIndex: 0, pageSize: 5, isLastPage: true)
        s.schemaID = "keyboard_3d7821f984693864ae91_14"
        s.highlightedSpelling = request ? "ni" : ""
        s.preeditSelStart = 0
        s.preeditSelEnd = input.utf8.count
        s.preeditCaretByte = input.utf8.count
        return s
    }
}

@MainActor
final class SpellingDemandGateTests: XCTestCase {

    /// kind = merged14 (would say "yes") but no physical proof → gate closed.
    func testKindFlypy14WithoutPhysicalProofClosesTheGate() {
        let engine = GateEngine()
        let session = InputSession(engine: engine, layout: .merged14)
        XCTAssertTrue(session.requiresSpellingDisplay, "kind alone claims reduced layout")
        XCTAssertFalse(session.compactSpellingLayout, "physical proof defaults to false")
        XCTAssertFalse(engine.evaluateDemand(), "production gate must read the physical proof")

        session.tap(.code("b"))
        XCTAssertEqual(engine.decodeCount, 0, "mislabeled 26-key definition: zero decodes")
        XCTAssertEqual(session.snapshot.highlightedSpelling, "")
    }

    /// Authorizing the physical proof opens the gate and decodes.
    func testPhysicalProofGrantsDemandAndDecodes() {
        let engine = GateEngine()
        let session = InputSession(engine: engine, layout: .merged14)
        session.compactSpellingLayout = true
        XCTAssertTrue(engine.evaluateDemand())

        session.tap(.code("b"))
        XCTAssertEqual(engine.decodeCount, 1)
        XCTAssertEqual(session.snapshot.highlightedSpelling, "ni")
    }

    /// A layout switch closes the gate synchronously (never a window
    /// where a stale qualification decodes the target schema).
    func testTransitionRevokesDemandSynchronously() {
        let engine = GateEngine()
        let session = InputSession(engine: engine, layout: .merged14)
        session.compactSpellingLayout = true
        XCTAssertTrue(engine.evaluateDemand())

        session.select(layout: .qwerty26)
        XCTAssertFalse(session.compactSpellingLayout)
        XCTAssertFalse(engine.evaluateDemand(), "gate closed during/after transition")

        session.tap(.code("b"))
        XCTAssertEqual(engine.decodeCount, 0, "no decode while qualification is revoked")
    }

    /// A 26-key KIND never opens the gate, even if it were physically authorized.
    func testFullLayoutKindWithoutProofStaysClosed() {
        let engine = GateEngine()
        let session = InputSession(engine: engine, layout: .qwerty26)
        XCTAssertFalse(engine.evaluateDemand())
        session.tap(.code("n"))
        XCTAssertEqual(engine.decodeCount, 0)
    }

    func testPhysicalProofCanChangeWhileEngineReadsDemand() {
        let engine = GateEngine()
        let session = InputSession(engine: engine, layout: .merged14)
        guard let demand = engine.spellingDemand else { return XCTFail("missing demand gate") }
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            for _ in 0..<10_000 { _ = demand() }
            finished.signal()
        }
        for index in 0..<10_000 { session.compactSpellingLayout = index.isMultiple(of: 2) }
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        session.compactSpellingLayout = false
        XCTAssertFalse(demand())
    }
}
