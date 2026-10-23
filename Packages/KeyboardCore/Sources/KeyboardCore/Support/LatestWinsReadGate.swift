import Foundation

/// Latest-wins generation gate for read-only async tasks.
///
/// Consecutive notifications (appearance change / didBecomeActive / layout re-read) start
/// several async read tasks whose scheduling and completion order is not guaranteed to match
/// start order; a late older read could overwrite a newer atomic snapshot.
///
/// Rules (single implementation shared by KeyboardPanelHost and KeyboardViewController):
///  - `begin()` before each read yields a fresh token, which is the latest.
///  - On completion, `accepts(token)` accepts only the latest token.
///  - `invalidate()` (disappear/leave) invalidates the current token too, so all in-flight
///    results are rejected.
///  - Tokens are a process-local monotonic `UInt64` and are not expected to wrap; even if one
///    did, comparing for equality with the current value keeps the semantics correct.
///
/// A pure value usable off the MainActor, but callers should stay in one execution domain
/// (usually MainActor) so begin/accepts do not interleave.
public struct LatestWinsReadGate: Equatable, Sendable {
    private var current: UInt64
    private var nextValue: UInt64

    public init() {
        self.current = 0
        self.nextValue = 0
    }

    /// Starts a read and returns its token (invalidating all earlier tokens).
    @discardableResult
    public mutating func begin() -> UInt64 {
        nextValue &+= 1
        current = nextValue
        return current
    }

    /// Whether the token is still the latest (safe to apply its result).
    public func accepts(_ token: UInt64) -> Bool { token == current }

    /// Invalidates the current token (disappear/leave): all in-flight results are then rejected.
    public mutating func invalidate() {
        nextValue &+= 1
        current = nextValue
    }
}
