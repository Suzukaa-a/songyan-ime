import Foundation

/// A tail row reuses the preceding full row's column scale instead of stretching its keys.
public struct KeyboardCategoryRowGeometry: Equatable, Sendable {
    public let keyWidths: [Double]
    public let gap: Double
    public let splitIndex: Int
    public let usedWidth: Double

    public init(
        width: Double, columns: Int, weights: [Double], row: Int, split: LayoutSplitConfiguration?,
        referenceWeights: [Double]? = nil
    ) {
        let fullGap = split?.gap(width: width, keyCount: columns, minimumKeyWidth: columns == 2 ? 140 : 28) ?? 0
        splitIndex = split?.breakIndex(row: row, keyCount: columns, width: width) ?? columns
        gap = weights.count > splitIndex ? fullGap : 0
        let reference = referenceWeights ?? weights
        let average = reference.map { $0 / Double(reference.count) }.reduce(0, +)
        let emptyWeights = (weights.count..<columns).map { $0 < reference.count ? reference[$0] : average }
        let projection = LayoutRowWidthProjection(weights: weights + emptyWeights)
        let available = max(0, width - fullGap - Double(columns - 1) * 4)
        keyWidths = projection.keyFractions.prefix(weights.count).map { available * $0 }
        usedWidth = keyWidths.reduce(0, +) + Double(max(0, weights.count - 1)) * 4 + gap
    }
}
