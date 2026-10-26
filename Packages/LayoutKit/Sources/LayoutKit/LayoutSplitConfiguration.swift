import Foundation

/// Widths at or below this are phone-sized surfaces (a folded cover screen is 466 pt): they keep one
/// keyboard under the automatic split, may narrow for one-handed use and never cap their content.
public enum KeyboardSurfaceWidth {
    public static let phoneMaximum = 600.0
}

/// A saved split follows the available keyboard width, including floating windows.
public struct LayoutSplitConfiguration: Codable, Equatable, Sendable {
    /// When a split is shown. Independent from `automaticGap`: this decides whether to split at
    /// all, `automaticGap` only decides how much gutter an active split keeps.
    public enum Activation: String, Codable, Sendable {
        /// Saved row cuts and spacing stay, but rows are never split.
        case off
        /// Split only on wide surfaces: a one-hand phone or folded cover screen keeps one keyboard.
        case automatic
        /// Split at every width; the user explicitly asked for two halves.
        case always
    }

    public var activation: Activation
    public var rowBreaks: [Int]
    public var gapFraction: Double
    /// The gutter follows the width instead of `gapFraction`.
    public var automaticGap: Bool
    public static let defaultGapFraction = 0.32

    public init(activation: Activation = .automatic, rowBreaks: [Int] = [], gapFraction: Double? = nil) {
        self.activation = activation
        self.rowBreaks = rowBreaks
        self.gapFraction = gapFraction ?? Self.defaultGapFraction
        automaticGap = gapFraction == nil
    }

    /// Whether this split really shows at `width`, measured on the whole keyboard.
    public func isActive(width: Double) -> Bool {
        switch activation {
        case .off: return false
        case .always: return true
        case .automatic: return width.isFinite && width > KeyboardSurfaceWidth.phoneMaximum
        }
    }

    /// The split to render at this width, or nil when rows stay whole. Renderers and previews
    /// resolve once against the whole keyboard, so an inner key area narrowed by rails can never
    /// switch the split off a second time.
    public func resolved(forWidth width: Double) -> ActiveLayoutSplit? {
        guard isActive(width: width) else { return nil }
        return ActiveLayoutSplit(rowBreaks: rowBreaks, gapFraction: gapFraction, automaticGap: automaticGap)
    }

    public static func resolving(page: Self?, main: Self?) -> Self? {
        if let page { return page }
        guard var inherited = main else { return nil }
        // Other pages have different key counts and choose their own row boundaries.
        inherited.rowBreaks = []
        return inherited
    }

    public func validate(rowKeyCounts: [Int]) throws {
        guard gapFraction.isFinite, (0...0.85).contains(gapFraction) else {
            throw LayoutError.invalid("拆分间距应在 0% 到 85% 之间，请调整后保存。")
        }
        guard rowBreaks.count <= rowKeyCounts.count else {
            throw LayoutError.invalid("拆分位置比按键行还多，请重新设置拆分位置。")
        }
        for (row, count) in rowBreaks.enumerated() {
            guard rowKeyCounts[row] <= 1 || (1..<rowKeyCounts[row]).contains(count) else {
                throw LayoutError.invalid("拆分位置应在两个按键之间，请调整后保存。")
            }
        }
    }

    /// Character index of the split in a row, whatever the width; editors show it even when the
    /// current surface keeps the row whole.
    public func breakIndex(row: Int, keyCount: Int) -> Int {
        ActiveLayoutSplit.breakIndex(rowBreaks: rowBreaks, row: row, keyCount: keyCount)
    }
}

/// A split that is showing at the current width. Only `LayoutSplitConfiguration.resolved(forWidth:)`
/// creates one, and it is never stored, so geometry never re-applies the width rule.
public struct ActiveLayoutSplit: Equatable, Sendable {
    public let rowBreaks: [Int]
    public let gapFraction: Double
    public let automaticGap: Bool

    /// Each half stays within one thumb's reach on large surfaces.
    public static let maximumThumbHalfWidth = 280.0
    /// Automatic spacing lets a key grow to this width before the rest becomes gutter, so a few
    /// columns on a tablet do not stretch into slabs.
    public static let maximumAutomaticKeyWidth = 84.0
    /// Automatic spacing never shrinks a key below this width.
    public static let minimumAutomaticKeyWidth = 32.0

    /// A nested area (a category grid) inside an already-resolved page: its own setting wins and is
    /// resolved at `width`; otherwise it inherits the page's active spacing with its own row cuts.
    public static func resolving(
        nested: LayoutSplitConfiguration?, parent: ActiveLayoutSplit?, width: Double
    ) -> ActiveLayoutSplit? {
        if let nested { return nested.resolved(forWidth: width) }
        return parent?.withoutRowBreaks
    }

    /// The same spacing for an area with different key counts, which picks its own row cuts.
    public var withoutRowBreaks: ActiveLayoutSplit {
        ActiveLayoutSplit(rowBreaks: [], gapFraction: gapFraction, automaticGap: automaticGap)
    }

    /// The split index in a row.
    public func breakIndex(row: Int, keyCount: Int) -> Int {
        Self.breakIndex(rowBreaks: rowBreaks, row: row, keyCount: keyCount)
    }

    static func breakIndex(rowBreaks: [Int], row: Int, keyCount: Int) -> Int {
        guard keyCount > 1 else { return keyCount }
        let requested = rowBreaks.indices.contains(row) ? rowBreaks[row] : (keyCount + 1) / 2
        return min(keyCount - 1, max(1, requested))
    }

    public func gap(
        width: Double, keyCount: Int, spacing: Double = 4, minimumKeyWidth: Double = 28
    ) -> Double {
        guard keyCount > 1 else { return 0 }
        let keyFloor = automaticGap ? max(Self.minimumAutomaticKeyWidth, minimumKeyWidth) : minimumKeyWidth
        let room = max(0, width - Double(keyCount) * keyFloor - Double(keyCount - 1) * spacing)
        // Keep large surfaces within thumb reach, while narrow windows keep usable keys.
        let maximumContentWidth = min(
            Self.maximumThumbHalfWidth * 2,
            Double(keyCount) * Self.maximumAutomaticKeyWidth + Double(keyCount - 1) * spacing)
        let requested =
            automaticGap
            ? max(width * LayoutSplitConfiguration.defaultGapFraction, width - maximumContentWidth)
            : width * gapFraction
        let result = min(requested, room)
        return result > spacing ? result : 0
    }
}
