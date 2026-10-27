import Foundation

/// The single geometry source for the phone (T9) shell: one width solved so the
/// grid exactly fills the same content width as the bottom control row, and one
/// set of row/column boundaries shared by both rails and the 3×3 digit grid.
///
/// Width rule (deterministic, symmetric, **no hidden side slack**):
///
///     contentWidth = leadingRail + gap + [d₀ gap d₁ gap d₂] + gap + trailingRail
///     digit        = min(preferredDigitWidth, (width − 4·gap − 2·minTouch) / 3)
///     rail         = min((width − 3·digit − 4·gap) / 2, digit)
///
/// Digits grow to their preferred 84pt first; every remaining point is then split
/// **equally between the two rails**, so the grid and the bottom control row share
/// exactly one content edge. Capping the rails at a fixed width and turning the
/// remainder into a centring inset *between* the grid and the control row would
/// leave the digit grid ~16pt narrower than the control row on iPhone Air.
///
/// The rails are still capped, but only at the digit width (a rail never out-scales
/// the keys it flanks). Only a shell wider than `max(digit, rail)` in total — i.e.
/// beyond every current iPhone — gains an `outerInset`, and it is applied once
/// around the **whole** shell (grid *and* control row together), so it can never
/// separate the two surfaces. On every supported phone the inset is exactly zero.
///
/// Height is owned here too, not guessed per view: `rowHeight` comes from the size
/// class (44 landscape / 54 portrait) and every digit row, rail slot and the control
/// row is derived from it. Below `3·minTouch + 2·minTouch + 4·gap` the whole unit
/// scales together (previews only), still filling the proposed width exactly.
///
/// Visual insets never touch these rects: `Slot.visualRect` is a separate, pure
/// derivation used only for the drawn keycap, so the layout frame and the hit
/// region are always the layout rect.
public struct PhoneKeypadMetrics: Equatable, Sendable {
    /// The one gap shared by every horizontal and vertical neighbour.
    public static let spacing: Double = 4
    /// Apple's minimum comfortable touch target.
    public static let minimumTouchTarget: Double = 44
    /// Preferred number-key width. Wider shells grow the rails instead.
    public static let preferredDigitWidth: Double = 84
    /// The main grid is always three digit rows; the control row sits outside it.
    public static let mainRowCount: Int = 3
    /// Shell width beyond which the whole shell (grid + control row together) is
    /// centred instead of stretched: exactly the width where the rails would
    /// out-scale the preferred digits. `84·5 + 4·4 = 436pt`, wider than every
    /// current iPhone (largest content width is 432pt), so supported phones get
    /// no side margin at all.
    public static let maximumShellWidth: Double =
        preferredDigitWidth * 5 + spacing * 4

    // MARK: Rect

    /// A pure layout rectangle. Callers must never mutate a slot's frame with a
    /// visual inset; use `visualRect` for the drawn surface instead.
    public struct Slot: Equatable, Sendable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        public var minX: Double { x }
        public var maxX: Double { x + width }
        public var midX: Double { x + width / 2 }
        public var minY: Double { y }
        public var maxY: Double { y + height }
        public var midY: Double { y + height / 2 }

        /// The drawn keycap surface. Insets are visual only: the layout `Slot`
        /// (and therefore the hit region) is unchanged.
        public func visualRect(insetX: Double, insetY: Double) -> Slot {
            Slot(
                x: x + insetX, y: y + insetY,
                width: max(0, width - insetX * 2), height: max(0, height - insetY * 2))
        }
    }

    // MARK: Columns / rows

    public enum Column: Hashable, Sendable {
        case leadingRail
        case digit(Int)
        case trailingRail
    }

    public enum Rail: Hashable, Sendable { case leading, trailing }

    // MARK: Stored geometry

    public let width: Double
    public let spacing: Double
    public let railWidth: Double
    public let digitWidth: Double
    public let rowHeight: Double
    /// The resolved grid width: rail + gap + pad + gap + rail.
    public let contentWidth: Double

    // MARK: Derived widths

    /// The three-column pad including its own two inner gaps.
    public var mainWidth: Double { digitWidth * 3 + spacing * 2 }
    /// Rail + gap + pad + gap + rail; identical to `contentWidth` by construction.
    public var computedContentWidth: Double { railWidth * 2 + mainWidth + spacing * 2 }
    /// Symmetric margin around the whole shell (grid and control row together).
    /// Exactly zero on every supported phone width.
    public var outerInset: Double { max(0, (width - contentWidth) / 2) }
    /// The shell's vertical centre. The two rails mirror about it.
    public var centerlineX: Double { contentWidth / 2 }
    /// Height of a key spanning `rows` stacked digit rows.
    public func spanHeight(_ rows: Int) -> Double {
        let rows = max(1, rows)
        return Double(rows) * rowHeight + Double(rows - 1) * spacing
    }

    // MARK: Derived heights

    /// The three digit rows plus their two inner gaps. The bottom control row is
    /// deliberately **outside** this: the main grid owns exactly three rows.
    public var mainHeight: Double { spanHeight(Self.mainRowCount) }
    /// Top of the bottom control row, in shell coordinates.
    public var controlRowY: Double { mainHeight + spacing }
    /// Grid + gap + control row.
    public var totalHeight: Double { mainHeight + spacing + rowHeight }

    // MARK: Columns

    public func columnRect(_ column: Column) -> Slot {
        let height = mainHeight
        switch column {
        case .leadingRail: return Slot(x: 0, y: 0, width: railWidth, height: height)
        case .trailingRail:
            return Slot(x: contentWidth - railWidth, y: 0, width: railWidth, height: height)
        case .digit(let index):
            guard (0..<3).contains(index) else { return Slot(x: 0, y: 0, width: 0, height: height) }
            let x = railWidth + spacing + Double(index) * (digitWidth + spacing)
            return Slot(x: x, y: 0, width: digitWidth, height: height)
        }
    }

    /// Left/right symmetry of the two rails about `centerlineX`.
    public func railsAreSymmetric() -> Bool {
        let left = columnRect(.leadingRail)
        let right = columnRect(.trailingRail)
        return abs(left.width - right.width) < 1e-9
            && abs(left.minX - (contentWidth - right.maxX)) < 1e-9
            && abs(left.midX + right.midX - contentWidth) < 1e-9
    }

    // MARK: Rows

    /// Top of digit row `index` (0...2), in shell coordinates.
    public func rowY(_ index: Int) -> Double {
        Double(index) * (rowHeight + spacing)
    }

    /// The full-width band of digit row `index`: rails and digits share this
    /// baseline exactly, so a rail slot never guesses at a vertical offset.
    public func mainRowRect(_ index: Int) -> Slot {
        Slot(x: 0, y: rowY(index), width: contentWidth, height: rowHeight)
    }

    public func digitCellRect(row: Int, column: Int) -> Slot {
        let cell = columnRect(.digit(column))
        return Slot(x: cell.x, y: rowY(row), width: digitWidth, height: rowHeight)
    }

    /// The bottom control row, spanning exactly the grid's content width.
    public func controlRowRect() -> Slot {
        Slot(x: 0, y: controlRowY, width: contentWidth, height: rowHeight)
    }

    /// The control row when the trailing column runs down beside it (bundled T9):
    /// it ends one gap before that column.
    public func controlRowRectBesideTrailingRail() -> Slot {
        Slot(x: 0, y: controlRowY, width: max(0, contentWidth - railWidth - spacing), height: rowHeight)
    }

    // MARK: Rails

    /// Deterministic rail slots laid out top-to-bottom in a `spacing`-paced stack,
    /// one entry per requested row span.
    ///
    /// A span of `1` is one digit row; a span of `2` is a double-height key whose
    /// top aligns with its first row and whose bottom aligns with its last row. The
    /// next slot resumes after the ordinary gap, so
    /// `railSlots(.trailing, spans: [1, 1, 2])` reproduces the bundled T9 column —
    /// Delete(row 0) + 重输(row 1) + Return/Confirm(row 2 and the control row, which
    /// is `spacing` below the grid exactly like a fourth row) — with no `maxHeight`
    /// inflation and no independent `VStack` guess. More than three single-row slots
    /// continue below the grid (the leading rail scrolls); they still share the
    /// digit row rhythm.
    public func railSlots(_ rail: Rail, spans: [Int]) -> [Slot] {
        let x = rail == .leading ? 0 : contentWidth - railWidth
        var y = 0.0
        var slots: [Slot] = []
        for span in spans {
            let height = spanHeight(span)
            slots.append(Slot(x: x, y: y, width: railWidth, height: height))
            y += height + spacing
        }
        return slots
    }

    /// Convenience for a rail whose keys each occupy one row.
    public func railSlots(_ rail: Rail, count: Int) -> [Slot] {
        railSlots(rail, spans: Array(repeating: 1, count: max(0, count)))
    }

    /// Deterministic row spans for a rail with `keyCount` keys. When the rail has
    /// fewer keys than the grid has rows, the surplus rows go to the **first**
    /// slot, so e.g. 2 keys over 3 rows becomes [2, 1]: the first key is
    /// double-height (top aligned with row 0, bottom aligned with row 1) and the
    /// second key sits on row 2. This is the general imported-rail default (the
    /// bundled T9 authors its own `bundledTrailingSpans` instead); it aligns rail
    /// keys with the digit rows without any `maxHeight` guess, and it is independent
    /// of any other rail's key count. A rail with at least `rowCount` keys stays one
    /// row per key (it scrolls past the grid).
    public static func slotSpans(keyCount: Int, rowCount: Int = PhoneKeypadMetrics.mainRowCount) -> [Int] {
        let count = max(0, keyCount)
        let rows = max(1, rowCount)
        guard count > 0 else { return [] }
        if count >= rows { return Array(repeating: 1, count: count) }
        return [rows - (count - 1)] + Array(repeating: 1, count: count - 1)
    }

    /// Rail slots resolved directly from a key count via `slotSpans`.
    public func railSlots(_ rail: Rail, keyCount: Int) -> [Slot] {
        railSlots(rail, spans: Self.slotSpans(keyCount: keyCount))
    }

    // MARK: Resolution

    public static func resolve(
        width rawWidth: Double,
        rowHeight rawRowHeight: Double = 54
    ) -> PhoneKeypadMetrics {
        let width = rawWidth.isFinite ? max(0, rawWidth) : 0
        let rowHeight = rawRowHeight.isFinite ? max(0, rawRowHeight) : 0
        guard width > 0 else {
            return PhoneKeypadMetrics(
                width: 0, spacing: 0, railWidth: 0, digitWidth: 0,
                rowHeight: rowHeight, contentWidth: 0)
        }

        let shellWidth = min(width, maximumShellWidth)
        let minimumContent = minimumTouchTarget * 2 + minimumTouchTarget * 3 + spacing * 4
        var spacing = Self.spacing
        var rail: Double
        var digit: Double

        if shellWidth < minimumContent {
            // Too narrow for the real grid (previews): scale the whole unit down
            // together, so the identity above still holds exactly and no key is
            // clipped or out-scales a peer.
            let scale = shellWidth / minimumContent
            spacing *= scale
            rail = minimumTouchTarget * scale
            digit = minimumTouchTarget * scale
        } else {
            // Digits grow to their preferred width while the rails stay at the
            // touch minimum; the whole surplus beyond that goes to the two rails
            // equally. No centring inset is inserted between the grid and the
            // control row, so no invisible side slack remains.
            let digitAvailable = (shellWidth - spacing * 4 - minimumTouchTarget * 2) / 3
            digit = min(preferredDigitWidth, digitAvailable)
            rail = min((shellWidth - digit * 3 - spacing * 4) / 2, digit)
            // Guard the touch minimum against a pathological cap interaction.
            if rail < minimumTouchTarget {
                rail = minimumTouchTarget
                digit = max(0, (shellWidth - spacing * 4 - rail * 2) / 3)
            }
        }
        rail = max(0, rail)
        digit = max(0, digit)
        let content = rail * 2 + digit * 3 + spacing * 4
        return PhoneKeypadMetrics(
            width: width, spacing: spacing, railWidth: rail,
            digitWidth: digit, rowHeight: rowHeight, contentWidth: content)
    }
}
