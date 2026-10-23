import Foundation

// MARK: - English Shift tri-state

/// Shift state for direct English input (a local state machine driven by the UI's
/// single/double-tap recognition):
///  - `off`: lowercase;
///  - `once`: the next letter is uppercase, then returns to off (digits/symbols don't consume it);
///  - `locked`: Caps Lock, uppercase until released.
///
/// Chinese composition is unaffected: keycap case is cosmetic; codes sent to the engine are always lowercase.
public enum ShiftState: Equatable, Sendable {
    case off
    case once
    case locked

    /// Whether once/locked is active (the UI shows English keycaps uppercase).
    public var isActive: Bool { self != .off }

    /// Whether to show the one-shot uppercase state (once only; locked uses a separate lit/filled style).
    public var isTemporary: Bool { self == .once }
}
