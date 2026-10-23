import Foundation

/// Vertical budget of the quick-content panel (symbols, phrases, clipboard).
///
/// The panel is drawn inside the keyboard's own height, which on a phone in landscape is a
/// fraction of the portrait height. Chrome that takes its ideal height regardless of the space
/// left overflows its bands on a short panel: rows collide and the content is clipped away. This policy is the single place that decides how much room each band gets, and it
/// guarantees the chrome never exceeds the panel.
///
/// The choices live in a **leading column**, the way the nine-key symbol page does it: one
/// vertical list of slots, scrolling when the list outgrows the panel, with the open choice
/// marked. There is no horizontal chip row, so nothing is squeezed into two stacked rows.
public struct QuickContentLayout: Equatable, Sendable {
    public enum Density: Equatable, Sendable {
        case regular, compact, minimal
    }

    public let density: Density
    /// Back / title / search row.
    public let titleBarHeight: CGFloat
    /// One divider; part of the budget, so it never adds to the panel.
    public let separatorHeight: CGFloat
    /// Height left for the leading column and the content side by side; never negative.
    public let contentHeight: CGFloat
    /// Leading column width.
    public let railWidth: CGFloat
    /// One leading-column slot. The list scrolls when the slots outgrow the panel.
    public let railSlotHeight: CGFloat
    public let symbolCellMinHeight: CGFloat
    /// Minimum column width for a single glyph and for a whole-phrase (kaomoji) cell.
    public let symbolColumnMinWidth: CGFloat
    public let kaomojiColumnMinWidth: CGFloat
    /// Whole-phrase cells use this many equal columns (single glyphs stay adaptive).
    public let kaomojiColumnCount: Int
    /// "Recent symbols" needs its own row: only worth showing when there is height to spare.
    public let showsRecents: Bool

    private static let separator: CGFloat = 0.5
    /// A slot stays a comfortable touch target; the list scrolls when the slots outgrow the panel
    /// rather than squeezing them below it.
    private static let railSlotFloor: CGFloat = 34
    private static let railSlotCeiling: CGFloat = 50

    /// - Parameters:
    ///   - height: the panel's own height.
    ///   - railItemCount: rows in the leading column (the three sections, plus the open
    ///     section's categories when symbols are showing).
    public static func resolve(height: CGFloat, railItemCount: Int) -> Self {
        let height = max(0, height)
        let density: Density = height >= 240 ? .regular : (height >= 176 ? .compact : .minimal)
        let title: CGFloat = density == .regular ? 44 : (density == .compact ? 40 : 36)
        // Narrow on purpose: the choices are two or three characters, and every point the column
        // does not take is a point the symbol grid gets.
        let railWidth: CGFloat = 42
        let cellHeight: CGFloat = density == .regular ? 56 : (density == .compact ? 48 : 44)
        let columnWidth: CGFloat = density == .regular ? 64 : (density == .compact ? 58 : 52)
        // Whole phrases (kaomoji and friends) sit in a fixed number of equal columns: wide enough
        // to keep the phrase on one line, dense enough that a whole row is visible at once.
        let kaomojiColumns = 3
        let kaomojiWidth: CGFloat = 72

        // A panel shorter than its own title bar cannot exist, but a mid-animation frame or a very
        // short split layout can still ask for less: scale the bar instead of overflowing.
        let chrome = title + Self.separator
        let scale = chrome > height ? height / chrome : 1
        let content = max(0, height - chrome * scale)
        let slots = max(1, railItemCount)
        let gaps = CGFloat(slots - 1) * Self.separator
        let slot = min(
            Self.railSlotCeiling,
            max(Self.railSlotFloor, (content - gaps) / CGFloat(slots)))

        return Self(
            density: density,
            titleBarHeight: title * scale,
            separatorHeight: Self.separator * scale,
            contentHeight: content,
            railWidth: railWidth,
            railSlotHeight: slot,
            symbolCellMinHeight: cellHeight,
            symbolColumnMinWidth: columnWidth,
            kaomojiColumnMinWidth: kaomojiWidth,
            kaomojiColumnCount: kaomojiColumns,
            showsRecents: density == .regular && content >= 150)
    }
}
