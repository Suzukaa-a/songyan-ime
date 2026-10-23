import Combine
import Foundation
import KeyboardCore

/// SwiftUI observable state for quick insert. All real logic lives in `KeyboardCore.QuickInsertCore`;
/// this layer only mirrors `@Published` values and forwards to the main thread. It never touches host text or reads the pasteboard.
///
/// Production wiring (the shared session binds it to the single commit exit):
/// ```
/// let state = QuickInsertState()
/// state.core.dispatchInsert = { text in /* return whether the host accepted the delivery */ false }
/// state.core.confirmComposition = { controller.commitComposition() }  // returns true when there is no composition
/// // In session.onCommit / the commit exit, also call:
/// state.recordCommitted(text)          // records Chinese candidates, direct English, multi-line literals
/// // On focus loss / host switch / field change:
/// state.resetContext()                 // clears only the in-memory repeat target; format preference is kept
/// ```
@MainActor
public final class QuickInsertState: ObservableObject {
    public let core: QuickInsertCore

    @Published public private(set) var hasRepeatableText: Bool
    @Published public private(set) var repeatPreview: String?
    @Published public private(set) var selectedFormat: QuickInsertDateFormat

    private var commitRecordingSuppressionDepth = 0

    public init(core: QuickInsertCore) {
        self.core = core
        self.hasRepeatableText = core.hasRepeatableText
        self.repeatPreview = core.repeatPreview
        self.selectedFormat = core.selectedFormat
        core.onChange = { [weak self] in self?.refresh() }
    }

    /// Convenience initializer: everything except persistence and the clock uses system defaults; wiring code can then adjust `core`'s properties.
    public convenience init(
        formatStore: QuickInsertFormatStore = QuickInsertFormatStore(),
        now: @escaping () -> Date = { Date() },
        calendar: Calendar? = nil,
        insert: @escaping (String) -> Void = { _ in },
        confirmComposition: @escaping () -> Bool = { true }
    ) {
        self.init(
            core: QuickInsertCore(
                formatStore: formatStore,
                now: now,
                calendar: calendar ?? QuickInsertCore.systemCalendar(),
                insert: insert,
                confirmComposition: confirmComposition))
    }

    /// Called from the single commit exit: records one real, non-empty plain commit (Chinese/English/multi-line).
    public func recordCommitted(_ text: String) {
        guard commitRecordingSuppressionDepth == 0 else { return }
        core.recordCommitted(text)
    }

    /// External payloads still go through the single commit exit but skip the repeat cache; synchronous re-entry does not resume recording early.
    @discardableResult
    public func withoutRecordingCommits(_ operation: () -> Bool) -> Bool {
        commitRecordingSuppressionDepth += 1
        defer { commitRecordingSuppressionDepth -= 1 }
        return operation()
    }

    /// Focus loss / host switch / field change: clears this session's repeat target (format preference is kept).
    public func resetContext() {
        core.resetContext()
    }

    /// Repeats the most recent commit (captures the original target, confirms the current composition, then inserts once).
    /// With no record or a failed confirmation it inserts nothing and returns false.
    @discardableResult
    public func performRepeat() -> Bool {
        core.performRepeat()
    }

    /// Inserts the given date/time format (computed at tap time, and remembers the format).
    @discardableResult
    public func insertDateFormat(_ format: QuickInsertDateFormat) -> Bool {
        core.insertDateFormat(format)
    }

    /// Inserts the currently remembered format.
    @discardableResult
    public func insertSelectedFormat() -> Bool {
        core.insertDateFormat(selectedFormat)
    }

    /// Display text computed on demand (re-evaluated on every call, so it is correct across midnight).
    public func formattedText(_ format: QuickInsertDateFormat) -> String {
        core.formattedText(format)
    }

    private func refresh() {
        // Assign only on change: every commit calls back here, and even an unchanged @Published write triggers a redraw.
        if hasRepeatableText != core.hasRepeatableText { hasRepeatableText = core.hasRepeatableText }
        if repeatPreview != core.repeatPreview { repeatPreview = core.repeatPreview }
        if selectedFormat != core.selectedFormat { selectedFormat = core.selectedFormat }
    }
}
