import XCTest

@testable import KeyboardCore

/// Pure-value regression for the failure-page status text.
///
/// The failure page must describe state according to real transaction semantics, not always claim "unchanged": an error thrown by the atomic installer before commit
/// proves both content and keyboard are unchanged; a second-write failure after commit only reaches "content saved, keyboard unchanged".
final class OperationFailureStateTests: XCTestCase {

    func testNothingCommittedStatesBothUnchanged() {
        let state = OperationFailureState.nothingCommitted
        XCTAssertTrue(state.stateLine.contains("键盘"))
        XCTAssertTrue(state.stateLine.contains("没有改变"))
        XCTAssertNotNil(state.nextStep)
    }

    func testInstalledNotAppliedStatesContentSavedKeyboardUnchanged() {
        let state = OperationFailureState.installedNotApplied
        XCTAssertTrue(state.stateLine.contains("已经保存"), state.stateLine)
        XCTAssertTrue(state.stateLine.contains("键盘没有改变"), state.stateLine)
        // Must not be conflated with "nothing happened" (never always claim "unchanged").
        XCTAssertNotEqual(state.stateLine, OperationFailureState.nothingCommitted.stateLine)
        XCTAssertTrue(state.nextStep?.contains("「使用」") == true, state.nextStep ?? "nil")
    }

    func testUnknownDoesNotClaimAnyOutcome() {
        let state = OperationFailureState.unknown
        XCTAssertFalse(state.stateLine.contains("没有改变"), "无法证明时不得宣称未改变")
        XCTAssertFalse(state.stateLine.contains("已经保存"), "无法证明时不得宣称已保存")
        XCTAssertNotNil(state.nextStep, "when unconfirmable the user should be asked to reload")
    }

    func testAllStateCopyAvoidsInternalTerminology() {
        for state in [OperationFailureState.nothingCommitted, .installedNotApplied, .unknown] {
            XCTAssertNil(UserTerminology.leaksInternalTerminology(state.stateLine), state.stateLine)
            if let next = state.nextStep {
                XCTAssertNil(UserTerminology.leaksInternalTerminology(next), next)
            }
        }
    }
}
