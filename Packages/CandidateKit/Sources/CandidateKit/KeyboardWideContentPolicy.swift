import Foundation
import LayoutKit

/// Where a width-capped keyboard content sits on a surface wider than its cap.
public enum KeyboardContentDock: String, CaseIterable, Sendable {
    case left, center, right

    /// Unknown or missing stored values fall back to center, the neutral default.
    public static func resolve(_ storedValue: String?) -> Self {
        storedValue.flatMap(Self.init(rawValue:)) ?? .center
    }
}

/// The laid-out width and side insets for a wide surface. No scale factor: callers assign
/// `contentWidth` as a real frame width and let the insets fill the rest.
public struct KeyboardWideContentPlan: Equatable, Sendable {
    /// false means the content keeps the full panel width and both insets are zero.
    public let active: Bool
    /// Real width to lay out with; finite and never above the panel width.
    public let contentWidth: Double
    /// Blank width before the content; finite and non-negative.
    public let leadingInset: Double
    /// Blank width after the content; finite and non-negative.
    public let trailingInset: Double

    public static func inactive(panelWidth: Double) -> Self {
        let width = KeyboardWideContentPolicy.normalized(panelWidth)
        return Self(active: false, contentWidth: width, leadingInset: 0, trailingInset: 0)
    }
}

/// Keeps wide layouts from stretching: above a phone-sized surface the content is capped and
/// docked left, center or right. The policy only does geometry — layout identity, split, height,
/// preferences and system gestures stay with their owners.
public enum KeyboardWideContentPolicy {
    /// The 9-key outer frame keeps the inner 436pt phone shell intact with a 4pt gutter per side
    /// (`436 + 2 * 4 = 444`); the reconcile is left to the layout that draws the shell.
    public static let phoneNineMaximumContentWidth: Double = 444
    /// The merged 14/18-key letter pads read as one unit on a wide surface without stretching.
    public static let mergedMaximumContentWidth: Double = 520

    /// Returns the real content width and insets for this surface. A nil or oversized cap, a
    /// phone-sized surface (`KeyboardSurfaceWidth.phoneMaximum`), and malformed widths all stay
    /// inactive at full width.
    public static func plan(
        panelWidth: Double,
        maximumContentWidth: Double?,
        dock: KeyboardContentDock
    ) -> KeyboardWideContentPlan {
        let width = normalized(panelWidth)
        guard width > KeyboardSurfaceWidth.phoneMaximum,
            let maximumContentWidth,
            maximumContentWidth.isFinite,
            maximumContentWidth > 0,
            maximumContentWidth < width
        else { return .inactive(panelWidth: width) }
        let remaining = width - maximumContentWidth
        let leading: Double
        let trailing: Double
        switch dock {
        case .left:
            leading = 0
            trailing = remaining
        case .center:
            leading = remaining / 2
            trailing = remaining - leading
        case .right:
            leading = remaining
            trailing = 0
        }
        return KeyboardWideContentPlan(
            active: true, contentWidth: maximumContentWidth,
            leadingInset: leading, trailingInset: trailing)
    }

    /// Real UI widths may be negative or non-finite right after a resize; normalize exactly once.
    static func normalized(_ width: Double) -> Double {
        width.isFinite ? max(0, width) : 0
    }
}
