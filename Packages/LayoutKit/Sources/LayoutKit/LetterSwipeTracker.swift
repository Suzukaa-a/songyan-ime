import Foundation

/// Horizontal swipe on a two-letter key: left picks the left letter, right the right one.
///
/// A tap's finger roll stays well under the commit distance, and the swipe must be
/// mostly sideways when it crosses it (direction lock at 45°), so a slightly sloppy tap
/// never turns into a pick. Once locked, the pick follows the finger: crossing back over
/// the touch-down point picks the other letter, and coming to rest near it returns to a
/// plain tap, the same give-back the 9-key upward flick has.
public struct LetterSwipeTracker: Equatable, Sendable {
    /// Sideways travel that locks the swipe (points). Within the 15–20pt range keyboards
    /// use for flick input, and past the few points a finger rolls during a tap.
    public static let lockDistance: Double = 18
    /// Back within this distance of the touch-down point, the press is a tap again.
    public static let returnDistance: Double = 8

    public let letterCount: Int
    public private(set) var isLocked = false
    /// The picked letter index; nil while the press is still a tap.
    public private(set) var choice: Int?

    public init(letterCount: Int) {
        self.letterCount = letterCount
    }

    /// Feeds the finger's offset from the touch-down point; returns whether `choice` changed.
    @discardableResult
    public mutating func update(dx: Double, dy: Double) -> Bool {
        guard letterCount > 1, dx.isFinite, dy.isFinite else { return false }
        if !isLocked {
            guard abs(dx) >= Self.lockDistance, abs(dx) > abs(dy) else { return false }
            isLocked = true
        }
        let next: Int? = abs(dx) < Self.returnDistance ? nil : (dx < 0 ? 0 : letterCount - 1)
        guard next != choice else { return false }
        choice = next
        return true
    }
}
