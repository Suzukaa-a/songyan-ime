import XCTest

@testable import LayoutKit

/// `DefinitionObservationGate` separates the panel's own explicit selection/reconcile from an external
/// registry content replacement, and does not blindly swallow the next change.
///
/// Scenario matrix (mirrors real Panel paths):
///  - explicit user selection old-to-target: one transaction only (the explicit path); the observer must consume it;
///  - layout/schema switch causing old-to-target: same (also caused by the panel);
///  - registry old-to-edited: one-shot transaction (observer treats it as a real change);
///  - an unrelated change before the expected target: not swallowed, handled as real, expectation kept;
///  - pure name/note no-op: identity unchanged, no transaction.
final class DefinitionObservationGateTests: XCTestCase {

    private func identity(_ id: String, _ marker: String) -> LayoutRuntimeIdentity {
        .proven("layout:\(id):\(marker)")
    }

    private let old = LayoutRuntimeIdentity.proven("layout:merged14:v1")
    private let target = LayoutRuntimeIdentity.proven("layout:merged14:v2")
    private let unrelated = LayoutRuntimeIdentity.proven("layout:qwerty26:v9")
    private let edited = LayoutRuntimeIdentity.proven("layout:merged14:v3")

    /// Explicit user selection old-to-target: once registered, that change is consumed (no second transaction).
    func testExplicitSelectionTransitionIsConsumedExactlyOnce() {
        var gate = DefinitionObservationGate()
        gate.expect(from: old, to: target)

        XCTAssertTrue(gate.consume(from: old, to: target), "the panel's own explicit transition must be consumed")
        XCTAssertFalse(gate.consume(from: old, to: target), "the same transition must not be consumed twice")
        XCTAssertNil(gate.expected, "the expectation must be cleared after consumption")
    }

    /// A layout/schema switch causing old-to-target: the same mechanism consumes it once.
    func testLayoutSwitchTransitionIsConsumedExactlyOnce() {
        var gate = DefinitionObservationGate()
        gate.expect(from: old, to: target)
        XCTAssertTrue(gate.consume(from: old, to: target))
        XCTAssertFalse(gate.hasExpectation)
    }

    /// registry old-to-edited: no expectation (or a mismatch) means not swallowed, handled as a real change.
    func testRegistryEditIsNotSwallowed() {
        var gate = DefinitionObservationGate()
        XCTAssertFalse(
            gate.consume(from: old, to: edited), "without an expectation it must be handled as a real change")

        // Even with an expectation, a different target is not swallowed.
        gate.expect(from: old, to: target)
        XCTAssertFalse(gate.consume(from: old, to: edited), "a mismatching target must not be swallowed")
        XCTAssertTrue(gate.hasExpectation, "a mismatch must not clear the expectation (it may arrive later)")
        // The real expectation arriving later is still consumed.
        XCTAssertTrue(gate.consume(from: old, to: target))
    }

    /// An unrelated change before the expected target is not swallowed and the expectation is kept.
    func testUnrelatedChangeBeforeExpectedIsNotSwallowed() {
        var gate = DefinitionObservationGate()
        gate.expect(from: old, to: target)

        XCTAssertFalse(gate.consume(from: old, to: unrelated), "an unrelated change must not be swallowed")
        XCTAssertTrue(gate.hasExpectation, "the expectation must be kept")
        XCTAssertTrue(gate.consume(from: old, to: target), "an expectation arriving later is still consumed")
    }

    /// A mismatching `from` is not swallowed either (e.g. a third party changed the active definition first).
    func testMismatchedFromIsNotSwallowed() {
        var gate = DefinitionObservationGate()
        gate.expect(from: old, to: target)
        XCTAssertFalse(gate.consume(from: unrelated, to: target))
        XCTAssertTrue(gate.hasExpectation)
    }

    /// A pure name/note change keeps identity, so there is no transition (`from == to`).
    /// Registering (old, old) then must not swallow a real old-to-edited change.
    func testNameOnlyNoopDoesNotConsumeRealEdit() {
        var gate = DefinitionObservationGate()
        gate.expect(from: old, to: old)  // rename only: expected no-op
        XCTAssertTrue(gate.consume(from: old, to: old), "an observation with no change can be consumed")
        XCTAssertFalse(gate.consume(from: old, to: edited), "a following real edit must not be swallowed")
    }

    /// `clear()` cancels the expectation explicitly.
    func testClearDropsExpectation() {
        var gate = DefinitionObservationGate()
        gate.expect(from: old, to: target)
        gate.clear()
        XCTAssertFalse(gate.hasExpectation)
        XCTAssertFalse(gate.consume(from: old, to: target), "nothing is swallowed after clearing")
    }

    /// An unprovable identity must never count as an exact observation through the synthesized Equatable.
    func testUnprovenExpectationIsNeverRegisteredOrConsumed() {
        var gate = DefinitionObservationGate()
        let from = LayoutRuntimeIdentity.unproven(id: "same")
        let to = LayoutRuntimeIdentity.unproven(id: "same")
        gate.expect(from: from, to: to)
        XCTAssertFalse(gate.hasExpectation)
        XCTAssertFalse(gate.consume(from: from, to: to))
    }

    /// No definition is not a provable physical identity either; absent == absent must not swallow an observation.
    func testAbsentExpectationIsNeverRegisteredOrConsumed() {
        var gate = DefinitionObservationGate()
        gate.expect(from: .absent, to: .absent)
        XCTAssertFalse(gate.hasExpectation)
        XCTAssertFalse(gate.consume(from: .absent, to: .absent))
    }
}
