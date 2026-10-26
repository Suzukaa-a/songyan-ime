import Foundation

/// A saved split follows the available keyboard width, including floating windows.
public struct LayoutSplitConfiguration: Codable, Equatable, Sendable {
    /// When a split is shown. Independent from `automaticGap`: this decides whether to split at
    /// all, `automaticGap` only decides how much gutter an active split keeps.
    public enum Activation: String, Codable, Sendable {
        /// Split only on wide surfaces: a one-hand phone or folded cover screen keeps one
        /// keyboard. The old `enabled: true` catalogs decode to this.
        case automatic
        /// Split at every width; the user explicitly asked for two halves.
        case always
    }

    /// Widths at or below this stay unsplit under `.automatic`. A folded cover screen (466 pt)
    /// and a portrait phone fit one hand; tablet and landscape widths do not.
    public static let automaticMaximumWidth = 600.0

    public var enabled: Bool
    public var rowBreaks: [Int]
    public var gapFraction: Double
    /// Nil preserves the explicit spacing of catalogs saved before automatic spacing.
    public var automaticGap: Bool?
    /// How the split decides whether to appear. Nil means `.automatic`.
    public var activation: Activation?
    public static let defaultGapFraction = 0.32
    public static let maximumThumbHalfWidth = 280.0

    public init(
        enabled: Bool = true, rowBreaks: [Int] = [], gapFraction: Double? = nil,
        activation: Activation? = nil
    ) {
        self.enabled = enabled
        self.rowBreaks = rowBreaks
        self.gapFraction = gapFraction ?? Self.defaultGapFraction
        automaticGap = gapFraction == nil ? true : nil
        self.activation = activation
    }

    /// Whether this split really shows at `width`. `.always` ignores the width rule; `.automatic`
    /// (the nil default) keeps narrow surfaces whole.
    public func isActive(width: Double) -> Bool {
        guard enabled else { return false }
        guard activation != .always else { return true }
        return width.isFinite && width > Self.automaticMaximumWidth
    }

    /// The split to render at this width, or nil when the row stays whole. Renderers/previews
    /// take this once per layout pass instead of reading `enabled` alone.
    ///
    /// The width check happens once against the whole keyboard. The returned copy is marked
    /// `.always` (only in memory, never saved) so an inner key area narrowed by rails cannot make
    /// the automatic rule switch the split off a second time.
    public func resolved(forWidth width: Double) -> LayoutSplitConfiguration? {
        guard isActive(width: width) else { return nil }
        var resolved = self
        resolved.activation = .always
        return resolved
    }

    public static func resolving(page: Self?, main: Self?) -> Self? {
        if let page { return page }
        guard var inherited = main else { return nil }
        // Other pages have different key counts and choose their own row boundaries.
        inherited.rowBreaks = []
        return inherited
    }

    public func validate(rowKeyCounts: [Int]) throws {
        guard gapFraction.isFinite, (0...0.85).contains(gapFraction),
            rowBreaks.count <= rowKeyCounts.count
        else { throw LayoutError.invalid("拆分间距应在 0% 到 85% 之间，请调整后保存。") }
        for (row, count) in rowBreaks.enumerated() {
            guard rowKeyCounts[row] <= 1 || (1..<rowKeyCounts[row]).contains(count) else {
                throw LayoutError.invalid("拆分位置应在两个按键之间，请调整后保存。")
            }
        }
    }

    /// Character index of the split in a row, ignoring the width activation rule.
    public func breakIndex(row: Int, keyCount: Int) -> Int {
        guard keyCount > 1 else { return keyCount }
        let requested = rowBreaks.indices.contains(row) ? rowBreaks[row] : (keyCount + 1) / 2
        return min(keyCount - 1, max(1, requested))
    }

    /// The split index to render at this width, or nil when the row stays whole.
    public func breakIndex(row: Int, keyCount: Int, width: Double) -> Int? {
        guard isActive(width: width) else { return nil }
        return breakIndex(row: row, keyCount: keyCount)
    }

    public func gap(
        width: Double, keyCount: Int, spacing: Double = 4, minimumKeyWidth: Double = 28
    ) -> Double {
        guard isActive(width: width), keyCount > 1 else { return 0 }
        let automatic = automaticGap == true
        let keyFloor = automatic ? max(32, minimumKeyWidth) : minimumKeyWidth
        let room = max(0, width - Double(keyCount) * keyFloor - Double(keyCount - 1) * spacing)
        // Keep large surfaces within thumb reach, while narrow windows keep usable keys.
        let maximumContentWidth = min(
            Self.maximumThumbHalfWidth * 2,
            Double(keyCount) * PhoneKeypadMetrics.preferredDigitWidth + Double(keyCount - 1) * spacing)
        let requested =
            automatic
            ? max(width * Self.defaultGapFraction, width - maximumContentWidth)
            : width * gapFraction
        let result = min(requested, room)
        return result > spacing ? result : 0
    }
}
