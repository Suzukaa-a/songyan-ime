import CandidateKit
import Combine
import Foundation
import KeyboardCore
import LayoutKit
import OSLog
import UIKit

extension KeyboardController {
    // MARK: Composition disambiguation (schema-independent)

    /// The sole disambiguation eligibility predicate: Chinese + composing + the physical definition's
    /// structure proves compact-spelling support.
    ///
    /// It deliberately ignores `KeyboardLayoutKind`: `layout` describes input method/encoding, and a
    /// 26-key definition mislabeled as `phone9`/`merged14` in `builtinLayout` would otherwise pass and
    /// get disambiguation queries. The panel computes the physical capability from the real
    /// `LayoutDefinition` and injects it (see `updateCompactSpellingLayout(_:)`); default is fail-closed.
    var ambiguityEligible: Bool {
        !retired && !isEnglishMode && snapshot.isComposing && session.compactSpellingLayout
    }

    /// Injects the current physical definition's capability and identity together (same source, same call, so they cannot diverge).
    public func updateCompactSpellingContext(
        eligible: Bool,
        numericTransport: Bool = false,
        definitionIdentity: LayoutRuntimeIdentity,
        readingKeys: [Character: Character] = [:]
    ) {
        currentDefinitionIdentity = definitionIdentity
        if readingKeyMap != readingKeys {
            readingKeyMap = readingKeys
            syncReadingCoverage()
        }
        let changed =
            session.compactSpellingLayout != eligible
            || session.numericTransportLayout != numericTransport
        session.compactSpellingLayout = eligible
        session.numericTransportLayout = numericTransport
        if changed { refreshAmbiguityPicker() }
    }

    /// Compatibility entry: updates the capability only and leaves the injected definition identity unchanged.
    public func updateCompactSpellingLayout(_ value: Bool) {
        updateCompactSpellingContext(
            eligible: value,
            numericTransport: session.numericTransportLayout,
            definitionIdentity: currentDefinitionIdentity,
            readingKeys: readingKeyMap)
    }

    func syncReadingCoverage() {
        readingFilter.setCoverage(
            ReadingInputCoverage(
                input: session.snapshot.rawInput,
                keyForLetter: readingKeyMap, exactKeys: exactTokenLetters))
    }

    /// Runs one synchronous switch with the picker held still; a switch that succeeds clears the picker.
    func performLayoutSwitch(_ switchLayout: () -> Bool) {
        layoutSwitchInFlight = true
        let ok = switchLayout()
        layoutSwitchInFlight = false
        if ok {
            ambiguityPicker.clear()
            ambiguityReportSource = nil
        }
        refreshAmbiguityPicker()
    }

    /// Refreshes the picker. While locked, keeps the lock (unless the engine's raw input no longer matches it); when unlocked, re-queries.
    ///
    /// It does not re-evaluate mid-switch: an `onUpdate → refresh` fired by the session would see
    /// eligibility off and drop the lock that a failed switch must keep.
    func refreshAmbiguityPicker() {
        guard !layoutSwitchInFlight else { return }
        guard ambiguityEligible else {
            ambiguityDebounceTask?.cancel()
            ambiguityReadID = nil
            ambiguityPicker.clear()
            ambiguityReportSource = nil
            return
        }
        if ambiguityPicker.phase == .locked {
            ambiguityDebounceTask?.cancel()
            ambiguityReadID = nil
            if ambiguityPicker.lock?.rewrittenInput != snapshot.rawInput {
                ambiguityPicker.clear()
                ambiguityReportSource = nil
            }
            return
        }
        let revision = session.compositionRevision
        let input = snapshot.rawInput
        // EngineBackend is not Sendable; its calls are serialized on EngineOpQueue.
        nonisolated(unsafe) let engine = session.engine
        let layout = session.layout
        let schemaID = session.selectedSchemaID
        let definitionIdentity = currentDefinitionIdentity
        let source = AmbiguityReportSource(
            engine: ObjectIdentifier(engine), schemaID: schemaID,
            layout: layout, definitionIdentity: definitionIdentity)
        if ambiguityPicker.phase == .available, ambiguityPicker.revision == revision,
            ambiguityPicker.report?.revisionInput == input, ambiguityReportSource == source
        {
            return
        }
        ambiguityPicker.clear()
        let readID = UUID()
        ambiguityReadID = readID
        ambiguityDebounceTask?.cancel()
        ambiguityDebounceTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
            guard let self, ambiguityReadID == readID else { return }
            // Still the owner but no longer applicable: settle the pending flag so a
            // held 9-key rail never waits on a report that will not arrive.
            guard !layoutSwitchInFlight, ambiguityEligible else {
                ambiguityReadID = nil
                return
            }
            let report = try? await EngineOpQueue.async { [liveAmbiguityRead] () -> AmbiguitySpellingsReport? in
                guard liveAmbiguityRead.matches(readID) else { return nil }
                return try engine.ambiguitySpellings()
            }
            await coalescedCompletionTurn()
            guard ambiguityReadID == readID else { return }
            guard !layoutSwitchInFlight,
                ambiguityEligible, ambiguityPicker.phase != .locked,
                session.engine === engine, session.compositionRevision == revision,
                snapshot.rawInput == input, session.layout == layout,
                session.selectedSchemaID == schemaID,
                currentDefinitionIdentity == definitionIdentity
            else {
                ambiguityReadID = nil
                return
            }
            ambiguityReadID = nil
            ambiguityReportSource = report == nil ? nil : source
            ambiguityPicker.update(report: report, revision: revision, isEligible: true)
            settleRailSelection()
            let summary =
                "\(report == nil ? 0 : 1):\(report?.options.count ?? 0):\(report?.isComplete == true ? 1 : 0):\(report?.isLockable == true ? 1 : 0):\(ambiguityPicker.showsPicker ? 1 : 0)"
            if summary != lastAmbiguityDiagnostic {
                lastAmbiguityDiagnostic = summary
                KeyboardLifecycleDiagnostics.emit(
                    "ambiguity.report",
                    [
                        "available": report == nil ? "0" : "1",
                        "options": String(report?.options.count ?? 0),
                        "complete": report?.isComplete == true ? "1" : "0",
                        "lockable": report?.isLockable == true ? "1" : "0",
                        "visible": ambiguityPicker.showsPicker ? "1" : "0",
                    ])
            }
        }
    }

    /// Selects a composition option (only from report.lockable). CAS; never selects, commits, or inserts a literal.
    public func selectAmbiguityOption(_ option: String) {
        guard ambiguityEligible,
            case .available = ambiguityPicker.phase,
            let report = ambiguityPicker.report,
            ambiguityPicker.accepts(
                option: option, revision: session.compositionRevision,
                input: snapshot.rawInput)
        else {
            ambiguityPicker.fail("组合已过期，请重新输入")
            return
        }
        let originalInput = report.revisionInput
        let segment = report.segment
        let outcome = session.applyAmbiguityOption(
            option, expectedInput: originalInput,
            segment: segment)
        switch outcome {
        case .applied:
            let newInput = session.snapshot.rawInput
            let suffix = originalInput.utf8.count - segment.upperBound
            let end = max(segment.lowerBound, newInput.utf8.count - suffix)
            ambiguityPicker.markLocked(
                option: option, originalInput: originalInput,
                originalSegment: segment, rewrittenInput: newInput,
                rewrittenSegment: segment.lowerBound..<end)
            refresh()
        default:
            ambiguityPicker.fail(Self.ambiguityFailureMessage(outcome))
            refresh()
        }
    }

    /// Undoes the composition: restores the locked segment to the original reduced code. On failure it
    /// keeps the lock and surfaces an observable error, never silently carrying a lock across states
    /// (the next attempt tries restore first again).
    @discardableResult
    public func undoAmbiguityLock() -> Bool {
        guard let lock = ambiguityPicker.lock, ambiguityEligible else {
            ambiguityPicker.clear()
            return false
        }
        let reduced = Self.substring(lock.originalInput, utf8Range: lock.originalSegment)
        let outcome = session.restoreAmbiguity(
            expectedInput: lock.rewrittenInput,
            segment: lock.rewrittenSegment,
            expectedOption: lock.chosenOption,
            reducedCode: reduced)
        switch outcome {
        case .applied:
            ambiguityPicker.markUnlocked()
            refresh()
            return true
        default:
            let message = Self.ambiguityFailureMessage(outcome)
            ambiguityPicker.markRestoreFailed(message)
            inputError = message
            onInputError?(message)
            refresh()
            return false
        }
    }

    /// Restores before further input (only when locked). Returns true if the new key may be processed.
    func restoreAmbiguityBeforeContinuedInput() -> Bool {
        guard ambiguityPicker.phase == .locked else { return true }
        guard ambiguityEligible else {
            ambiguityPicker.clear()
            return true
        }
        let restored = undoAmbiguityLock()
        if !restored {
            // Never append the new key after an alias/canonical code, which would produce a mixed code.
            inputError = ambiguityPicker.message ?? "撤销组合失败，已取消本次输入"
            onInputError?(inputError ?? "")
        }
        return restored
    }

    private static func ambiguityFailureMessage(_ outcome: AmbiguityApplyOutcome) -> String {
        switch outcome {
        case .applied: return ""
        case .stale: return "组合已过期，请重新输入"
        case .unsupported: return "当前输入方案不支持组合锁定"
        case .invalid: return "组合不合法，已取消"
        case .failed: return "组合锁定未完成，请检查输入后重试"
        case .failedRollbackUnverified: return "组合锁定失败且未能确认还原，请重新输入"
        }
    }

    /// Whether to show the disambiguation UI: the same eligibility as `ambiguityEligible`, minus the
    /// transient "composing" condition. A 26-key definition (even a mislabeled builtin) is therefore always false: no UI.
    public var usesAmbiguityPickerUI: Bool { !isEnglishMode && session.compactSpellingLayout }

    /// Sole input assembly for the panel header's content decision: `KeyboardPanelView` consumes it and
    /// hands it to `CandidateHeaderVisibility.showsHeader` to decide whether the bar draws the real
    /// input or a generic idle description. It does not feed height computation: the candidate bar
    /// takes the same fixed budget in every state (`KeyboardPanelGeometry.fixedPanelHeight`), so the
    /// host and the panel need no same-frame height negotiation. The view layer passes `statusMessage`
    /// and `hasAmbiguitySlot`: on 9-key the real readings and composition lock live in the left column,
    /// so the top bar must not assume a visible picker because of a left-column control.
    public func headerVisibilityInput(statusMessage: String?, hasAmbiguitySlot: Bool = true)
        -> CandidateHeaderVisibilityInput
    {
        CandidateHeaderVisibilityInput(
            isEnglish: isEnglishMode,
            hasCandidates: !snapshot.candidates.isEmpty,
            hasStatus: statusMessage != nil,
            // Eligibility + real query result: a 26-key definition yields zero after both gates.
            hasAmbiguityPicker: hasAmbiguitySlot && ambiguityPicker.showsPicker,
            hasCompositionFallback: !isEnglishMode && keyboardCompositionFallback != nil,
            isReadingFiltering: session.compactSpellingLayout && !isEnglishMode && readingFilter.isFiltering)
    }

    /// Extracts a substring from the whole raw input by UTF-8 byte range (raw input is ASCII code).
    static func substring(_ input: String, utf8Range: Range<Int>) -> String {
        let bytes = Array(input.utf8)
        guard utf8Range.lowerBound >= 0, utf8Range.upperBound <= bytes.count,
            utf8Range.lowerBound <= utf8Range.upperBound
        else { return "" }
        return String(decoding: bytes[utf8Range.lowerBound..<utf8Range.upperBound], as: UTF8.self)
    }
}
