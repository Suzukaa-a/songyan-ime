import XCTest

@testable import KeyboardCore

/// Engine-level proof that a 26-key (non-compact-spelling) layout makes **zero queries**.
///
/// `layout` describes the input method/encoding, not a physical key-layout fact: a definition whose `rows` are 26-key but whose `builtinLayout`
/// is mislabeled `phone9`/`merged14` makes `layout` that kind, so the kind **cannot**
/// be used as the disambiguation gate. The real capability is computed by the front end from the definition structure and injected as `compactSpellingLayout` (default false
/// = fail closed); this file uses a spy engine to prove neither read-only API reaches the engine when unauthorized, and that
/// granting/revoking takes effect immediately.
private final class QueryCountingSpyEngine: EngineBackend {
    let kind: EngineBackendKind = .demoSimulator("query-gate-spy")
    var snapshot = EngineSnapshot(
        candidates: [Candidate(index: 0, text: "你")],
        rawInput: "ug", isComposing: true)
    var report: AmbiguitySpellingsReport?
    var rejectSchemaIDs: Set<String> = []
    /// Commit-failure script: when `false` the session is still composing after commit (production `commitComposition` returns false accordingly).
    var commitSucceeds = true
    /// `selectSchema` failure script (validate passes but the engine rejects).
    var failSchemaSelect = false
    private(set) var ambiguityCalls = 0
    private(set) var readingCalls = 0
    private(set) var applied: [(String, Range<Int>, String)] = []
    private(set) var restored: [(String, Range<Int>, String, String)] = []

    func setup(sharedDirectory: URL, userDirectory: URL) throws {}
    func validateSchema(_ schemaID: String) throws {
        if rejectSchemaIDs.contains(schemaID) {
            throw EngineBackendError.unsupportedSchema("spy rejects \(schemaID)")
        }
    }
    func selectSchema(_ schemaID: String) throws {
        if failSchemaSelect {
            throw EngineBackendError.unsupportedSchema("spy selectSchema failed \(schemaID)")
        }
    }
    func processKey(_ keyValue: String) throws -> EngineSnapshot { snapshot }
    func cancelComposition() throws -> EngineSnapshot { EngineSnapshot() }
    func selectCandidate(_ index: Int) throws -> EngineSnapshot {
        guard commitSucceeds else { return snapshot }  // still composing -> the upper layer sees the commit as failed
        // Production contract: the composition ends after a candidate is confirmed.
        snapshot = EngineSnapshot(committed: "你")
        return snapshot
    }
    func nextPage() throws -> EngineSnapshot { snapshot }
    func previousPage() throws -> EngineSnapshot { snapshot }
    func currentSnapshot() -> EngineSnapshot { snapshot }
    func shutdown() {}
    var statusSummary: String { "query-gate-spy" }

    func ambiguitySpellings() throws -> AmbiguitySpellingsReport? {
        ambiguityCalls += 1
        return report
    }

    func readCandidatesWithReadings(fromIndex: Int, count: Int) throws -> [ReadingCandidate]? {
        readingCalls += 1
        return [ReadingCandidate(index: fromIndex, text: "你")]
    }

    func applyAmbiguitySpelling(
        expectedInput: String, segment: Range<Int>,
        option: String
    ) throws -> AmbiguityApplyOutcome {
        applied.append((expectedInput, segment, option))
        return .applied
    }

    func restoreAmbiguitySpelling(
        expectedInput: String, segment: Range<Int>,
        expectedOption: String,
        reducedCode: String
    ) throws -> AmbiguityApplyOutcome {
        restored.append((expectedInput, segment, expectedOption, reducedCode))
        return .applied
    }
}

@MainActor
final class AmbiguityQueryGateTests: XCTestCase {

    private func makeSession(_ layout: KeyboardLayoutKind) -> (InputSession, QueryCountingSpyEngine) {
        let engine = QueryCountingSpyEngine()
        let session = InputSession(engine: engine, layout: layout)
        session.onDispatchCommit = { _ in true }
        session.refresh()
        XCTAssertTrue(session.snapshot.isComposing)
        return (session, engine)
    }

    private func report() -> AmbiguitySpellingsReport {
        AmbiguitySpellingsReport(
            revisionInput: "ug", segment: 0..<2,
            options: ["chang", "shang"],
            allSpellings: ["chang", "shang"],
            lockMode: .tokenAlias, isComplete: true)
    }

    /// Core regression: the kind is `.phone9` / `.merged14` (the result of a 26-key definition mislabeled as builtin),
    /// but the physical structure is not authorized -> both engine APIs get zero calls.
    func testUnauthorizedPhysicalLayoutQueriesNothingEvenWhenKindIsCompact() throws {
        for layout in [KeyboardLayoutKind.phone9, .merged14] {
            let (session, engine) = makeSession(layout)
            XCTAssertFalse(session.compactSpellingLayout, "\(layout) must fail closed by default")

            XCTAssertNil(session.ambiguitySpellings())
            XCTAssertNil(try session.readCandidatesWithReadings(fromIndex: 0, count: 32))

            XCTAssertEqual(engine.ambiguityCalls, 0, "\(layout): must not query spellings when unauthorized")
            XCTAssertEqual(engine.readingCalls, 0, "\(layout): must not read readings when unauthorized")
        }
    }

    /// A 26-key layout's 26-key kind also makes zero calls (double check: whatever the kind is).
    func testTwentySixKindQueriesNothing() throws {
        let (session, engine) = makeSession(.qwerty26)
        session.compactSpellingLayout = false
        XCTAssertNil(session.ambiguitySpellings())
        XCTAssertNil(try session.readCandidatesWithReadings(fromIndex: 0, count: 32))
        XCTAssertEqual(engine.ambiguityCalls, 0)
        XCTAssertEqual(engine.readingCalls, 0)
    }

    /// After authorization each is called exactly once (proving the gate did not shut the legitimate path too).
    func testGrantedCapabilityForwardsExactlyOnce() throws {
        let (session, engine) = makeSession(.merged14)
        session.compactSpellingLayout = true
        engine.report = report()

        XCTAssertEqual(session.ambiguitySpellings()?.options, ["chang", "shang"])
        XCTAssertNotNil(try session.readCandidatesWithReadings(fromIndex: 4, count: 32))

        XCTAssertEqual(engine.ambiguityCalls, 1)
        XCTAssertEqual(engine.readingCalls, 1)
    }

    /// After revocation (definition switched away) queries stop **immediately**: no engine call leaks.
    func testWithdrawnCapabilityStopsQueryingImmediately() throws {
        let (session, engine) = makeSession(.merged14)
        session.compactSpellingLayout = true
        engine.report = report()
        _ = session.ambiguitySpellings()
        _ = try session.readCandidatesWithReadings(fromIndex: 0, count: 32)
        XCTAssertEqual(engine.ambiguityCalls, 1)
        XCTAssertEqual(engine.readingCalls, 1)

        session.compactSpellingLayout = false
        XCTAssertNil(session.ambiguitySpellings())
        XCTAssertNil(try session.readCandidatesWithReadings(fromIndex: 0, count: 32))
        XCTAssertEqual(engine.ambiguityCalls, 1, "no more queries after revocation")
        XCTAssertEqual(engine.readingCalls, 1, "no more reading reads after revocation")
    }

    // MARK: rewrite (apply / restore) must also fail closed at the session boundary

    /// When unauthorized, both **rewrite** entry points must return `.unsupported` with **zero engine calls**.
    /// A UI-layer guard cannot replace this: the public session API can be reached by any caller.
    func testUnauthorizedPhysicalLayoutPerformsNoRewrite() {
        for layout in [KeyboardLayoutKind.phone9, .merged14, .qwerty26] {
            let (session, engine) = makeSession(layout)
            XCTAssertFalse(session.compactSpellingLayout, "\(layout) fails closed by default")

            XCTAssertEqual(
                session.applyAmbiguityOption(
                    "shang", expectedInput: "ug",
                    segment: 0..<2), .unsupported)
            XCTAssertEqual(
                session.restoreAmbiguity(
                    expectedInput: "9084", segment: 0..<4,
                    expectedOption: "shang",
                    reducedCode: "ug"), .unsupported)

            XCTAssertTrue(engine.applied.isEmpty, "\(layout): must not reach apply rewrite when unauthorized")
            XCTAssertTrue(engine.restored.isEmpty, "\(layout): must not reach restore rewrite when unauthorized")
        }
    }

    /// After authorization both rewrite entry points pass through verbatim (proving the gate did not shut the legitimate path).
    func testGrantedCapabilityForwardsRewriteVerbatim() {
        let (session, engine) = makeSession(.merged14)
        session.compactSpellingLayout = true

        XCTAssertEqual(
            session.applyAmbiguityOption(
                "shang", expectedInput: "ug",
                segment: 0..<2), .applied)
        XCTAssertEqual(
            session.restoreAmbiguity(
                expectedInput: "9084", segment: 0..<4,
                expectedOption: "shang",
                reducedCode: "ug"), .applied)

        XCTAssertEqual(engine.applied.count, 1)
        XCTAssertEqual(engine.applied.first?.0, "ug")
        XCTAssertEqual(engine.applied.first?.1, 0..<2)
        XCTAssertEqual(engine.applied.first?.2, "shang")
        XCTAssertEqual(engine.restored.count, 1)
        XCTAssertEqual(engine.restored.first?.0, "9084")
        XCTAssertEqual(engine.restored.first?.2, "shang")
        XCTAssertEqual(engine.restored.first?.3, "ug")
    }

    /// After revocation rewrite stops immediately (a locked restore cannot bypass the gate either).
    func testWithdrawnCapabilityStopsRewriteImmediately() {
        let (session, engine) = makeSession(.merged14)
        session.compactSpellingLayout = true
        _ = session.applyAmbiguityOption("shang", expectedInput: "ug", segment: 0..<2)
        _ = session.restoreAmbiguity(
            expectedInput: "9084", segment: 0..<4,
            expectedOption: "shang", reducedCode: "ug")
        XCTAssertEqual(engine.applied.count, 1)
        XCTAssertEqual(engine.restored.count, 1)

        session.compactSpellingLayout = false
        XCTAssertEqual(
            session.applyAmbiguityOption(
                "chang", expectedInput: "ug",
                segment: 0..<2), .unsupported)
        XCTAssertEqual(
            session.restoreAmbiguity(
                expectedInput: "9084", segment: 0..<4,
                expectedOption: "shang",
                reducedCode: "ug"), .unsupported)
        XCTAssertEqual(engine.applied.count, 1, "no more rewrite after revocation")
        XCTAssertEqual(engine.restored.count, 1, "no more restore after revocation")
    }

    // MARK: Synchronous fail-closed on layout switch (transition gate)

    /// Fail closed **before** a switch attempt: any `onUpdate`/`refresh` triggered by the session during the switch
    /// must not see the old (true) eligibility, so the target schema can never be queried with stale eligibility.
    func testTransitionGateInvalidatesCapabilityBeforeAnyRefresh() {
        let (session, engine) = makeSession(.merged14)
        session.compactSpellingLayout = true
        engine.report = report()

        var capabilityAtUpdate: [Bool] = []
        session.onUpdate = { capabilityAtUpdate.append(session.compactSpellingLayout) }

        session.select(layout: .qwerty26)  // the session begins internally (no explicit call needed)

        XCTAssertFalse(
            capabilityAtUpdate.contains(true),
            "the switch (select -> onUpdate -> refresh) must not see the old eligibility true")
        XCTAssertFalse(session.compactSpellingLayout, "eligibility must already be failed closed after the switch")
        XCTAssertEqual(engine.ambiguityCalls, 0, "zero queries during the switch")
    }

    /// Failed switch: the owner restores the original eligibility (no second grant needed from the caller), and the switch makes zero queries.
    func testFailedTransitionRestoresCapabilityAndQueriesNothing() {
        let (session, engine) = makeSession(.merged14)
        session.compactSpellingLayout = true
        engine.report = report()
        engine.rejectSchemaIDs = ["songyan_quanpin"]

        session.select(layout: .qwerty26, boundSchemaID: "songyan_quanpin")

        XCTAssertEqual(session.layout, .merged14, "a failed switch keeps the original layout")
        XCTAssertEqual(engine.ambiguityCalls, 0, "zero queries during a failed switch")
        // The owner rolls back itself on the failure path: eligibility restored (definition unchanged), and no transaction remains.
        XCTAssertTrue(session.compactSpellingLayout, "after failure the owner restores the pre-switch eligibility")
        XCTAssertNotNil(session.ambiguitySpellings(), "queries work normally after restoration")
        XCTAssertEqual(
            engine.ambiguityCalls, 1,
            "the query after restoration is the only one (the process itself makes zero queries)")
    }

    // MARK: Transactional gate (no-op / failure recovery / do not resurrect an expired lock)

    /// **True no-op**: select of the same layout must not change eligibility (otherwise reselecting the current layout would wrongly clear it).
    func testSelectingCurrentLayoutIsNoopAndKeepsCapability() {
        let (session, engine) = makeSession(.merged14)
        session.compactSpellingLayout = true
        engine.report = report()

        session.select(layout: .merged14)  // same layout
        XCTAssertTrue(session.compactSpellingLayout, "reselecting the same layout must not clear eligibility")
        XCTAssertNotNil(session.ambiguitySpellings(), "eligibility kept -> still queryable")
        XCTAssertEqual(engine.ambiguityCalls, 1)

        session.select(layout: .merged14, boundSchemaID: session.selectedSchemaID)
        XCTAssertTrue(session.compactSpellingLayout, "reselecting the same layout+schema must not clear eligibility")
        XCTAssertEqual(engine.ambiguityCalls, 1, "reselecting the same layout adds zero queries")
    }

    /// **Every failure path** of `select(layout:)` must leave no transitioning state and restore the original eligibility.
    /// Covers: validate failure / confirm failure / selectSchema failure / missing resource pairing.
    func testOwnerSelectFailuresNeverLeakTransition() {
        // 1) validate failure (bound entry, schema unsupported).
        let (vSession, vEngine) = makeSession(.merged14)
        vSession.compactSpellingLayout = true
        vEngine.rejectSchemaIDs = ["missing_schema"]
        vSession.select(layout: .qwerty26, boundSchemaID: "missing_schema")
        XCTAssertEqual(vSession.layout, .merged14, "validate failure keeps the original layout")
        XCTAssertTrue(vSession.compactSpellingLayout, "validate failure restores the original eligibility")

        // 2) confirm failure (composition cannot be confirmed).
        let (cSession, cEngine) = makeSession(.merged14)
        cSession.compactSpellingLayout = true
        cEngine.rejectSchemaIDs = []
        cEngine.commitSucceeds = false
        cSession.select(layout: .qwerty26)
        XCTAssertEqual(cSession.layout, .merged14, "confirm failure keeps the original layout")
        XCTAssertTrue(cSession.compactSpellingLayout, "confirm failure restores the original eligibility")

        // 3) selectSchema failure (validate passes but the engine rejects).
        let (sSession, sEngine) = makeSession(.merged14)
        sSession.compactSpellingLayout = true
        sEngine.rejectSchemaIDs = []
        sEngine.failSchemaSelect = true
        sSession.select(layout: .qwerty26)
        XCTAssertEqual(sSession.layout, .merged14, "selectSchema failure keeps the original layout")
        XCTAssertTrue(sSession.compactSpellingLayout, "selectSchema failure restores the original eligibility")

        // 4) resource branch: pairing missing (independent selection has no companion scheme for the target layout).
        let rEngine = QueryCountingSpyEngine()
        let rSet = KeyboardResourceSet(
            id: "empty-combos", name: "empty-combos",
            sharedDirectory: FileManager.default.temporaryDirectory,
            userDirectory: FileManager.default.temporaryDirectory,
            layoutEntries: [],
            schemas: [KeyboardSchemaDescriptor(id: "songyan_quanpin", name: "全拼")],
            selectedSchemaID: "songyan_quanpin")
        XCTAssertTrue(rSet.usesIndependentSelection, "this resource set takes the independent-selection branch")
        XCTAssertNil(rSet.combination(layout: .merged14), "the target layout really has no companion scheme")
        let rSession = InputSession(engine: rEngine, layout: .qwerty26, resourceSet: rSet)
        rSession.compactSpellingLayout = true
        rSession.select(layout: .merged14)
        XCTAssertEqual(rSession.layout, .qwerty26, "missing resource combination keeps the original layout")
        XCTAssertTrue(rSession.compactSpellingLayout, "resource failure restores the original eligibility")
    }

    /// Confirming a composition for a configuration change restores the pre-confirmation qualification.
    func testPrepareRestoresCapability() {
        let (session, _) = makeSession(.merged14)
        session.compactSpellingLayout = true
        XCTAssertTrue(session.prepareForConfigurationChange())
        XCTAssertTrue(session.compactSpellingLayout, "a confirmation does not change the definition")
    }
}
