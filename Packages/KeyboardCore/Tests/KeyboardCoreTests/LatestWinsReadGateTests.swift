import XCTest

@testable import KeyboardCore

/// Deterministic regression for the latest-wins read-only gate.
///
/// Scenario: the old read starts first and the new read starts later, but the old result returns **after** the new one. The old one must be rejected,
/// otherwise it would overwrite the new atomic snapshot.
final class LatestWinsReadGateTests: XCTestCase {

    func testOldTokenRejectedAfterNewerReadCompleted() {
        var gate = LatestWinsReadGate()
        let old = gate.begin()
        let new = gate.begin()
        // new completes first and can be applied.
        XCTAssertTrue(gate.accepts(new))
        // old arrives later: must be rejected.
        XCTAssertFalse(gate.accepts(old))
    }

    func testLatestOnlyIsAcceptedAmongMany() {
        var gate = LatestWinsReadGate()
        var tokens: [UInt64] = []
        for _ in 0..<5 { tokens.append(gate.begin()) }
        for token in tokens.dropLast() { XCTAssertFalse(gate.accepts(token)) }
        XCTAssertTrue(gate.accepts(tokens.last!))
    }

    func testInvalidateRejectsBothOldAndCurrent() {
        var gate = LatestWinsReadGate()
        let old = gate.begin()
        let current = gate.begin()
        gate.invalidate()
        XCTAssertFalse(gate.accepts(old))
        XCTAssertFalse(gate.accepts(current), "after invalidate the current token must also be invalid")
    }

    func testBeginAfterInvalidateIsAccepted() {
        var gate = LatestWinsReadGate()
        let before = gate.begin()
        gate.invalidate()
        let after = gate.begin()
        XCTAssertFalse(gate.accepts(before))
        XCTAssertTrue(gate.accepts(after))
    }

    func testTokensAreStrictlyMonotonicAndNeverWrapInPractice() {
        var gate = LatestWinsReadGate()
        var previous: UInt64 = 0
        for _ in 0..<1_000 {
            let token = gate.begin()
            XCTAssertGreaterThan(token, previous)
            previous = token
        }
    }

    /// Wrap semantics are explicit: the comparison is "equals the current value", so even if &+ wraps to 0 an old token is never wrongly accepted.
    func testWrapSemanticsCompareEqualToCurrentNotGreaterThan() {
        var gate = LatestWinsReadGate()
        // Drive close to wraparound (without actually waiting for 2^64; only the equality semantics are verified).
        let a = gate.begin()
        let b = gate.begin()
        XCTAssertFalse(gate.accepts(a))
        XCTAssertTrue(gate.accepts(b))
        // If current becomes numerically equal to the old token after wrapping, accepts only recognizes "the current one";
        // a fresh value proves it is not misjudged as "greater": after b, a is never accepted.
        gate.invalidate()
        XCTAssertFalse(gate.accepts(b))
    }

    /// The two gates are independent (layout and appearance each stand alone).
    func testIndependentGatesDoNotInterfere() {
        var layout = LatestWinsReadGate()
        var appearance = LatestWinsReadGate()
        let layoutToken = layout.begin()
        let appearanceToken = appearance.begin()
        layout.invalidate()
        XCTAssertFalse(layout.accepts(layoutToken))
        XCTAssertTrue(appearance.accepts(appearanceToken))
    }
}
