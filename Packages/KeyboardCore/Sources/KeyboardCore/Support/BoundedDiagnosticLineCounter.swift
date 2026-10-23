import Foundation
import os

/// Bounded diagnostic line counter.
///
/// The hard cap on diagnostic logging must hold under concurrency: `emit` can be called from
/// the main thread (view lifecycle) and from background threads (self-check/measurement).
/// A lock-free static mutable `Int` would race between check and increment and could exceed
/// the cap or miscount.
///
/// This type puts check-and-increment under one lock: `reserve()` returning true means the
/// caller got a line of quota. Do not use it on the hot input path.
public final class BoundedDiagnosticLineCounter: Sendable {
    public let limit: Int
    private struct State {
        var reserved = 0
        var capReported = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    public enum Reservation: Equatable, Sendable {
        case line, capMarker, exhausted
    }

    public init(limit: Int) {
        self.limit = max(0, limit)
    }

    /// Takes one line within the hard cap; false means the cap was reached.
    public func reserve() -> Bool {
        state.withLock { [limit] state in
            guard state.reserved < limit else { return false }
            state.reserved += 1
            return true
        }
    }

    /// Reserve the last line for one explicit truncation marker. Without it a
    /// capped lifecycle log ends silently and can be mistaken for process death.
    public func reserveWithCapMarker() -> Reservation {
        state.withLock { [limit] state in
            if state.reserved < limit - 1 {
                state.reserved += 1
                return .line
            }
            if state.reserved < limit && !state.capReported {
                state.reserved += 1
                state.capReported = true
                return .capMarker
            }
            return .exhausted
        }
    }

    /// Lines taken so far (diagnostics/tests).
    public var count: Int {
        state.withLock { $0.reserved }
    }
}
