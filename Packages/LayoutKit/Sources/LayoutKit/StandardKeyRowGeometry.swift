import Foundation

/// Character rows share ten columns; controls absorb the remaining third-row width.
public struct StandardKeyRowGeometry: Equatable, Sendable {
    public let gap: Double
    public let keyWidth: Double
    public let thirdRowSideWidth: Double

    public init(width: Double, split: LayoutSplitConfiguration? = nil, spacing: Double = 4) {
        let width = max(0, width)
        gap = split?.gap(width: width, keyCount: 10, spacing: spacing) ?? 0
        keyWidth = max(0, (width - gap - spacing * 9) / 10)
        thirdRowSideWidth = max(0, (width - gap - keyWidth * 7 - spacing * 8) / 2)
    }
}
