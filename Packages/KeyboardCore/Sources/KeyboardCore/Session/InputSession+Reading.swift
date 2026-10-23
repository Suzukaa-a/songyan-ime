import Foundation

extension InputSession {
    // MARK: Composition spelling disambiguation (read-only report + CAS apply/restore)

    /// Read-only spelling report for the tail segment of the current composition (schema-independent);
    /// returns nil when it can't be proven (no error, no guessing).
    ///
    /// Physical-structure gate: the engine is reached only when the current definition is proven to
    /// be a compact-spelling layout (`compactSpellingLayout`); otherwise nil is returned without
    /// querying. Callers need not re-check.
    public func ambiguitySpellings() -> AmbiguitySpellingsReport? {
        drainPendingCodes()
        guard compactSpellingLayout, inputAvailable() else { return nil }
        do { return try engine.ambiguitySpellings() } catch {
            onError?(error)
            return nil
        }
    }

    /// Read-only reading browse (engine candidate pronunciations). `nil` = not authorized or unsupported by the backend; callers terminate normally.
    ///
    /// Shares the physical-structure gate with `ambiguitySpellings()`: no query on non-compact layouts.
    public func readCandidatesWithReadings(fromIndex: Int, count: Int) throws -> [ReadingCandidate]? {
        guard compactSpellingLayout else { return nil }
        return try engine.readCandidatesWithReadings(fromIndex: fromIndex, count: count)
    }

    /// CAS select: on success refreshes from the engine's real post-state (`apply`; produces no commit).
    ///
    /// Physical-structure gate (same qualification as the read-only query): non-compact layouts
    /// return `.unsupported` and never reach the engine's rewrite. The UI layer
    /// (`KeyboardController`) has its own guard, but this public API can't rely on callers: a 26-key
    /// definition mislabelled `phone9`/`merged14` must fail closed here.
    @discardableResult
    public func applyAmbiguityOption(
        _ option: String, expectedInput: String,
        segment: Range<Int>
    ) -> AmbiguityApplyOutcome {
        drainPendingCodes()
        guard compactSpellingLayout, inputAvailable() else { return .unsupported }
        do {
            let outcome = try engine.applyAmbiguitySpelling(
                expectedInput: expectedInput, segment: segment, option: option)
            if outcome == .applied { _ = apply(engine.currentSnapshot()) }
            return outcome
        } catch {
            onError?(error)
            return .failed
        }
    }

    /// CAS undo: restores a locked segment to its original reduced code; refreshes from the real post-state on success.
    ///
    /// Same gate as `applyAmbiguityOption`: non-compact layouts return `.unsupported` and never reach the engine's restore rewrite.
    @discardableResult
    public func restoreAmbiguity(
        expectedInput: String, segment: Range<Int>,
        expectedOption: String,
        reducedCode: String
    ) -> AmbiguityApplyOutcome {
        drainPendingCodes()
        guard compactSpellingLayout, inputAvailable() else { return .unsupported }
        do {
            let outcome = try engine.restoreAmbiguitySpelling(
                expectedInput: expectedInput, segment: segment,
                expectedOption: expectedOption, reducedCode: reducedCode)
            if outcome == .applied { _ = apply(engine.currentSnapshot()) }
            return outcome
        } catch {
            onError?(error)
            return .failed
        }
    }

    // MARK: Read-only cross-page browsing (doesn't change the engine's current page/highlight)

    /// Whether the engine supports read-only cross-page candidate reads.
    public var supportsReadOnlyBrowsing: Bool { engine.supportsReadOnlyBrowsing }

    /// Read-only fetch of the candidates of a page (by absolute index offset). It doesn't change the
    /// engine's current page/highlight/selected candidate and doesn't trigger `apply`/`onUpdate`,
    /// so host marked text is untouched.
    ///
    /// Error / termination semantics (a failure must never be folded into empty, or the page would be skipped for good):
    ///   * browsing unsupported / no paging (pageSize ≤ 0) / invalid page → returns `[]`
    ///     (normal termination; callers must not retry indefinitely);
    ///   * engine unavailable or the underlying read throws → `throw` (retryable);
    ///   * an empty/short page on success = no more candidates (true EOF); ends normally.
    public func readCandidatePage(pageIndex: Int) throws -> [Candidate] {
        let size = snapshot.pageSize
        guard supportsReadOnlyBrowsing, size > 0, pageIndex >= 0 else { return [] }
        return try engine.readCandidates(fromIndex: pageIndex * size, count: size)
    }
}
