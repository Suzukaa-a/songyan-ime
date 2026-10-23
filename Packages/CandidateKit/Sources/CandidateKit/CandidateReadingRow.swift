import Foundation
import KeyboardCore
import LayoutKit

// MARK: - Standalone trusted reading row (declared by the physical layout's capability)
//
// Readings/disambiguation must not overlap word candidates. Definitions without an explicit declaration
// derive a reading row from provably compact structures; explicit declarations decide by their capability.
// Candidates and readings use only real engine content; the phone structure uses a left rail instead of an extra top band.
//
// Height ownership: the panel only reports definition eligibility and KeyboardPanelHost grants a fixed
// row height; cold start, before the session/layout registry exist, only reuses the last accepted hint that matches the selected definition.

/// Eligibility and dimensions of the reading row (single source).
public enum CandidateReadingRowPolicy {
    /// Reading row height: one full tappable horizontal cell (the whole cell is the hit area, not just the glyphs).
    /// 32pt gives readings and the word candidates below separate touch bands without leaving a large gap at the keyboard top.
    public static let height: Double = 32
    /// Reading font size: only one step below the candidate words (system default candidate 21pt), easy to
    /// read and hit; a smaller size is hard to read and makes people tap the glyphs below.
    public static let fontSize: Double = 18
    /// Minimum width of each reading cell (height is bounded by the row height; width tops up the hit area).
    public static let minimumCellWidth: Double = 56
    /// Horizontal padding of a reading cell: hit boundaries between adjacent readings do not hug the glyphs.
    public static let cellPaddingX: Double = 12
    /// Reading text sits 4pt below the row center: close to the word row it filters while leaving a clear
    /// gap between the two rows, so it is not mistaken for a candidate comment. The hit region is still the full row.
    public static let textDrop: Double = 4
    /// The shortest a reading row gets when iOS presents less height than the layout
    /// asked for (it kept an earlier presentation's height): one line of reading text.
    /// The row gives up height before the key rows do.
    public static let minimumHeight: Double = 24

    /// The text's offset below the row's top: `textDrop` below centre in a full row,
    /// shrinking with a squeezed row so the text is never clipped.
    public static func textTopPadding(rowHeight: Double) -> Double {
        min(textDrop * 2, max(0, rowHeight - minimumHeight))
    }
    /// How far word-candidate text sits below its row center when a reading row is present: splits the
    /// band so the text keeps the shared `candidateBottomSpace` above the keys.
    public static let candidateDrop: Double =
        (KeyboardPanelGeometry.readingCandidateSpace - KeyboardPanelGeometry.candidateBottomSpace) / 2
    /// How far word-candidate text sits below its row center when there is no reading row: splits the band
    /// into the shared `candidateTopSpace` above the text and `candidateBottomSpace` below it.
    public static let plainCandidateDrop: Double =
        (KeyboardPanelGeometry.candidateTopSpace - KeyboardPanelGeometry.candidateBottomSpace) / 2
    public static let candidateLift: Double = 0

    /// In landscape (compact height) the shell is shorter: the reading row and font each shrink one step to leave height for key rows.
    public static let compactHeight: Double = 28
    public static let compactFontSize: Double = 16

    /// Host granted or not -> budget height.
    public static func height(reserved: Bool, compact: Bool = false) -> Double {
        reserved ? (compact ? compactHeight : height) : 0
    }

    /// The selected definition decides whether its candidate area has a separate reading row.
    /// Phone layouts keep the dedicated leading rail; a missing definition fails closed.
    public static func isEligible(_ definition: LayoutDefinition?) -> Bool {
        guard let definition else { return false }
        return definition.effectiveCandidateArea.reading && !PhoneKeypadStructure.matches(definition)
    }

    /// Phone layouts query the engine for their side rail; other layouts do so when
    /// the selected definition requests a separate reading row.
    public static func needsEngineSpelling(_ definition: LayoutDefinition?) -> Bool {
        guard let definition else { return false }
        return PhoneKeypadStructure.matches(definition) || isEligible(definition)
    }
}

/// Eligibility report from panel to host (a fact, not a height).
public struct CandidateReadingRowReport: Equatable, Sendable {
    /// Whether this layout reserves a word candidate area, independent of input state.
    public var candidateAreaRequired: Bool
    /// Whether the currently resolved physical definition needs a standalone reading row.
    public var eligible: Bool
    /// Resolved definition id (for diagnostics/hints; eligibility itself comes from content).
    public var definitionID: String?
    /// Whether the published layout registry was available at resolution time (false = built-in definition fallback).
    public var resolvedFromRegistry: Bool

    /// The grant describes the current ABC/123 page, not the definition itself.
    public var pageOverride: Bool

    public init(
        eligible: Bool, definitionID: String?, resolvedFromRegistry: Bool,
        candidateAreaRequired: Bool = true, pageOverride: Bool = false
    ) {
        self.candidateAreaRequired = candidateAreaRequired
        self.pageOverride = pageOverride
        self.eligible = eligible
        self.definitionID = definitionID
        self.resolvedFromRegistry = resolvedFromRegistry
    }
}

/// Whether the host accepts a report.
///
/// While the layout registry is still loading asynchronously, the panel falls back to the built-in
/// definition by kind; that is only a **guess** (a DIY definition's physical structure can differ from
/// the built-in of the same kind). Therefore:
///  - source not settled (still loading): not accepted, the last granted value is kept;
///  - registry available: only reports **resolved from the registry** are accepted;
///  - registry read failed / no full access: the built-in definition is the real source and its report is accepted.
public enum CandidateReadingRowGrant {
    public static func accepts(
        _ report: CandidateReadingRowReport,
        layoutSourceSettled: Bool,
        registryAvailable: Bool
    ) -> Bool {
        layoutSourceSettled && report.resolvedFromRegistry == registryAvailable
    }
}

/// Cold-start hint: the eligibility the host last **accepted**, recorded under the layout selection at that time.
///
/// The extension's `loadView` runs before the session and the layout registry and can only read local
/// defaults synchronously. The hint applies only when the recorded selection equals the current one;
/// otherwise the first frame starts ungranted (14-key is not guessed), and once the host settles it
/// corrects through a neutral transition (bottom-anchored, the key area does not move).
///
/// The "selection" is composed by `selectionKey(layoutKind:definitionID:)`: a change of either the physical
/// layout kind or the explicit definition id invalidates an old hint (kind is only an **invalidation**
/// condition, never a source of eligibility).
public struct CandidateReadingRowHint: Equatable, Sendable {
    public static let defaultsKey = "keyboard.candidateReadingRowHint"
    private static let selectionField = "selection"
    private static let eligibleField = "eligible"
    private static let candidateField = "candidateAreaRequired"

    /// Layout selection at record time (`nil` is recorded as an empty string).
    public var selection: String
    public var eligible: Bool
    public var candidateAreaRequired: Bool

    /// Selection context readable synchronously at cold start -> hint key.
    public static func selectionKey(layoutKind: String?, definitionID: String?) -> String {
        "\(layoutKind ?? "")|\(definitionID ?? "")"
    }

    public init(selection: String?, eligible: Bool, candidateAreaRequired: Bool = true) {
        self.selection = selection ?? ""
        self.eligible = eligible
        self.candidateAreaRequired = candidateAreaRequired
    }

    /// Decoded from a defaults value; a wrong shape returns nil (fails closed).
    public init?(storedValue: Any?) {
        guard let dictionary = storedValue as? [String: Any],
            let selection = dictionary[Self.selectionField] as? String,
            let eligible = dictionary[Self.eligibleField] as? Bool
        else { return nil }
        self.selection = selection
        self.eligible = eligible
        self.candidateAreaRequired = dictionary[Self.candidateField] as? Bool ?? true
    }

    public var storedValue: [String: Any] {
        [
            Self.selectionField: selection, Self.eligibleField: eligible,
            Self.candidateField: candidateAreaRequired,
        ]
    }

    /// Cold-start grant for the current selection: reused only when the selection matches, otherwise false.
    public func resolve(currentSelection: String?) -> Bool {
        eligible && selection == (currentSelection ?? "")
    }

    /// An unknown or changed layout retains the candidate area until its definition is resolved.
    public func resolveCandidateArea(currentSelection: String?) -> Bool {
        selection == (currentSelection ?? "") ? candidateAreaRequired : true
    }

    /// Reads and resolves the hint (a `nil` hint means not granted).
    public static func resolve(storedValue: Any?, currentSelection: String?) -> Bool {
        CandidateReadingRowHint(storedValue: storedValue)?.resolve(currentSelection: currentSelection) ?? false
    }

    public static func resolveCandidateArea(storedValue: Any?, currentSelection: String?) -> Bool {
        CandidateReadingRowHint(storedValue: storedValue)?.resolveCandidateArea(currentSelection: currentSelection)
            ?? true
    }
}

/// What the reading row draws in the current state (a pure decision shared by production and tests).
public enum CandidateReadingRowContent: Hashable, Sendable {
    /// Transparent empty band: no placeholder title and no explanatory text.
    case empty
    /// Lockable spellings reported by the engine (only from `report.options`, never invented by the front end).
    case options([String])
    /// Locked: shows the spelling actually locked and the undo entry.
    case locked(chosen: String)
    /// Multi-syllable composition: the next-syllable options among the **engine readings** of loaded real
    /// candidates (`CandidateReadingFilter`, decoded by the schema dictionary from each candidate's own code);
    /// `selected` is the already chosen prefix syllables. Filters candidates read-only and never rewrites the
    /// input. Disambiguation reports only cover single-syllable segments, so this carries readings for multi-character input.
    case readings(selected: [String], options: [String])

    /// - Parameters:
    ///   - reserved: the host has granted height for this row;
    ///   - eligible: the resolved physical definition actually needs a reading row (may briefly differ from the grant during a transient fallback);
    ///   - usesPickerUI: `KeyboardController.usesAmbiguityPickerUI` (Chinese + compact structure);
    ///   - picker: real disambiguation state (takes priority: lockable single-syllable spellings and the undo entry);
    ///   - readings: read-only filter state of real candidate readings (used when disambiguation has nothing to show).
    public static func resolve(
        reserved: Bool, eligible: Bool, usesPickerUI: Bool,
        picker: AmbiguitySpellingPicker,
        readings: CandidateReadingFilter = CandidateReadingFilter()
    ) -> CandidateReadingRowContent {
        guard reserved, eligible, usesPickerUI else { return .empty }
        if picker.showsPicker {
            if picker.canUndoLock, let lock = picker.lock { return .locked(chosen: lock.chosenOption) }
            if let report = picker.report, !report.options.isEmpty {
                let ordered = readings.coverage.flatMap { coverage in
                    SyllableOrder.typedKeys(of: report, in: report.revisionInput).map {
                        SyllableOrder.spellingOptions(
                            report.options, typedKeys: $0,
                            keyForLetter: coverage.keyForLetter)
                    }
                }
                return .options(ordered ?? report.options)
            }
        }
        let options = readings.options
        guard readings.isFiltering || !options.isEmpty else { return .empty }
        return .readings(selected: readings.prefix, options: options)
    }

    public var isEmpty: Bool { self == .empty }
}
