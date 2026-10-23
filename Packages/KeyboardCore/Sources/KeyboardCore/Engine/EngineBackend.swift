import Foundation

// MARK: - Engine backend protocol (consumer-side contract)
//
// This is the only surface of the engine that Apps/ (HostApp + KeyboardExtension) depend
// on. RimeBridge's RimeEngine must conform to this protocol before EngineFactory can
// select the real engine. See the interface notes in the RimeBridge package for contract
// details and the librime mapping.

public protocol EngineBackend: AnyObject {
    /// Engine implementation kind (real Rime / demo); the UI uses it to show a "demo data" marker.
    var kind: EngineBackendKind { get }
    /// Non-nil after an unrecoverable activation failure. Input must wait for recovery.
    var inputUnavailableReason: String? { get }

    /// Directories needed for install/deploy. Real engine: shared = deployed scheme
    /// resource directory (e.g. BuiltinPackages/Basic), user = isolated user directory
    /// (build/, userdb, sync). May be slow (the real engine deploys); call on a background queue.
    func setup(sharedDirectory: URL, userDirectory: URL) throws

    /// Activates an input scheme. `schemaID` is the engine-side schema id (e.g. "songyan_quanpin").
    func selectSchema(_ schemaID: String) throws

    /// Nonmutating preflight before confirming input for a user-requested layout change.
    func validateSchema(_ schemaID: String) throws
    /// Actual enabled schemas for this engine/resource generation, not compiled inventory.
    var availableSchemas: [KeyboardSchemaDescriptor] { get }
    /// The `speller/alphabet` of a running schema, generated adapters included; nil when unknown.
    func spellerAlphabet(schemaID: String) -> String?

    /// Processes one key press. keyValue is a logical key:
    ///   - a single-character text key (lowercase letter / digit);
    ///   - control keys use reserved symbols: "\u{08}" (backspace), " " (space) = confirm
    ///     the composition, "\n" (return), Esc = cancel the composition. Implementations may
    ///     decide space/return behavior using IME semantics.
    /// Returns the resulting state snapshot.
    func processKey(_ keyValue: String) throws -> EngineSnapshot

    /// Cancels the current composition (no commit, no commit text) and returns the *validated* post-cancel snapshot.
    ///
    /// Must be distinct from `processKey("Esc")`: a synthesized Esc goes through the
    /// scheme's own key bindings/editor semantics, and librime's `Editor::CancelComposition`
    /// only rolls back one segment when a previous segment exists (remaining syllables
    /// continue composing after a partial commit), leaving the composition alive
    /// (`isComposing == true`), which does not reliably "clear". A real engine with a
    /// dedicated clear API (librime `clear_composition`) must override this to clear
    /// unconditionally; the default only falls back to Esc, keeping demo/test-stub behavior.
    ///
    /// Failure contract: the implementation must cancel and read the real, fallible
    /// post-state within one serial owner step. An unavailable session, a rejected cancel,
    /// or a failed post-cancel read must `throw`; never substitute an empty/default snapshot
    /// for success, or `InputSession.discardComposition()` would treat the failure as
    /// "cancelled" and wrongly let the host clear the document / marked text. A successful
    /// snapshot must be the real read (real `isComposing == false`) with no pending commit.
    func cancelComposition() throws -> EngineSnapshot

    /// Dismisses post-commit prediction without committing or deleting host text; returns the current snapshot unchanged when there is none.
    func dismissPrediction() throws -> EngineSnapshot

    /// Selects the candidate at index (0-based) on the current page; returns the resulting
    /// snapshot (may carry commit text, keep the remaining composition, or clear it).
    func selectCandidate(_ index: Int) throws -> EngineSnapshot

    /// Selects a candidate by *cross-page absolute index* (0-based, global), so the front
    /// end can show multiple pages continuously and commit precisely without mistaking a
    /// concatenated-array index for an in-page index. Implementations without absolute
    /// selection fall back to in-page selection (only when the target is on the current page).
    func selectCandidateAbsolute(_ index: Int) throws -> EngineSnapshot

    /// Whether read-only cross-page candidate fetching is supported (does not change the current page/highlight). Default false.
    ///
    /// false means "no browsable candidate pages" = normal termination: callers must not
    /// retry on that basis, nor treat the default empty return of `readCandidates` as an error.
    var supportsReadOnlyBrowsing: Bool { get }

    /// Reads a run of candidates by absolute index (0-based, global), read-only. Must not
    /// change the engine's current page, highlight, or selected candidate (unlike nextPage/previousPage).
    ///
    /// Error / end semantics (callers use them to tell "read failed" from a real EOF; an
    /// error must not be treated as empty):
    ///   * `throw` = genuinely unavailable or read failed (engine not started / session
    ///     invalid / bad argument / underlying error). Callers may retry and must not treat
    ///     it as EOF/empty page;
    ///   * normal return (including an empty array or fewer than `count`) = successful read;
    ///     an empty/short page means no more candidates at that position (real EOF) and
    ///     callers end normally;
    ///   * default implementation (no capability) = normal termination, no endless retry.
    func readCandidates(fromIndex: Int, count: Int) throws -> [Candidate]
    /// Optional read-only pronunciation browsing. nil means unsupported backend.
    func readCandidatesWithReadings(fromIndex: Int, count: Int) throws -> [ReadingCandidate]?
    /// Optional word completions for the ABC page: the candidates `schemaID` itself
    /// produces for `prefix` in a separate read-only session (never the input
    /// session, never committed or learned). nil = the schema cannot be selected.
    /// No schema or dictionary is assumed; callers keep what fits their page.
    func wordCompletions(prefix: String, schemaID: String, limit: Int) throws -> [String]?
    /// Schemas worth probing for word completions of `sourceSchemaID`, discovered
    /// from that scheme's own configuration (empty = none).
    func wordCompletionSchemas(sourceSchemaID: String) throws -> [String]
    /// Drops the read-only word-completion session; the next query recreates it.
    func releaseWordCompletions()
    /// Read-only marked-text proof: the current highlighted preedit range and one
    /// complete pronunciation of the specified absolute candidate must agree.
    /// nil means unsupported or unproven; it must never fall back to a comment.
    /// The caller freezes physicalLayoutEligible on its owner thread before dispatch.
    func verifiedHighlightedReading(
        absoluteIndex: Int, expectedText: String,
        physicalLayoutEligible: Bool
    ) throws -> String?

    /// Pages / expands candidates (real engine paging; the demo engine may return the snapshot unchanged when it has no paging).
    func nextPage() throws -> EngineSnapshot
    func previousPage() throws -> EngineSnapshot

    /// Current state snapshot (the UI redraws from it after a scheme switch or paging).
    func currentSnapshot() -> EngineSnapshot

    /// Releases/closes the engine. The real engine handles rime_finalize etc.; idempotent.
    func shutdown()

    /// Stable, readable engine status summary (version, current schema, data source) for the About/debug page.
    var statusSummary: String { get }

    /// Only verified switches for the active resource/schema. False is a value, not capability.
    func optionStates() throws -> [EngineOptionState]
    /// Changes a switch and refreshes composition/candidates without committing input.
    func setOption(_ name: String, value: Bool) throws -> EngineSnapshot

    /// Composition display request: when it returns true and a composition is active, the
    /// engine-mapped snapshot must carry the highlighted candidate's trusted spelling.
    /// `InputSession` installs it for the *actual* current layout and it is evaluated within
    /// the same engine call, so snapshots produced on a failure-fallback path also use the
    /// actual layout (not the target layout). Default nil = never requested (the demo
    /// engine / plain 26-key layouts do no candidate probing).
    var spellingDemand: (@Sendable () -> Bool)? { get set }

    /// Read-only query for the spelling report reachable for the last `abc` segment of the
    /// current composition (schema-agnostic: all interpretations of the current segment
    /// proven by the live prism/segment graph); nil if it cannot be proven. This is a
    /// *protocol requirement* (not just an extension method) so real implementations and test
    /// stubs take effect through existential dynamic dispatch. A protocol extension supplies
    /// a default (nil), so existing engines need no change.
    func ambiguitySpellings() throws -> AmbiguitySpellingsReport?

    /// Rewrites the tail segment to a proven spelling (CAS; re-validated engine-side, opaque alias). Default unsupported.
    func applyAmbiguitySpelling(
        expectedInput: String, segment: Range<Int>,
        option: String
    ) throws -> AmbiguityApplyOutcome

    /// Restores a locked tail segment to the original reduced code (CAS; re-validated engine-side). Default unsupported.
    func restoreAmbiguitySpelling(
        expectedInput: String, segment: Range<Int>,
        expectedOption: String,
        reducedCode: String
    ) throws -> AmbiguityApplyOutcome
}

public extension EngineBackend {
    func readCandidatesWithReadings(fromIndex: Int, count: Int) throws -> [ReadingCandidate]? { nil }
    func wordCompletions(prefix: String, schemaID: String, limit: Int) throws -> [String]? { nil }
    func wordCompletionSchemas(sourceSchemaID: String) throws -> [String] { [] }
    func releaseWordCompletions() {}
    func verifiedHighlightedReading(
        absoluteIndex: Int, expectedText: String,
        physicalLayoutEligible: Bool
    ) throws -> String? { nil }
}

public extension EngineBackend {
    var inputUnavailableReason: String? { nil }
    func validateSchema(_ schemaID: String) throws {}

    /// No dedicated clear API by default: falls back to Esc (demo engine and test stubs keep this).
    /// The real engine: see `RimeBackend.cancelComposition()` (librime `clear_composition`).
    func cancelComposition() throws -> EngineSnapshot { try processKey("Esc") }
    /// Dismisses post-commit prediction (`EngineSnapshot.isPrediction`) without committing
    /// any candidate. Default: return unchanged when there is none, otherwise hand Esc to
    /// the scheme (librime-predict's predictor dismisses on Esc).
    func dismissPrediction() throws -> EngineSnapshot {
        let snapshot = currentSnapshot()
        guard snapshot.isPrediction else { return snapshot }
        var updated = try processKey("Esc")
        updated.committed = ""
        return updated
    }
    var availableSchemas: [KeyboardSchemaDescriptor] { [] }
    func spellerAlphabet(schemaID: String) -> String? { availableSchemas.first { $0.id == schemaID }?.alphabet }
    func optionStates() throws -> [EngineOptionState] { [] }
    /// No absolute selection by default: falls back to in-page selection only when the target
    /// absolute index is on the current page; cross-page requests fail explicitly (the host
    /// must not commit a concatenated index as an in-page index).
    func selectCandidateAbsolute(_ index: Int) throws -> EngineSnapshot {
        let snapshot = currentSnapshot()
        guard snapshot.pageSize > 0 else { return try selectCandidate(index) }
        guard index >= 0, index / snapshot.pageSize == snapshot.pageIndex else {
            throw EngineBackendError.operationFailed("当前引擎不支持跨页绝对选词")
        }
        return try selectCandidate(index % snapshot.pageSize)
    }
    /// No read-only cross-page candidate fetching by default.
    var supportsReadOnlyBrowsing: Bool { false }
    func readCandidates(fromIndex: Int, count: Int) throws -> [Candidate] { [] }
    func setOption(_ name: String, value: Bool) throws -> EngineSnapshot {
        throw EngineBackendError.operationFailed("当前输入方案不支持选项 \(name)")
    }
    /// No spelling requested by default; only the real engine overrides it with a stored
    /// property. The protocol extension's setter is a no-op so the demo engine needs no change.
    var spellingDemand: (@Sendable () -> Bool)? {
        get { nil }
        set {}
    }
}

// MARK: - Composition spelling disambiguation (default unsupported; existing engines/stubs unchanged)

public extension EngineBackend {
    /// Read-only query for the spelling report reachable for the last `abc` segment of the
    /// current composition (schema-agnostic: all interpretations of the current segment
    /// proven by the live prism/segment graph); nil if it cannot be proven.
    /// Default (demo engine / test stubs / legacy backends) = nil; never guesses.
    func ambiguitySpellings() throws -> AmbiguitySpellingsReport? { nil }

    /// Rewrites the tail segment to a proven spelling (CAS; re-validated engine-side, opaque alias). Default unsupported.
    func applyAmbiguitySpelling(
        expectedInput: String, segment: Range<Int>,
        option: String
    ) throws -> AmbiguityApplyOutcome { .unsupported }

    /// Restores a locked tail segment to the original reduced code (CAS; re-validated engine-side). Default unsupported.
    func restoreAmbiguitySpelling(
        expectedInput: String, segment: Range<Int>,
        expectedOption: String,
        reducedCode: String
    ) throws -> AmbiguityApplyOutcome { .unsupported }
}

// MARK: - Demo engine provider (tests only; the production path never calls it)
//
// RimeBridge is a separate Swift package (it does not depend on this one) and its
// RimeEngine does not conform to this protocol. The real production engine adapter lives
// in Apps/SharedKeyboard (RimeBackend etc.) and is chosen by the app layer; this package
// never imports the bridge module. Only an explicitly labeled demo constructor is provided
// here for KeyboardCore unit tests and self-tests; the production path must never quietly fall back to the demo engine.

public enum EngineProvider {
    /// Demo engine (kind == .demoSimulator). For explicit tests/self-checks only; the
    /// production UI engine comes from RimeBackend in Apps/SharedKeyboard.
    public static func makeDemoEngine() -> EngineBackend {
        DemoEngine()
    }
}
