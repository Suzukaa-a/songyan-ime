import Foundation

/// Selectable compact-key spellings come only from live engine reports or complete
/// candidate readings. Display-only sentence spelling is deliberately not an input.
public struct SpellingRailChoices: Equatable, Sendable {
    public private(set) var canUndoLock = false
    public private(set) var lockedOption: String?
    public private(set) var lockOptions: [String] = []
    public private(set) var isFiltering = false
    public private(set) var readingPrefix: [String] = []
    public private(set) var readings: [String] = []

    public var isEmpty: Bool { !canUndoLock && lockOptions.isEmpty && !isFiltering && readings.isEmpty }

    public init() {}

    public static func resolve(
        eligible: Bool, input: String, revision: Int,
        report: AmbiguitySpellingsReport?, reportRevision: Int,
        lockedOption: String? = nil, lockedInput: String? = nil,
        readings: CandidateReadingFilter
    ) -> Self {
        guard eligible, !input.isEmpty else { return Self() }
        var result = Self()
        if let lockedOption, !lockedOption.isEmpty, lockedInput == input {
            result.canUndoLock = true
            result.lockedOption = lockedOption
        } else if let report, reportRevision == revision, report.revisionInput == input,
            report.isComplete, report.isAmbiguous, report.isLockable,
            report.segment.lowerBound >= 0, !report.segment.isEmpty,
            report.segment.upperBound <= input.utf8.count
        {
            result.lockOptions =
                readings.coverage.flatMap { coverage in
                    SyllableOrder.typedKeys(of: report, in: input).map {
                        SyllableOrder.spellingOptions(
                            report.options, typedKeys: $0, keyForLetter: coverage.keyForLetter)
                    }
                } ?? report.options
        }
        if readings.revision == revision {
            result.isFiltering = readings.isFiltering
            result.readingPrefix = readings.prefix
            // Prefer a real engine rewrite when the same reading is available both ways.
            let locks = Set(result.lockOptions)
            result.readings = readings.options.filter { !locks.contains($0) }
        }
        return result
    }
}
