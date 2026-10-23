import Foundation

/// One-handed keyboard choice: which side the key content hugs, if any.
public enum KeyboardOneHandMode: String, CaseIterable, Sendable {
    case off
    /// Content hugs the left edge; the restore gutter sits on the right.
    case left
    /// Content hugs the right edge; the restore gutter sits on the left.
    case right

    /// Unknown or missing stored values resolve to off.
    public static func resolve(_ storedValue: String?) -> Self {
        storedValue.flatMap(Self.init(rawValue:)) ?? .off
    }
}

/// The narrowed layout: only the laid-out width shrinks, with no scale transform.
public struct KeyboardOneHandPlan: Equatable, Sendable {
    /// false = lay out exactly as before, full width.
    public let active: Bool
    /// Actual content width when active (full panel width when not).
    public let contentWidth: Double
    /// Actual blank gutter width when active (0 when not).
    public let gutterWidth: Double
    /// Whether the blank gutter sits on the left (right-handed mode) or the right (left-handed mode).
    public let gutterOnLeft: Bool

    public static func inactive(panelWidth: Double) -> Self {
        Self(active: false, contentWidth: panelWidth, gutterWidth: 0, gutterOnLeft: false)
    }
}

/// Decides when one-handed narrowing applies and the widths it produces.
///
/// Only iPhone portrait panels of standard width narrow; landscape, iPad and
/// unusual widths keep the full-width layout. The caller passes the idiom and
/// size-class facts rather than inferring device class from the width.
public enum KeyboardOneHandLayoutPolicy {
    /// Narrowed content keeps this share of the panel width.
    public static let contentRatio: Double = 0.85
    /// Lower bound of the narrowed content so alphabetic keys stay usable.
    public static let minimumContentWidth: Double = 320
    /// The gutter carries the restore control, which needs a 44pt target.
    public static let minimumGutterWidth: Double = 44
    /// Standard iPhone portrait widths start here.
    public static let minimumPanelWidth: Double = 375
    /// Above this width the panel is a pad / floating / regular-width surface.
    public static let maximumPanelWidth: Double = 600

    public static func plan(
        mode: KeyboardOneHandMode,
        panelWidth: Double,
        isPhonePortrait: Bool
    ) -> KeyboardOneHandPlan {
        guard mode != .off,
            isPhonePortrait,
            panelWidth >= minimumPanelWidth,
            panelWidth <= maximumPanelWidth
        else { return .inactive(panelWidth: panelWidth) }
        let content = max(minimumContentWidth, (panelWidth * contentRatio).rounded(.down))
        let gutter = panelWidth - content
        guard gutter >= minimumGutterWidth else { return .inactive(panelWidth: panelWidth) }
        return KeyboardOneHandPlan(
            active: true,
            contentWidth: content,
            gutterWidth: gutter,
            gutterOnLeft: mode == .right)
    }
}
