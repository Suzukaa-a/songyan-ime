import Foundation

/// Keeps a usable space bar in each half while preserving the surrounding controls.
public struct SplitSpaceRowGeometry: Equatable, Sendable {
    public let gap: Double
    public let spacing: Double
    public let leftWidth: Double
    public let rightWidth: Double
    public let leftSpaceWidth: Double
    public let rightSpaceWidth: Double

    public init?(
        width: Double, requestedGap: Double, leftKeyWidths: [Double], rightKeyWidths: [Double],
        spacing: Double = 4, minimumSpaceWidth: Double = 44, preferredSpaceWidth: Double? = nil
    ) {
        let leftFixed = leftKeyWidths.reduce(0, +) + Double(leftKeyWidths.count) * spacing
        let rightFixed = rightKeyWidths.reduce(0, +) + Double(rightKeyWidths.count) * spacing
        let available = width - leftFixed - rightFixed - spacing
        guard requestedGap > spacing, available - minimumSpaceWidth * 2 > spacing else { return nil }
        // Space takes priority over the gutter, with equal targets under both thumbs.
        let preferred = max(minimumSpaceWidth, preferredSpaceWidth ?? minimumSpaceWidth)
        let fittingSpace = max(minimumSpaceWidth, (available - spacing * 2) / 2)
        let spaceFloor = min(preferred, fittingSpace)
        self.spacing = spacing
        gap = min(requestedGap, available - spaceFloor * 2)
        leftSpaceWidth = (available - gap) / 2
        rightSpaceWidth = leftSpaceWidth
        leftWidth = leftFixed + leftSpaceWidth
        rightWidth = rightFixed + rightSpaceWidth
    }
}
