import XCTest

@testable import KeyboardCore

/// Model contract for the bridge-observed Rime values that the panel layer will
/// later consume: the three engine mode flags and the engine-owned candidate
/// select key/label. These are pure value-type guarantees; the real
/// RimeState -> EngineSnapshot mapping is covered by the macOS native harness
/// `Tools/BuildRimeIOS/scripts/32-bridge-contracts-harness.sh`.
final class EngineObservationContractTests: XCTestCase {

    // MARK: - Engine mode flags (ascii_mode / full_shape / ascii_punct)

    func testSnapshotModeFlagsDefaultFalseAndStayIndependent() {
        var snapshot = EngineSnapshot()
        XCTAssertFalse(snapshot.isAsciiMode)
        XCTAssertFalse(snapshot.isFullShape)
        XCTAssertFalse(snapshot.isAsciiPunct)

        snapshot.isFullShape = true
        XCTAssertTrue(snapshot.isFullShape)
        XCTAssertFalse(snapshot.isAsciiMode, "full_shape must not imply ascii_mode")
        XCTAssertFalse(snapshot.isAsciiPunct, "full_shape must not imply ascii_punct")

        snapshot.isAsciiPunct = true
        XCTAssertFalse(snapshot.isAsciiMode)
        XCTAssertTrue(snapshot.isFullShape)
        XCTAssertTrue(snapshot.isAsciiPunct)

        snapshot.isAsciiMode = true
        XCTAssertTrue(snapshot.isAsciiMode)
        XCTAssertTrue(snapshot.isFullShape)
        XCTAssertTrue(snapshot.isAsciiPunct)
    }

    func testSnapshotEqualityIncludesModeFlags() {
        // Compatible defaults: an old-style snapshot equals one with the flags
        // explicitly false, so existing demo/test constructions are unchanged.
        XCTAssertEqual(
            EngineSnapshot(),
            EngineSnapshot(
                committed: "", candidates: [], preedit: "",
                rawInput: "", isComposing: false))
        var ascii = EngineSnapshot()
        ascii.isAsciiMode = true
        XCTAssertNotEqual(EngineSnapshot(), ascii)
    }

    // MARK: - Candidate select key / label

    func testCandidateSelectMetadataDefaultsNil() {
        let candidate = Candidate(index: 0, text: "你", comment: "ni")
        XCTAssertNil(candidate.selectKey, "no fabricated default select key")
        XCTAssertNil(candidate.selectLabel, "no fabricated default label")
        XCTAssertEqual(candidate.comment, "ni")
    }

    func testCandidateSelectMetadataIsPreservedAndDistinctFromComment() {
        let candidate = Candidate(
            index: 2, text: "好", comment: "hao",
            selectKey: "d", selectLabel: "丙")
        XCTAssertEqual(candidate.selectKey, "d")
        XCTAssertEqual(candidate.selectLabel, "丙")
        XCTAssertEqual(candidate.comment, "hao")
        XCTAssertNotEqual(
            candidate.selectLabel, candidate.comment,
            "a comment must never be treated as the engine label")
    }

    func testCandidateEqualityIncludesSelectMetadata() {
        let base = Candidate(index: 0, text: "你")
        XCTAssertNotEqual(base, Candidate(index: 0, text: "你", selectKey: "a"))
        XCTAssertNotEqual(base, Candidate(index: 0, text: "你", selectLabel: "甲"))
        XCTAssertEqual(base, Candidate(index: 0, text: "你", selectKey: nil, selectLabel: nil))
    }
}
