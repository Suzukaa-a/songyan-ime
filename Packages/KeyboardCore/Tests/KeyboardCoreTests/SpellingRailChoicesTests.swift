import XCTest

@testable import KeyboardCore

final class SpellingRailChoicesTests: XCTestCase {
    private func report(
        input: String = "64", mode: AmbiguityLockMode = .tokenAlias,
        complete: Bool = true, segment: Range<Int> = 0..<2
    ) -> AmbiguitySpellingsReport {
        AmbiguitySpellingsReport(
            revisionInput: input, segment: segment,
            options: ["mi", "ni"], allSpellings: ["mi", "ni", "display-only"],
            lockMode: mode, isComplete: complete)
    }

    private func readings(revision: Int = 7) -> CandidateReadingFilter {
        var filter = CandidateReadingFilter()
        filter.reset(revision: revision)
        filter.append(
            [
                .init(index: 0, text: "你", syllables: ["ni"]),
                .init(index: 1, text: "米", syllables: ["mi"]),
                .init(index: 2, text: "拟", readingPaths: [["guessed"]], readingsComplete: false),
                .init(index: 3, text: "你好", syllables: ["ni", "hao"]),
            ], requested: 4, revision: revision)
        return filter
    }

    private func resolve(
        _ report: AmbiguitySpellingsReport? = nil, eligible: Bool = true,
        input: String = "64", revision: Int = 7, reportRevision: Int = 7,
        filter: CandidateReadingFilter? = nil
    ) -> SpellingRailChoices {
        SpellingRailChoices.resolve(
            eligible: eligible, input: input, revision: revision,
            report: report, reportRevision: reportRevision, readings: filter ?? readings())
    }

    func testOnlyEngineLockableChoicesAppearOnce() {
        let choices = resolve(report())
        XCTAssertEqual(choices.lockOptions, ["mi", "ni"])
        XCTAssertTrue(choices.readings.isEmpty)
        XCTAssertFalse(choices.canUndoLock)
    }

    func testRealReadingsWorkWithoutRewriteCapability() {
        let choices = resolve(report(mode: .none))
        XCTAssertTrue(choices.lockOptions.isEmpty)
        XCTAssertEqual(choices.readings, ["ni", "mi"])
    }

    func testUnsupportedOrIdleContextShowsNoChoicesEvenWithCachedEvidence() {
        XCTAssertTrue(resolve(report(), eligible: false).isEmpty)
        XCTAssertTrue(resolve(report(), input: "").isEmpty)
        XCTAssertTrue(resolve(filter: CandidateReadingFilter()).isEmpty)
    }

    func testStaleEvidenceCannotCreateSelectableChoices() {
        let oldReadings = readings(revision: 6)
        XCTAssertTrue(resolve(report(), reportRevision: 6, filter: oldReadings).isEmpty)
        XCTAssertTrue(resolve(report(input: "65"), filter: oldReadings).isEmpty)
    }

    func testIncompleteAndInvalidReportsDoNotCreateLocks() {
        XCTAssertTrue(resolve(report(complete: false)).lockOptions.isEmpty)
        XCTAssertTrue(resolve(report(segment: 0..<3)).lockOptions.isEmpty)
        XCTAssertTrue(resolve(report(segment: 1..<1)).lockOptions.isEmpty)
    }

    func testSelectionFiltersRealCandidatesAndUndoRestoresTheirOriginalOrder() {
        var filter = readings()
        filter.select("ni")
        var choices = resolve(filter: filter)
        XCTAssertTrue(choices.isFiltering)
        XCTAssertEqual(choices.readingPrefix, ["ni"])
        XCTAssertEqual(choices.readings, ["hao"])
        XCTAssertEqual(filter.matches.map { $0.index }, [0, 3])
        filter.select("guessed")
        XCTAssertEqual(filter.prefix, ["ni"])
        filter.undoSelection()
        choices = resolve(filter: filter)
        XCTAssertFalse(choices.isFiltering)
        XCTAssertEqual(choices.readings, ["ni", "mi"])
        XCTAssertEqual(filter.matches.map { $0.index }, [0, 1, 2, 3])
    }

    func testTypedNineKeyCoverageDoesNotOfferUntypedCompletionSyllables() {
        let groups = ["abc", "def", "ghi", "jkl", "mno", "pqrs", "tuv", "wxyz"]
        var keys: [Character: Character] = [:]
        for (offset, letters) in groups.enumerated() {
            for letter in letters { keys[letter] = Character(String(offset + 2)) }
        }
        var filter = readings()
        filter.setCoverage(ReadingInputCoverage(input: "64", keyForLetter: keys))
        XCTAssertEqual(resolve(filter: filter).readings, ["ni", "mi"])
        filter.select("ni")
        XCTAssertTrue(resolve(filter: filter).readings.isEmpty)
        XCTAssertEqual(filter.matches.map { $0.index }, [0, 3])
    }

    func testLockRemainsVisibleForUndoOnlyWhileRewrittenInputMatches() {
        let choices = SpellingRailChoices.resolve(
            eligible: true, input: "ni", revision: 8,
            report: nil, reportRevision: 7, lockedOption: "ni", lockedInput: "ni", readings: readings())
        XCTAssertTrue(choices.canUndoLock)
        XCTAssertEqual(choices.lockedOption, "ni")
        XCTAssertTrue(choices.lockOptions.isEmpty)
        XCTAssertTrue(choices.readings.isEmpty)
        let stale = SpellingRailChoices.resolve(
            eligible: true, input: "ni4", revision: 9,
            report: nil, reportRevision: 7, lockedOption: "ni", lockedInput: "ni", readings: readings())
        XCTAssertTrue(stale.isEmpty)
    }
}
