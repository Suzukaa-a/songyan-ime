import XCTest

@testable import KeyboardCore

/// Faithful model of the production engine/spelling contract used by RimeBackend:
/// the highlighted spelling is decoded **when a snapshot is produced** (action or
/// select), then cached; `currentSnapshot()` maps that cache and never re-evaluates
/// the demand. The layout-switch tests below rely on this — not a stub
/// that recomputes on every `currentSnapshot`.
private final class CacheContractEngine: EngineBackend {
    let kind: EngineBackendKind = .demoSimulator("cache-contract-test")
    var spellingDemand: (@Sendable () -> Bool)?
    var rejectSchemaIDs: Set<String> = []
    var currentSchemaID = "songyan_quanpin"
    var candidateText = "你"
    var candidateSpelling = "ni"

    private(set) var schemaSelectCount = 0
    /// Number of candidate decodes (demand true and composing at production time).
    private(set) var spellingRequestCount = 0

    private var input = ""
    private var composing = false
    private var cached: EngineSnapshot?

    func setup(sharedDirectory: URL, userDirectory: URL) throws {}
    func validateSchema(_ schemaID: String) throws {
        if rejectSchemaIDs.contains(schemaID) {
            throw EngineBackendError.unsupportedSchema("stub rejects \(schemaID)")
        }
    }
    func selectSchema(_ schemaID: String) throws {
        schemaSelectCount += 1
        currentSchemaID = schemaID
        input = ""
        composing = false
        cached = produce()  // production caches engine.state() after select
    }
    func processKey(_ keyValue: String) throws -> EngineSnapshot {
        switch keyValue {
        case "\u{08}":
            if !input.isEmpty { input.removeLast() }
            composing = !input.isEmpty
        case "\n":
            input = ""
            composing = false
        default:
            input += keyValue
            composing = true
        }
        cached = produce()
        return cached!
    }
    func selectCandidate(_ index: Int) throws -> EngineSnapshot {
        var s = produce()
        if composing { s.committed = candidateText }
        input = ""
        composing = false
        cached = s
        return s
    }
    func nextPage() throws -> EngineSnapshot { currentSnapshot() }
    func previousPage() throws -> EngineSnapshot { currentSnapshot() }
    /// Production contract: map the cache, clear the one-shot commit, never re-decode.
    func currentSnapshot() -> EngineSnapshot {
        var s = cached ?? produce()
        s.committed = ""
        return s
    }
    func shutdown() {}
    var statusSummary: String { "cache-contract" }

    private func produce() -> EngineSnapshot {
        let request = composing && (spellingDemand?() ?? false)
        if request { spellingRequestCount += 1 }
        let preedit = composing ? input : ""
        var s = EngineSnapshot(
            candidates: composing ? [Candidate(index: 0, text: candidateText)] : [],
            preedit: preedit, rawInput: preedit, isComposing: composing,
            highlightedIndex: composing ? 0 : -1, pageIndex: 0, pageSize: 5, isLastPage: true)
        s.schemaID = currentSchemaID
        s.highlightedSpelling = request ? candidateSpelling : ""
        s.preeditSelStart = 0
        s.preeditSelEnd = preedit.utf8.count
        s.preeditCaretByte = preedit.utf8.count
        s.preeditSelection = NSRange(location: (preedit as NSString).length, length: 0)
        return s
    }
}

@MainActor
final class SpellingDemandSwitchTests: XCTestCase {

    private func marked(_ session: InputSession) -> String {
        MarkedComposition(snapshot: session.snapshot, spellingPreedit: session.requiresSpellingDisplay).text
    }

    /// Composes through real session actions, so the demand is installed before each
    /// snapshot is produced and the cache is real (never recomputed by currentSnapshot).
    private func compose(_ session: InputSession, _ keys: String) {
        for ch in keys { session.tap(.code(String(ch))) }
        XCTAssertTrue(session.snapshot.isComposing, "composition established: \(keys)")
    }

    // MARK: - Failed explicit switch keeps the actual layout's cache

    /// 26 actual → failed 14 target: no new decode, cache unchanged, no switch, no commit.
    func testFailedSwitchToReducedLayoutKeepsFullLayoutAndRequestsNoSpelling() {
        let engine = CacheContractEngine()
        let session = InputSession(engine: engine, layout: .qwerty26)
        compose(session, "ni")
        XCTAssertEqual(engine.spellingRequestCount, 0, "a 26-key composition produces no candidate decoding")
        engine.rejectSchemaIDs = [BuiltinTemplateSchemas.defaultSchemaID(for: .merged14)!]
        let requestsBefore = engine.spellingRequestCount
        let selectsBefore = engine.schemaSelectCount
        var errors = 0
        session.onError = { _ in errors += 1 }
        var commits: [String] = []
        session.onCommitted = { commits.append($0) }

        session.select(layout: .merged14)

        XCTAssertEqual(session.layout, .qwerty26)
        XCTAssertFalse(session.requiresSpellingDisplay)
        XCTAssertEqual(engine.schemaSelectCount, selectsBefore, "no schema select on validation failure")
        XCTAssertEqual(engine.spellingRequestCount, requestsBefore, "26 must stay at zero decodes")
        XCTAssertEqual(session.snapshot.highlightedSpelling, "", "failure reuses the 26 cache")
        XCTAssertTrue(commits.isEmpty)
        XCTAssertEqual(errors, 1)
    }

    /// 14 actual → failed 26 target: the cached 14 spelling is retained (no fallback to raw).
    func testFailedSwitchToFullLayoutKeepsReducedSpelling() {
        let engine = CacheContractEngine()
        let session = InputSession(engine: engine, layout: .merged14)
        // The decode gate is the PHYSICAL proof, not the layout kind.
        session.compactSpellingLayout = true
        compose(session, "bu")
        XCTAssertEqual(session.snapshot.highlightedSpelling, "ni")
        engine.rejectSchemaIDs = ["songyan_quanpin"]
        let requestsBefore = engine.spellingRequestCount
        let selectsBefore = engine.schemaSelectCount
        var commits: [String] = []
        session.onCommitted = { commits.append($0) }

        session.select(layout: .qwerty26)

        XCTAssertEqual(session.layout, .merged14)
        XCTAssertTrue(session.requiresSpellingDisplay)
        XCTAssertEqual(engine.schemaSelectCount, selectsBefore)
        XCTAssertEqual(
            engine.spellingRequestCount, requestsBefore,
            "failure reuses the cached 14 spelling; no new request")
        XCTAssertEqual(session.snapshot.highlightedSpelling, "ni", "no fallback to raw code")
        XCTAssertEqual(marked(session), "ni")
        XCTAssertTrue(commits.isEmpty)
    }

    func testFailedBoundSwitchDoesNotPolluteEitherDirection() {
        let engine = CacheContractEngine()
        let session = InputSession(engine: engine, layout: .merged14)
        session.compactSpellingLayout = true
        compose(session, "bu")
        engine.rejectSchemaIDs = ["missing_schema"]
        let requestsBefore = engine.spellingRequestCount
        let selectsBefore = engine.schemaSelectCount

        session.select(layout: .qwerty26, boundSchemaID: "missing_schema")

        XCTAssertEqual(session.layout, .merged14)
        XCTAssertEqual(engine.schemaSelectCount, selectsBefore)
        XCTAssertEqual(engine.spellingRequestCount, requestsBefore)
        XCTAssertEqual(session.snapshot.highlightedSpelling, "ni")
    }

    func testSuccessfulSwitchMovesDemandToActualLayout() {
        let engine = CacheContractEngine()
        let session = InputSession(engine: engine, layout: .qwerty26)
        XCTAssertFalse(session.requiresSpellingDisplay)

        session.select(layout: .merged14)
        XCTAssertEqual(session.layout, .merged14)
        XCTAssertTrue(session.requiresSpellingDisplay)
        XCTAssertEqual(engine.schemaSelectCount, 1)

        session.select(layout: .qwerty26)
        XCTAssertEqual(session.layout, .qwerty26)
        XCTAssertFalse(session.requiresSpellingDisplay)
        XCTAssertEqual(engine.schemaSelectCount, 2)
    }

    // MARK: - Composition resume must request spelling before replay

    /// Reproduces the boot order: install the demand bound to the resume target,
    /// replay raw input, then create the InputSession; the read-only first frame
    /// must already carry the spelling.
    private func resume(_ layout: KeyboardLayoutKind, keys: String, preReplayDemand: Bool)
        -> (InputSession, CacheContractEngine, [String])
    {
        let engine = CacheContractEngine()
        // boot: engine.spellingDemand = { bootLayout.requiresSpellingDisplay } BEFORE replay
        if preReplayDemand {
            let reduced = layout.requiresSpellingDisplay
            engine.spellingDemand = { reduced }
        }
        // boot: selectSchema(initial) then replay rawInput (before any InputSession exists)
        try? engine.selectSchema(BuiltinTemplateSchemas.defaultSchemaID(for: layout) ?? "")
        var commits: [String] = []
        for ch in keys { _ = try? engine.processKey(String(ch)) }
        // boot: create KeyboardController -> InputSession installs the real-layout demand
        let session = InputSession(engine: engine, layout: layout)
        session.onCommitted = { commits.append($0) }
        session.refresh()  // Controller init's read-only frame
        return (session, engine, commits)
    }

    func testFourteenKeyResumeFirstFrameKeepsSpelling() {
        let (session, _, commits) = resume(.merged14, keys: "bu", preReplayDemand: true)
        XCTAssertEqual(
            session.snapshot.highlightedSpelling, "ni",
            "the first frame must already carry spelling (the demand is installed before replay)")
        XCTAssertEqual(marked(session), "ni")
        XCTAssertTrue(commits.isEmpty, "replay must not produce any host commit")
    }

    func testNineKeyResumeFirstFrameKeepsSpelling() {
        let (session, _, commits) = resume(.phone9, keys: "64", preReplayDemand: true)
        XCTAssertEqual(session.snapshot.highlightedSpelling, "ni")
        XCTAssertEqual(marked(session), "ni")
        XCTAssertTrue(commits.isEmpty)
    }

    func testTwentySixResumePerformsNoDecode() {
        let (session, engine, commits) = resume(.qwerty26, keys: "nihao", preReplayDemand: true)
        XCTAssertEqual(engine.spellingRequestCount, 0, "a 26-key restore must not produce candidate decoding")
        XCTAssertEqual(session.snapshot.highlightedSpelling, "")
        XCTAssertEqual(marked(session), session.snapshot.preedit, "26-key keeps the original preedit")
        XCTAssertTrue(commits.isEmpty)
    }

    /// Negative control: if the demand were installed only after replay (the old bug),
    /// the cached first frame has no spelling and a read-only refresh cannot recover it.
    func testResumeWithoutPreReplayDemandLosesFirstFrameSpelling() {
        let (session, engine, _) = resume(.merged14, keys: "bu", preReplayDemand: false)
        XCTAssertEqual(engine.spellingRequestCount, 0, "no request during replay -> the cache has no spelling")
        XCTAssertEqual(
            session.snapshot.highlightedSpelling, "",
            "the cached first frame of the old order indeed has no spelling (the case the demand-before-replay ordering eliminates)"
        )
        XCTAssertEqual(marked(session), "bu", "and therefore falls back to the raw code")
    }

    /// After a resumed 14 composition, a later failed switch must not degrade the spelling.
    func testResumeThenFailedSwitchKeepsSpelling() {
        let (session, engine, _) = resume(.merged14, keys: "bu", preReplayDemand: true)
        XCTAssertEqual(marked(session), "ni")
        engine.rejectSchemaIDs = ["songyan_quanpin"]
        session.select(layout: .qwerty26)
        XCTAssertEqual(session.layout, .merged14)
        XCTAssertEqual(marked(session), "ni", "a failed switch after restore must not regress")
    }
}
