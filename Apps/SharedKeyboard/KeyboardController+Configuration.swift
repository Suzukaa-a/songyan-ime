import CandidateKit
import Combine
import Foundation
import KeyboardCore
import LayoutKit
import OSLog
import UIKit

extension KeyboardController {
    public func selectSchema(_ id: String) { session.selectSchema(id) }
    public func revalidateCurrentSchema() { session.revalidateCurrentSchema() }
    /// Layout switch via the controller's direct entry. Re-selecting the current layout/schema is a no-op.
    /// A real switch clears the ambiguity picker; a failed one keeps it and the previous qualification.
    public func selectLayout(_ layout: KeyboardLayoutKind, boundSchemaID: String? = nil) {
        guard !retired else { return }
        let needsTransition =
            boundSchemaID.map { layout != session.layout || $0 != session.selectedSchemaID }
            ?? (layout != session.layout)
        guard needsTransition else { return }
        performLayoutSwitch {
            if let boundSchemaID {
                session.select(layout: layout, boundSchemaID: boundSchemaID)
            } else {
                session.select(layout: layout)
            }
            return session.layout == layout
                && (boundSchemaID == nil || session.selectedSchemaID == boundSchemaID)
        }
    }

    func reportSuccessfulSelectionChange() {
        let change = KeyboardSelectionChange(schemaID: selectedSchemaID, layout: layout)
        successfulChange = change
        onSelectionChanged?(change)
    }

    @discardableResult
    public func discardComposition() -> Bool {
        inputError = nil
        let completed = session.discardComposition()
        // Do not drop the only restore token before cancellation is proven.
        // A failed cancellation leaves the internal canonical/alias input live.
        if completed { ambiguityPicker.clear() }
        return completed
    }

    @discardableResult
    public func commitComposition() -> Bool {
        inputError = nil
        if session.compactSpellingLayout && readingFilter.isFiltering { return confirmReadingTarget() }
        let completed = session.commitComposition()
        // `refresh()` normally clears the picker when composition ends. Keep
        // the lock on failure so a later code key must still restore first.
        if completed { ambiguityPicker.clear() }
        return completed
    }

    /// Shared by keycaps, full SymbolLibrary, public confirmation and mode entry.
    /// Partial selection preserves the remaining composition and cancels this
    /// compound action. No fallback to the now-hidden engine highlight.
    func confirmReadingTarget() -> Bool {
        guard session.compactSpellingLayout, readingFilter.isFiltering else { return true }
        guard readingFilter.revision == session.compositionRevision,
            let first = readingFilter.matches.first
        else { return false }
        return session.confirmCandidateAbsolute(first.index) == .completed
    }

    @discardableResult
    public func prepareForConfigurationChange() -> Bool {
        guard !retired else { return false }
        inputError = nil
        var completed = false
        performLayoutSwitch {
            completed = session.prepareForConfigurationChange()
            return completed
        }
        return completed
    }

    public func reloadOptions() {
        guard !retired else { return }
        session.reloadOptions()
        if let message = (session.engine as? RimeBackend)?.lastErrorText {
            Self.diagnosticLogger.error("option reload failed: \(message, privacy: .private)")
            optionError = "无法读取当前方案的选项，请重试。"
        }
    }

    public func setOption(_ name: String, value: Bool) {
        guard !retired else { return }
        do {
            try session.setOption(name, value: value)
            optionError =
                (session.engine as? RimeBackend)?.optionPersistenceError == nil
                ? nil : "选项已在本次会话生效，但未能保存，请重试。"
        } catch {
            Self.diagnosticLogger.error("option save failed: \(String(describing: error), privacy: .private)")
            optionError = "未能保存选项，请重试。"
        }
    }
}
