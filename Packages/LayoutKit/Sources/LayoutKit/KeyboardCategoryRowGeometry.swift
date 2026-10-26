import Foundation

/// A tail row reuses the preceding full row's column scale instead of stretching its keys.
public struct KeyboardCategoryRowGeometry: Equatable, Sendable {
    /// Gap between neighboring keys, matching the other key rows.
    public static let spacing = 4.0
    /// Narrowest key a split row keeps; a two-column category holds phrases, so its halves stay wide.
    public static let minimumKeyWidth = 28.0
    public static let minimumPhraseKeyWidth = 140.0

    public let keyWidths: [Double]
    public let gap: Double
    public let splitIndex: Int
    public let usedWidth: Double

    /// `weights` holds one entry per key in this row; a row never has more keys than `columns`.
    public init(
        width: Double, columns: Int, weights: [Double], row: Int, split: ActiveLayoutSplit?,
        referenceWeights: [Double]? = nil
    ) {
        let columns = max(columns, weights.count, 1)
        let spacing = Self.spacing
        let minimumKeyWidth = columns == 2 ? Self.minimumPhraseKeyWidth : Self.minimumKeyWidth
        let fullGap = split?.gap(width: width, keyCount: columns, minimumKeyWidth: minimumKeyWidth) ?? 0
        splitIndex = split?.breakIndex(row: row, keyCount: columns) ?? columns
        gap = weights.count > splitIndex ? fullGap : 0
        let reference = referenceWeights ?? weights
        let average = reference.isEmpty ? 1 : reference.map { $0 / Double(reference.count) }.reduce(0, +)
        let emptyWeights = (weights.count..<columns).map { $0 < reference.count ? reference[$0] : average }
        let projection = LayoutRowWidthProjection(weights: weights + emptyWeights)
        let available = max(0, width - fullGap - Double(columns - 1) * spacing)
        keyWidths = projection.keyFractions.prefix(weights.count).map { available * $0 }
        usedWidth = keyWidths.reduce(0, +) + Double(max(0, weights.count - 1)) * spacing + gap
    }
}
