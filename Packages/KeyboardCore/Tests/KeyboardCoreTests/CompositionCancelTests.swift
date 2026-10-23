import XCTest

@testable import KeyboardCore

/// Regression: "clear / cancel" during an active composition must not rely on a synthetic `Esc`.
///
/// Real librime (pinned 1.17.0) semantics:
///   * `Esc` → `Editor::CancelComposition`（`src/rime/gear/editor.cc`）：
///         if (!ctx->ClearPreviousSegment()) ctx->Clear();
///     When a previous segment exists (e.g. remaining syllables keep composing after a partial commit) only that segment is rolled back,
///     the composition stays, and `isComposing` remains true;
///   * the dedicated `clear_composition` -> `Session::ClearComposition`
///     （`src/rime/service.cc`）→ `Context::AbortComposition` → `Context::Clear`
///     (`src/rime/context.cc`), which clears unconditionally.
///
/// So the Host "clear" implemented `discardComposition()` with `processKey("Esc")`, which was judged a failure in the state above
/// and popped up "could not cancel the current composition". This file pins that difference with a faithful model stub
/// and drives the **real production function** `InputSession.discardComposition()` to verify the fix.
@MainActor
final class CompositionCancelTests: XCTestCase {

    /// Model stub: `processKey("Esc")` clears only when there is no previous segment;
    /// the dedicated `cancelComposition()` always clears unconditionally.
    private final class PreviousSegmentEngine: EngineBackend {
        let kind: EngineBackendKind = .demoSimulator("previous-segment")
        var dedicatedClearUsed = false
        /// If the dedicated cancel makes the engine also emit a commit, the upper layer must swallow it.
        var dedicatedClearCommit = ""
        private var input = ""
        private var previousSegment = false

        var statusSummary: String { "previous-segment" }
        func setup(sharedDirectory: URL, userDirectory: URL) throws {}
        func selectSchema(_ schemaID: String) throws {}

        func processKey(_ keyValue: String) throws -> EngineSnapshot {
            if keyValue == "Esc" {
                if previousSegment {
                    // Editor::CancelComposition hits ClearPreviousSegment:
                    // only rolls back the previous segment; the remaining composition is kept.
                    previousSegment = false
                } else {
                    input = ""
                }
                return currentSnapshot()
            }
            if keyValue == "\u{08}" {
                if !input.isEmpty { input.removeLast() }
                if input.isEmpty { previousSegment = false }
                return currentSnapshot()
            }
            input.append(keyValue)
            return currentSnapshot()
        }

        /// Partial commit: one candidate is committed, the remaining syllables keep composing -> a previous segment appears.
        func selectCandidate(_ index: Int) throws -> EngineSnapshot {
            previousSegment = true
            var snapshot = currentSnapshot()
            snapshot.committed = "早"
            return snapshot
        }

        func cancelComposition() throws -> EngineSnapshot {
            dedicatedClearUsed = true
            input = ""
            previousSegment = false
            var snapshot = currentSnapshot()
            snapshot.commitTextPreview = ""
            snapshot.committed = dedicatedClearCommit
            return snapshot
        }

        func nextPage() throws -> EngineSnapshot { currentSnapshot() }
        func previousPage() throws -> EngineSnapshot { currentSnapshot() }
        func currentSnapshot() -> EngineSnapshot {
            EngineSnapshot(
                candidates: input.isEmpty ? [] : [Candidate(index: 0, text: input)],
                preedit: input,
                rawInput: input,
                isComposing: !input.isEmpty
            )
        }
        func shutdown() {}
    }

    /// A stub that does not override the dedicated capability: `cancelComposition()` falls back to the default Esc.
    /// Used to confirm "if Esc cannot clear it, failure is still reported" so the fix does not mask the failure surface.
    private final class EscFallbackEngine: EngineBackend {
        let kind: EngineBackendKind = .demoSimulator("esc-fallback")
        var escRejected = false
        private var input = ""
        var statusSummary: String { "esc-fallback" }
        func setup(sharedDirectory: URL, userDirectory: URL) throws {}
        func selectSchema(_ schemaID: String) throws {}
        func processKey(_ keyValue: String) throws -> EngineSnapshot {
            if keyValue == "Esc" {
                if escRejected { throw EngineBackendError.operationFailed("esc rejected") }
                input = ""
                return currentSnapshot()
            }
            input.append(keyValue)
            return currentSnapshot()
        }
        func selectCandidate(_ index: Int) throws -> EngineSnapshot { currentSnapshot() }
        func nextPage() throws -> EngineSnapshot { currentSnapshot() }
        func previousPage() throws -> EngineSnapshot { currentSnapshot() }
        func currentSnapshot() -> EngineSnapshot {
            EngineSnapshot(
                candidates: input.isEmpty ? [] : [Candidate(index: 0, text: input)],
                preedit: input,
                rawInput: input,
                isComposing: !input.isEmpty
            )
        }
        func shutdown() {}
    }

    func testDiscardAfterPartialCommitClearsThroughDedicatedCapability() {
        let engine = PreviousSegmentEngine()
        let session = InputSession(engine: engine, layout: .qwerty26)
        var commits: [String] = []
        var errors = 0
        session.onCommitted = { commits.append($0) }
        session.onError = { _ in errors += 1 }

        session.tap(.code("z"))
        session.tap(.code("c"))
        XCTAssertTrue(session.snapshot.isComposing)

        // Partial commit: "早" committed, the remaining composition kept -> previous segment appears.
        session.selectCandidate(0)
        XCTAssertEqual(commits, ["早"])
        XCTAssertTrue(session.snapshot.isComposing)
        XCTAssertTrue(engine.currentSnapshot().isComposing)

        // The cancel must succeed: the dedicated clear clears unconditionally and produces no new commit.
        XCTAssertTrue(session.discardComposition())
        XCTAssertTrue(engine.dedicatedClearUsed)
        XCTAssertFalse(session.snapshot.isComposing)
        XCTAssertTrue(session.snapshot.candidates.isEmpty)
        XCTAssertEqual(commits, ["早"], "cancel must never commit")
        XCTAssertEqual(errors, 0)
    }

    func testDedicatedCancelCommitIsSuppressed() {
        let engine = PreviousSegmentEngine()
        engine.dedicatedClearCommit = "must not reach document"
        let session = InputSession(engine: engine, layout: .qwerty26)
        var commits: [String] = []
        session.onCommitted = { commits.append($0) }

        session.tap(.code("n"))
        XCTAssertTrue(session.discardComposition())
        XCTAssertFalse(session.snapshot.isComposing)
        XCTAssertTrue(commits.isEmpty, "the commit attached to a dedicated cancel must be swallowed")
    }

    func testEscFallbackSuccessAndFailureAreReportedTruthfully() {
        let engine = EscFallbackEngine()
        let session = InputSession(engine: engine, layout: .qwerty26)
        var errors = 0
        session.onError = { _ in errors += 1 }

        session.tap(.code("n"))
        engine.escRejected = true
        XCTAssertFalse(session.discardComposition())
        XCTAssertTrue(session.snapshot.isComposing, "a failed cancel must keep the real composition")
        XCTAssertEqual(errors, 1)

        engine.escRejected = false
        XCTAssertTrue(session.discardComposition())
        XCTAssertFalse(session.snapshot.isComposing)
    }

    // MARK: - Cancel followed by a state-read failure / session invalidation must not fake success

    /// Controllable engine: can separately simulate "underlying state read failing after the dedicated cancel (clear actually ran)",
    /// "session invalidation" and "cancel returning still composing".
    private final class FailableCancelEngine: EngineBackend {
        enum Outcome {
            /// The dedicated cancel clears and returns the readable post-state.
            case success
            /// The underlying clear ran, but reading the post-state afterwards fails -> must throw.
            case readFailsAfterClear
            /// Session invalidation -> cancel unavailable, must throw.
            case sessionInvalid
            /// Cancel returns a real snapshot that is still composing (clear did not take effect, not a read failure).
            case stillComposing
        }
        let kind: EngineBackendKind = .demoSimulator("failable-cancel")
        var outcome: Outcome = .success
        var clearsPerformed = 0
        var inputUnavailableReason: String?
        private var input = ""

        var statusSummary: String { "failable-cancel" }
        func setup(sharedDirectory: URL, userDirectory: URL) throws {}
        func selectSchema(_ schemaID: String) throws {}
        func processKey(_ keyValue: String) throws -> EngineSnapshot {
            input.append(keyValue)
            return currentSnapshot()
        }
        func selectCandidate(_ index: Int) throws -> EngineSnapshot { currentSnapshot() }
        func nextPage() throws -> EngineSnapshot { currentSnapshot() }
        func previousPage() throws -> EngineSnapshot { currentSnapshot() }
        func currentSnapshot() -> EngineSnapshot {
            EngineSnapshot(
                candidates: input.isEmpty ? [] : [Candidate(index: 0, text: input)],
                preedit: input,
                rawInput: input,
                isComposing: !input.isEmpty
            )
        }
        func shutdown() {}
        func failSession() { input = "" }

        func cancelComposition() throws -> EngineSnapshot {
            switch outcome {
            case .success:
                inputUnavailableReason = nil
                input = ""
                clearsPerformed += 1
                return currentSnapshot()
            case .readFailsAfterClear:
                // The clear itself ran (engine is really non-composing) but the
                // post-state read failed. Returning .empty here is exactly the
                // CC-01 defect; the contract requires throwing instead.
                input = ""
                clearsPerformed += 1
                throw EngineBackendError.operationFailed("post-clear state read failed")
            case .sessionInvalid:
                throw EngineBackendError.engineNotStarted
            case .stillComposing:
                return currentSnapshot()
            }
        }
    }

    func testReadFailureAfterClearKeepsLastTrustedCompositionAndDoesNotAuthorizeClear() {
        let engine = FailableCancelEngine()
        let session = InputSession(engine: engine, layout: .qwerty26)
        var commits: [String] = []
        var errors = 0
        session.onCommitted = { commits.append($0) }
        session.onError = { _ in errors += 1 }

        session.tap(.code("w"))
        session.tap(.code("o"))
        let trusted = session.snapshot
        XCTAssertTrue(trusted.isComposing)
        let revision = session.compositionRevision

        engine.outcome = .readFailsAfterClear
        XCTAssertFalse(session.discardComposition(), "a read failure after cancel must return false")
        XCTAssertEqual(engine.clearsPerformed, 1, "clear actually ran (the read failed after the simulated success)")
        XCTAssertEqual(
            session.snapshot, trusted, "must not apply a fake empty snapshot; keep the last trusted composition")
        XCTAssertTrue(session.snapshot.isComposing)
        XCTAssertEqual(session.compositionRevision, revision, "a failure path must not bump the generation")
        XCTAssertTrue(commits.isEmpty, "cancel never commits")
        XCTAssertEqual(errors, 1)
    }

    func testInvalidSessionCancelFailsWithoutApplying() {
        let engine = FailableCancelEngine()
        let session = InputSession(engine: engine, layout: .qwerty26)
        var errors = 0
        session.onError = { _ in errors += 1 }

        session.tap(.code("n"))
        let trusted = session.snapshot
        engine.outcome = .sessionInvalid
        XCTAssertFalse(session.discardComposition())
        XCTAssertEqual(session.snapshot, trusted)
        XCTAssertEqual(errors, 1)
    }

    func testCancelReturningStillComposingAppliesRealStateAndReturnsFalse() {
        let engine = FailableCancelEngine()
        let session = InputSession(engine: engine, layout: .qwerty26)
        var errors = 0
        session.onError = { _ in errors += 1 }

        session.tap(.code("n"))
        session.tap(.code("i"))
        engine.outcome = .stillComposing
        XCTAssertFalse(session.discardComposition())
        // The returned snapshot is genuine (real remaining composition), not a
        // fabricated empty one: applying it keeps the composition visible.
        XCTAssertTrue(session.snapshot.isComposing)
        XCTAssertEqual(session.snapshot.rawInput, "ni")
        XCTAssertEqual(errors, 1)
    }

    func testIdleUnavailableCancellationReachesEngineAndCanRetry() {
        let engine = FailableCancelEngine()
        let session = InputSession(engine: engine, layout: .qwerty26)
        var document = "existing text"
        var errors = 0
        session.onCommitted = { document += $0 }
        session.onError = { _ in errors += 1 }
        let trusted = session.snapshot
        let revision = session.compositionRevision
        engine.inputUnavailableReason = "unread first key"
        engine.outcome = .readFailsAfterClear
        XCTAssertFalse(session.discardComposition())
        XCTAssertEqual(engine.clearsPerformed, 1)
        XCTAssertEqual(session.snapshot, trusted)
        XCTAssertEqual(session.compositionRevision, revision)
        XCTAssertNotNil(session.inputUnavailableReason)
        XCTAssertEqual(document, "existing text")
        engine.outcome = .success
        XCTAssertTrue(session.discardComposition())
        XCTAssertEqual(engine.clearsPerformed, 2)
        XCTAssertNil(session.inputUnavailableReason)
        XCTAssertGreaterThan(session.compositionRevision, revision)
        XCTAssertEqual(document, "existing text")
        XCTAssertEqual(errors, 1)
    }

    func testNormalPartialCompositionCancelSucceeds() {
        let engine = FailableCancelEngine()
        let session = InputSession(engine: engine, layout: .qwerty26)
        var commits: [String] = []
        var errors = 0
        session.onCommitted = { commits.append($0) }
        session.onError = { _ in errors += 1 }

        session.tap(.code("z"))
        session.tap(.code("c"))
        let before = session.compositionRevision
        XCTAssertTrue(session.discardComposition())
        XCTAssertFalse(session.snapshot.isComposing)
        XCTAssertTrue(session.snapshot.candidates.isEmpty)
        XCTAssertEqual(engine.clearsPerformed, 1)
        XCTAssertGreaterThan(
            session.compositionRevision, before, "the success path should apply and bump the generation")
        XCTAssertTrue(commits.isEmpty)
        XCTAssertEqual(errors, 0)
    }
}
