import KeyboardCore
import LayoutKit
import XCTest

@testable import CandidateKit

final class AmbiguitySpellingPickerTests: XCTestCase {

    private func report(
        options: [String], all: [String], complete: Bool = true,
        mode: AmbiguityLockMode = .tokenAlias,
        input: String = "ug"
    ) -> AmbiguitySpellingsReport {
        AmbiguitySpellingsReport(
            revisionInput: input, segment: 0..<input.utf8.count,
            options: options, allSpellings: all,
            lockMode: mode, isComplete: complete)
    }

    func testAvailableOnlyExposesLockableOptions() {
        var picker = AmbiguitySpellingPicker()
        picker.update(
            report: report(options: ["chang", "cheng"], all: ["chang", "cheng", "shang"]),
            revision: 3, isEligible: true)
        XCTAssertEqual(picker.phase, .available)
        XCTAssertTrue(picker.showsPicker)
        XCTAssertEqual(picker.report?.options, ["chang", "cheng"])
        XCTAssertEqual(picker.allSpellings, ["chang", "cheng", "shang"], "diagnostics keep full set")
        XCTAssertEqual(picker.revision, 3)
    }

    func testFewerThanTwoLockableHidesPickerButKeepsDiagnostics() {
        var picker = AmbiguitySpellingPicker()
        picker.update(
            report: report(options: ["chang"], all: ["chang", "cheng"]),
            revision: 1, isEligible: true)
        XCTAssertEqual(picker.phase, .idle)
        XCTAssertFalse(picker.showsPicker)
        XCTAssertNil(picker.report)
        XCTAssertEqual(picker.allSpellings, ["chang", "cheng"])
    }

    func testIncompleteReportIsNeverPresentedAsFullPicker() {
        var picker = AmbiguitySpellingPicker()
        picker.update(
            report: report(options: ["a", "b"], all: ["a", "b"], complete: false),
            revision: 1, isEligible: true)
        XCTAssertEqual(picker.phase, .idle)
        XCTAssertNil(picker.report)
        XCTAssertNotNil(picker.message)
    }

    func testIneligibleClears() {
        var picker = AmbiguitySpellingPicker()
        picker.update(report: report(options: ["a", "b"], all: ["a", "b"]), revision: 1, isEligible: true)
        picker.update(report: nil, revision: 2, isEligible: false)
        XCTAssertEqual(picker.phase, .idle)
        XCTAssertNil(picker.report)
    }

    func testStaleRevisionAndInputRejected() {
        var picker = AmbiguitySpellingPicker()
        picker.update(report: report(options: ["a", "b"], all: ["a", "b"]), revision: 5, isEligible: true)
        XCTAssertTrue(picker.accepts(option: "a", revision: 5, input: "ug"))
        XCTAssertFalse(picker.accepts(option: "a", revision: 6, input: "ug"), "stale revision")
        XCTAssertFalse(picker.accepts(option: "a", revision: 5, input: "ugx"), "stale input")
        XCTAssertFalse(picker.accepts(option: "z", revision: 5, input: "ug"), "not lockable")
    }

    func testLockLifecycleRecordsOriginalAndRewritten() {
        var picker = AmbiguitySpellingPicker()
        picker.update(
            report: report(options: ["shang", "chang"], all: ["shang", "chang"]),
            revision: 7, isEligible: true)
        picker.markLocked(
            option: "shang", originalInput: "ug", originalSegment: 0..<2,
            rewrittenInput: "9084", rewrittenSegment: 0..<4)
        XCTAssertEqual(picker.phase, .locked)
        XCTAssertTrue(picker.canUndoLock)
        XCTAssertTrue(picker.showsPicker)
        XCTAssertEqual(picker.lock?.originalInput, "ug")
        XCTAssertEqual(picker.lock?.chosenOption, "shang")
        XCTAssertEqual(picker.lock?.rewrittenInput, "9084")
        // A locked picker stays locked across an unrelated refresh that keeps the input.
        picker.update(report: nil, revision: 8, isEligible: true)
        XCTAssertEqual(picker.phase, .locked)
        picker.update(
            report: report(options: ["shang"], all: ["shang"]),
            revision: 9, isEligible: true)
        XCTAssertEqual(picker.phase, .locked, "locked alias commonly re-enumerates as a singleton")
        picker.update(
            report: report(
                options: ["shang", "chang"], all: ["shang", "chang"],
                complete: false), revision: 10, isEligible: true)
        XCTAssertEqual(picker.phase, .locked, "truncated refresh cannot discard the restore token")
        picker.markUnlocked()
        XCTAssertEqual(picker.phase, .idle)
        XCTAssertNil(picker.lock)
    }

    func testFailureEntersErrorAndDropsFakeButtons() {
        var picker = AmbiguitySpellingPicker()
        picker.update(report: report(options: ["a", "b"], all: ["a", "b"]), revision: 1, isEligible: true)
        picker.fail("stale")
        XCTAssertEqual(picker.phase, .error)
        XCTAssertNil(picker.report, "no fake selectable options after failure")
        XCTAssertEqual(picker.message, "stale")
        XCTAssertFalse(picker.showsPicker)
    }

    /// BN+UI on the physical 14-key layout emits raw "bu": both BU and NI are
    /// live-prism-proven lockable alternatives and both must be selectable.
    func testMergedTrajectoryBuExposesBuAndNi() {
        var picker = AmbiguitySpellingPicker()
        picker.update(
            report: report(options: ["bu", "ni"], all: ["bu", "ni"], input: "bu"),
            revision: 2, isEligible: true)
        XCTAssertEqual(picker.phase, .available)
        XCTAssertTrue(picker.showsPicker)
        XCTAssertEqual(picker.report?.options, ["bu", "ni"])
        XCTAssertTrue(picker.accepts(option: "bu", revision: 2, input: "bu"))
        XCTAssertTrue(picker.accepts(option: "ni", revision: 2, input: "bu"))
        XCTAssertFalse(picker.accepts(option: "ni", revision: 3, input: "bu"), "stale revision")
        XCTAssertFalse(picker.accepts(option: "ni", revision: 2, input: "bug"), "stale input")
    }

    /// CAS identity criterion: the lock is valid only while its **rewritten** input still equals the real input.
    func testLockMatchesUsesRewrittenInput() {
        var picker = AmbiguitySpellingPicker()
        picker.update(
            report: report(options: ["shang", "chang"], all: ["shang", "chang"]),
            revision: 1, isEligible: true)
        picker.markLocked(
            option: "shang", originalInput: "ug", originalSegment: 0..<2,
            rewrittenInput: "9084", rewrittenSegment: 0..<4)
        XCTAssertTrue(picker.lockMatches(rawInput: "9084"), "the rewrite still applies, so the lock is valid")
        XCTAssertFalse(picker.lockMatches(rawInput: "ug"), "back to the original code, the lock must not revive")
        XCTAssertFalse(picker.lockMatches(rawInput: "9084x"), "the input changed, so the lock is invalid")
        XCTAssertFalse(AmbiguitySpellingPicker().lockMatches(rawInput: "9084"), "no lock")
    }
}
