import Foundation

/// Coordinates observation of definition changes (pure value, unit-testable, no delay).
///
/// `KeyboardPanelView` detects registry hot updates via `.onChange(of: activeDefinition)`, but
/// `activeDefinition` is computed: a successful explicit `selectDefinition` writes `localLayoutID`
/// and layout/schema switches change resolution, so the panel triggers its own old-to-target change.
/// Treating that as a hot update would open a second transaction and confirm the user's own
/// choice twice.
///
/// The explicit path registers the expected `(from, to)` before acting; the observer consumes only
/// an exact match.
///
///  - match: caused by the panel itself and already settled, so the observer only suppresses;
///  - mismatch: not swallowed, handled as a real external change (registry content replaced);
///  - an expectation is never eaten by an arbitrary next change: both identities must match exactly.
public struct DefinitionObservationGate: Equatable, Sendable {
    /// One expected transition: `from` is the active identity before the action, `to` the target identity.
    public struct Expectation: Equatable, Sendable {
        public let from: LayoutRuntimeIdentity
        public let to: LayoutRuntimeIdentity
        public init(from: LayoutRuntimeIdentity, to: LayoutRuntimeIdentity) {
            self.from = from
            self.to = to
        }
    }

    /// The registered expectation (overwritten by a later `expect`, cleared on match).
    public private(set) var expected: Expectation?

    /// Whether an expected transition is still registered.
    public var hasExpectation: Bool { expected != nil }

    public init() {}

    /// Registers the expected transition (call before an explicit selection/reconcile).
    public mutating func expect(from: LayoutRuntimeIdentity, to: LayoutRuntimeIdentity) {
        // Suppression claims "this is the change I just triggered", so like lock restoration it only
        // accepts proven identities; absent/unproven must not match through the synthesized Equatable.
        guard from.isProven, to.isProven else {
            expected = nil
            return
        }
        expected = Expectation(from: from, to: to)
    }

    /// Consumes an observed change. Returns true (and clears the expectation) only on an exact match;
    /// otherwise returns false and keeps the expectation, and the caller must treat it as a real change.
    public mutating func consume(
        from: LayoutRuntimeIdentity,
        to: LayoutRuntimeIdentity
    ) -> Bool {
        guard let expected,
            expected.from.isProvablySame(as: from),
            expected.to.isProvablySame(as: to)
        else { return false }
        self.expected = nil
        return true
    }

    /// Clears explicitly (e.g. when switching to an unrelated flow).
    public mutating func clear() { expected = nil }
}
