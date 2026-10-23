import Foundation
import KeyboardCore
import LayoutKit

/// The **independent** state model of the composition disambiguation picker (does not reuse `CandidateReadingFilter`).
///
/// Responsibilities:
///   * Consumes only engine-proven `AmbiguitySpellingsReport`s; `options` takes only `lockable` entries and
///     never builds a button for a non-lockable one; `allSpellings` is for diagnostics. The report's semantics are
///     **schema-agnostic** (pinyin/shuangpin/shape code/zhuyin/dialects alike); this model makes no pinyin assumptions.
///   * Binds `revisionInput` + the tail segment's raw byte range + `lockMode` and rejects stale refreshes accordingly.
///   * Single lock: records the original whole input / original reduced span / chosen option /
///     rewritten whole input / rewritten segment range, so "undo composition" can restore precisely.
///   * Four explicit states `idle / available / locked / error`; failures are never silent and never swallow input.
///
/// This model never touches the engine; engine calls and side effects are always done by the Controller.
public struct AmbiguitySpellingPicker: Equatable, Sendable {

    public enum Phase: Equatable, Sendable {
        case idle
        case available
        case locked
        case error
    }

    /// Lock record. `rewrittenSegment` is the segment the engine actually wrote (canonical or alias).
    public struct Lock: Equatable, Sendable {
        public let originalInput: String
        public let originalSegment: Range<Int>
        public let chosenOption: String
        public let rewrittenInput: String
        public let rewrittenSegment: Range<Int>

        public init(
            originalInput: String, originalSegment: Range<Int>,
            chosenOption: String, rewrittenInput: String,
            rewrittenSegment: Range<Int>
        ) {
            self.originalInput = originalInput
            self.originalSegment = originalSegment
            self.chosenOption = chosenOption
            self.rewrittenInput = rewrittenInput
            self.rewrittenSegment = rewrittenSegment
        }
    }

    public private(set) var phase: Phase = .idle
    /// The report currently available for display/selection (`options` already contains only lockable entries).
    public private(set) var report: AmbiguitySpellingsReport?
    /// For diagnostics: all reachable spellings (may include non-lockable ones). Never build buttons from them.
    public private(set) var allSpellings: [String] = []
    public private(set) var lock: Lock?
    /// The latest error / rejection reason (user-visible feedback).
    public private(set) var message: String?
    /// Composition revision bound at the last refresh (`InputSession.compositionRevision`).
    public private(set) var revision: Int = 0

    public init() {}

    /// Whether there is a choice bar to show (>= 2 lockable options and not truncated). True while locked (the undo entry).
    public var showsPicker: Bool {
        switch phase {
        case .available: return true
        case .locked: return true
        case .idle, .error: return false
        }
    }

    /// Once locked, the undo entry is always reachable (even if the current segment is no longer ambiguous).
    public var canUndoLock: Bool { phase == .locked && lock != nil }

    /// Whether the lock is still valid for the current raw input (CAS identity unchanged).
    ///
    /// The criterion is the **rewritten** input: the lock records the segment the engine actually wrote (canonical or alias),
    /// and only while it still equals the real raw input has the opaque token not been confirmed/overwritten, so restoring is allowed.
    public func lockMatches(rawInput: String) -> Bool {
        guard let lock else { return false }
        return lock.rewrittenInput == rawInput
    }

    /// Binding check before committing an option: revision (composed revision) + raw input + segment range
    /// must match those at refresh time, otherwise it is stale and an outdated tap is never committed.
    public func accepts(
        option: String, revision currentRevision: Int,
        input currentInput: String
    ) -> Bool {
        guard phase == .available, let report, report.options.contains(option) else { return false }
        return revision == currentRevision && report.revisionInput == currentInput
    }

    /// Refreshes with the latest report. Clears when `isEligible` is false (non-Chinese / not composing / 26-key etc.).
    /// Binds the revision; `revisionInput` and the segment range come from the report itself and are CAS-checked again at commit.
    public mutating func update(
        report newReport: AmbiguitySpellingsReport?,
        revision newRevision: Int,
        isEligible: Bool
    ) {
        revision = newRevision
        guard isEligible else {
            clear()
            revision = newRevision
            return
        }
        // The controller has already verified that the live raw input still
        // equals `lock.rewrittenInput`. Once locked, a follow-up read-only
        // report may legitimately be nil, singleton, or otherwise no longer
        // ambiguous because the internal canonical/alias did its job. Such a
        // report must never discard the only restore token.
        if phase == .locked, lock != nil {
            if let newReport { allSpellings = newReport.allSpellings }
            report = nil
            return
        }
        guard let newReport else {
            clear()
            revision = newRevision
            return
        }
        allSpellings = newReport.allSpellings
        // A truncated set must not be treated as the complete choice set: hide it and record it; no picker bar.
        if !newReport.isComplete {
            report = nil
            lock = nil
            phase = .idle
            message = "拼音组合列表被截断，未能完整显示。"
            return
        }
        // Fewer than 2 lockable options = unambiguous: not shown, but diagnostics are kept.
        guard newReport.isAmbiguous, newReport.isLockable else {
            report = nil
            lock = nil
            phase = .idle
            message = nil
            return
        }
        report = newReport
        if phase != .locked { phase = .available }
        // A locked picker keeps its lock while the underlying input still carries it.
        if phase == .available { message = nil }
    }

    /// Records a successful selection (called after the apply CAS succeeds). `rewrittenInput`/`rewrittenSegment`
    /// are computed by the Controller from the real raw input after apply.
    public mutating func markLocked(
        option: String, originalInput: String,
        originalSegment: Range<Int>, rewrittenInput: String,
        rewrittenSegment: Range<Int>
    ) {
        lock = Lock(
            originalInput: originalInput, originalSegment: originalSegment,
            chosenOption: option, rewrittenInput: rewrittenInput,
            rewrittenSegment: rewrittenSegment)
        report = nil
        phase = .locked
        message = nil
    }

    /// Selection failed (stale/unsupported/invalid/failed/rollbackUnverified): enter error and
    /// keep no tappable fake button; the caller is responsible for a safe refresh/state clear.
    public mutating func fail(_ reason: String) {
        report = nil
        lock = nil
        phase = .error
        message = reason
    }

    /// Undo failed: **keep the lock** and only record an observable error. The lock must be kept, otherwise the
    /// next ordinary code key would append new code after the alias/canonical and produce a mixed string; while it is kept, the next attempt still tries restore first.
    public mutating func markRestoreFailed(_ reason: String) {
        message = reason
    }

    /// After a successful undo, return to the unlocked state (the caller then refreshes to re-evaluate).
    public mutating func markUnlocked() {
        lock = nil
        report = nil
        phase = .idle
        message = nil
    }

    /// Layout/schema/mode/commit/clear state changes: reset the state completely.
    public mutating func clear() {
        phase = .idle
        report = nil
        allSpellings = []
        lock = nil
        message = nil
    }
}
