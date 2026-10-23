import Foundation

// MARK: - Quick insert: fixed date/time formats
//
// A small set of common offline formats, computed on tap from the injected clock. No
// arbitrary scripts, no schema Lua dependency, no code-dictionary changes. Time zone and
// calendar follow the injected Calendar (production = system local).

/// The fixed set of date/time quick-insert formats.
public enum QuickInsertDateFormat: String, CaseIterable, Identifiable, Codable, Equatable, Sendable {
    /// 2026-09-09
    case date = "date"
    /// 2026年9月9日
    case dateChinese = "date-chinese"
    /// 14:30 (24-hour, zero seconds)
    case time = "time"
    /// 2026-09-09 14:30
    case dateTime = "date-time"
    /// 2026年9月9日 14:30
    case dateTimeChinese = "date-time-chinese"

    public var id: String { rawValue }

    /// Chinese title shown in the tool UI.
    public var title: String {
        switch self {
        case .date: return "日期"
        case .dateChinese: return "中文日期"
        case .time: return "时间"
        case .dateTime: return "日期与时间"
        case .dateTimeChinese: return "中文日期与时间"
        }
    }

    /// DateFormatter template; literal Chinese characters are quoted so they aren't read as format letters.
    fileprivate var dateFormatTemplate: String {
        switch self {
        case .date: return "yyyy-MM-dd"
        case .dateChinese: return "yyyy'年'M'月'd'日'"
        case .time: return "HH:mm"
        case .dateTime: return "yyyy-MM-dd HH:mm"
        case .dateTimeChinese: return "yyyy'年'M'月'd'日' HH:mm"
        }
    }
}

/// Date/time text computation (pure). Computed from the given date on every call, never
/// cached; calendar and time zone come from the passed `calendar` (production: system local).
public enum QuickInsertFormatting {
    public static func text(_ format: QuickInsertDateFormat, at date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        // POSIX locale: Arabic digits and a stable format regardless of system region.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format.dateFormatTemplate
        return formatter.string(from: date)
    }
}

/// Persistence for the chosen date/time format. Stores the format only, never any committed text.
public struct QuickInsertFormatStore {
    public static let selectedFormatKey = "quickInsert.selectedDateFormat"

    public var defaults: UserDefaults
    /// False when `defaults` cannot be written (a keyboard without Full Access); the
    /// choice then lives only in the running `QuickInsertCore`.
    public var persists: () -> Bool

    public init(defaults: UserDefaults = .standard, persists: @escaping () -> Bool = { true }) {
        self.defaults = defaults
        self.persists = persists
    }

    public func selectedFormat() -> QuickInsertDateFormat? {
        defaults.string(forKey: Self.selectedFormatKey).flatMap(QuickInsertDateFormat.init(rawValue:))
    }

    public func save(_ format: QuickInsertDateFormat) {
        guard persists() else { return }
        defaults.set(format.rawValue, forKey: Self.selectedFormatKey)
    }
}

// MARK: - Last non-empty commit (in-memory session cache)

/// The last non-empty committed text, cached in memory for the current input session only;
/// the caller clears it with `resetContext()` on focus loss or host switch. User input is
/// never persisted, and neither the clipboard nor host context is read.
public final class QuickInsertRecentText {
    public private(set) var lastCommittedText: String?

    public init() {}

    /// Called from the single commit exit. Whitespace-only commits (a lone space/newline) are ignored and don't clear the existing target.
    public func recordCommitted(_ text: String) {
        guard Self.hasVisibleContent(text) else { return }
        lastCommittedText = text
    }

    /// Clears the session's repeat target on focus loss / host switch / field change.
    public func resetContext() {
        lastCommittedText = nil
    }

    public var hasRepeatableText: Bool { lastCommittedText != nil }

    /// Single-line short preview for display. Repeat insertion always uses the full original text; the preview doesn't truncate it.
    public var repeatPreview: String? { QuickInsertRecentText.preview(for: lastCommittedText) }

    public static func hasVisibleContent(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Collapses any committed text into a one-line preview (multi-line commits with newlines/runs of whitespace stay readable).
    public static func preview(for text: String?, maxCharacters: Int = 24) -> String? {
        guard let text else { return nil }
        let collapsed = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        if collapsed.count <= maxCharacters { return collapsed }
        let head = collapsed.prefix(max(1, maxCharacters - 1))
        return String(head) + "…"
    }
}

// MARK: - Quick insert core (pure logic)

/// Quick insert core: repeat last commit + date/time. No UI/Combine dependency; testable with `swift test`.
///
/// Repeat ordering: capture the original target first, then confirm the current composition
/// with the existing confirm semantics, then insert the captured target and record it back as
/// the last commit (so it can repeat again). Even if the confirm callback records the just-confirmed
/// word through the commit exit, the original target is not polluted.
public final class QuickInsertCore {
    public let recent = QuickInsertRecentText()

    /// Evaluated on every use (production = `{ Date() }`; tests inject a fixed instant to verify midnight rollover).
    public var now: () -> Date
    /// Gregorian calendar + local time zone (production follows the system; tests inject a fixed zone).
    public var calendar: Calendar
    /// Composition confirm: wired to `controller.commitComposition()`; returns true when there is no composition.
    public var confirmComposition: () -> Bool
    /// The single exit that actually commits text to the host (same insertion path as a normal commit).
    public var insert: (String) -> Void
    /// Preferred outlet: a refusal must not become a recent item or a saved format.
    /// The Void outlet remains for adapters that cannot report acceptance.
    public var dispatchInsert: ((String) -> Bool)?
    /// Notifies the outer ObservableObject mirror of state changes (record/reset/insert/format switch).
    public var onChange: (() -> Void)?

    public private(set) var selectedFormat: QuickInsertDateFormat
    private let formatStore: QuickInsertFormatStore

    public init(
        formatStore: QuickInsertFormatStore = QuickInsertFormatStore(),
        now: @escaping () -> Date = { Date() },
        calendar: Calendar? = nil,
        insert: @escaping (String) -> Void = { _ in },
        confirmComposition: @escaping () -> Bool = { true }
    ) {
        self.formatStore = formatStore
        self.selectedFormat = formatStore.selectedFormat() ?? .date
        self.now = now
        self.calendar = calendar ?? QuickInsertCore.systemCalendar()
        self.insert = insert
        self.confirmComposition = confirmComposition
    }

    /// Production default: Gregorian calendar + current system time zone.
    public static func systemCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    // MARK: Convenience reads (outer UI mirror)

    public var lastCommittedText: String? { recent.lastCommittedText }
    public var hasRepeatableText: Bool { recent.hasRepeatableText }
    public var repeatPreview: String? { recent.repeatPreview }

    // MARK: Commit recording and lifecycle

    /// Must be called from the single commit exit to record a non-empty commit that actually reached the host.
    /// Chinese candidate confirmation, direct English input and multi-line literals all arrive through it.
    public func recordCommitted(_ text: String) {
        recent.recordCommitted(text)
        notify()
    }

    /// Focus loss / host switch / field change: clears the session repeat target; the format preference is kept.
    public func resetContext() {
        recent.resetContext()
        notify()
    }

    // MARK: Actions

    /// Repeats the last commit: captures the target, confirms the current composition, then inserts the target once.
    /// Returns false without inserting when there is no record or confirmation fails.
    @discardableResult
    public func performRepeat() -> Bool {
        // Capture must precede confirmation so a confirm callback that records the composed word doesn't alter this target.
        guard let target = recent.lastCommittedText else { return false }
        return deliverAfterConfirmingComposition(target)
    }

    /// Inserts date/time: computed from now() on tap (no stale date across midnight); confirms any
    /// composition first, then remembers the format across reopen.
    @discardableResult
    public func insertDateFormat(_ format: QuickInsertDateFormat) -> Bool {
        let text = formattedText(format)
        guard deliverAfterConfirmingComposition(text) else { return false }
        remember(format)
        return true
    }

    /// Format text computed fresh before display/insertion.
    public func formattedText(_ format: QuickInsertDateFormat) -> String {
        QuickInsertFormatting.text(format, at: now(), calendar: calendar)
    }

    // MARK: Private

    private func deliverAfterConfirmingComposition(_ text: String) -> Bool {
        guard confirmComposition() else { return false }
        if let dispatchInsert {
            guard dispatchInsert(text) else { return false }
        } else {
            insert(text)
        }
        // Only an accepted dispatch may become a repeat target.
        recent.recordCommitted(text)
        notify()
        return true
    }

    private func remember(_ format: QuickInsertDateFormat) {
        guard format != selectedFormat else { return }
        selectedFormat = format
        formatStore.save(format)
        notify()
    }

    private func notify() {
        onChange?()
    }
}
