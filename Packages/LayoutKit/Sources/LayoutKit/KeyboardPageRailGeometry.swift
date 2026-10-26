import Foundation

/// Vertical spans for a leading/trailing rail, shared by the runtime and the preview so both
/// place the same authored keys at the same heights.
///
/// A rail key's `width` is a relative vertical span, not a width. With total height H, spacing
/// s and spans summing to S, key i is `(H + s) * span_i / S - s`; each height is then raised to
/// the minimum tap height. When the minimum pushes the rail past H the caller scrolls it instead
/// of compressing keys below a usable size.
public struct KeyboardPageRailGeometry: Equatable, Sendable {
    public let keyHeights: [Double]
    /// Total rail content height including inter-key spacing; scroll when it exceeds H.
    public let contentHeight: Double
    public let spacing: Double

    public init(
        height: Double, weights: [Double], spacing: Double = 4, minimumKeyHeight: Double = 44
    ) {
        let resolvedSpacing = spacing.isFinite ? max(0, spacing) : 0
        let resolvedHeight = height.isFinite ? max(0, height) : 0
        let minimum = minimumKeyHeight.isFinite ? max(0, minimumKeyHeight) : 0
        self.spacing = resolvedSpacing
        let safeWeights = weights.map { $0.isFinite && $0 > 0 ? $0 : 0 }
        // Divide by the largest weight before summing so legal largest-magnitude values cannot
        // overflow the total or the per-key multiplication.
        let scale = safeWeights.max() ?? 0
        let normalized = scale > 0 ? safeWeights.map { $0 / scale } : safeWeights
        let total = normalized.reduce(0, +)
        guard !weights.isEmpty else {
            keyHeights = []
            contentHeight = 0
            return
        }
        guard total > 0 else {
            // Unvalidated preview weights: keep every span at the usable minimum instead of
            // borrowing the whole rail height for each key.
            keyHeights = weights.map { _ in minimum }
            contentHeight =
                keyHeights.reduce(0, +) + resolvedSpacing * Double(weights.count - 1)
            return
        }
        keyHeights = normalized.map { weight in
            let raw = (resolvedHeight + resolvedSpacing) * weight / total - resolvedSpacing
            return max(minimum, raw)
        }
        contentHeight = keyHeights.reduce(0, +) + resolvedSpacing * Double(weights.count - 1)
    }
}
