import CoreGraphics
import Foundation

/// Blind alternate picking for the long-press key popup.
///
/// Why this exists: once a long press has committed to the popup, asking the
/// finger to land exactly on a 44pt cell is both slow and unreliable — the popup
/// sits above the key, far from the finger's natural travel, and the finger
/// covers the cell it is aiming at. This picker therefore maps the **horizontal
/// distance from the long-press origin** to the option column (one column pitch
/// per step, dead-zoned and hysteretic), and uses the finger's vertical position
/// only to choose the row — clamped, so dragging above the popup, or drifting a
/// little below where the finger started, keeps the current row instead of
/// cancelling.
///
/// Deliberately preserved:
///  - a stationary finger never *chooses* an option by itself (`Tuning.deadZone`,
///    applied per axis, so a diagonal wobble is not a move): it keeps whatever
///    the caller already highlighted. An ordinary key's popup opens on the
///    deterministic `defaultSelection` (the first fully visible option — the
///    key-face hint), so a stationary long press commits that option; the
///    preference-writing pickers seed nothing of the kind;
///  - jitter around a cell boundary never flickers (`Tuning.hysteresis`);
///  - sliding horizontally past the option band cancels the pick
///    (`Tuning.cancelMargin`) — "slide out cancels", expressed in the axis
///    the picker actually uses;
///  - pulling the finger clearly **down**, away from the popup, also cancels
///    (`Tuning.cancelDrop`). This is the cancel an edge key can always reach:
///    a popup opened from a screen-edge key (or one as wide as the screen) is
///    clamped flush to the safe edge, so the finger physically cannot travel
///    `cancelMargin` past the band on the outward side. The popup never opens
///    below the key, so "down" is always "away". The drop is measured on
///    screen (not in content coordinates, which move with the auto-scroll), and
///    only downward: upward overshoot toward/through the popup and small
///    downward drift stay tolerated;
///  - 2- and 3-option popups are symmetric about the finger: the column anchor is
///    the origin's continuous column, not the rounded nearest cell, so a move
///    either way needs the same travel;
///  - a vertical-only drift never chooses a column: it keeps the chosen column,
///    or on a first choice takes the origin's deterministic column (ties toward
///    the leading edge, so an even-column boundary never biases right); a
///    single-row popup has no row information, so a vertical-only first move
///    selects nothing;
///  - cells that are not **fully** inside the viewport are never selectable:
///    `Geometry.viewport` (real content coordinates) plus `visibleRows` express
///    the popup's actual visible cells, so a column clipped by the safe bounds, a
///    row scrolled out of the scroll view, a partially clipped cell and an empty
///    trailing position in a partial last row are all unselectable;
///  - the popup's own placement, screen-edge clamping/flip, the keyboard
///    geometry and the option frames are untouched: this type is arithmetic on
///    points that are already in the popup's content coordinate space;
///  - `requiresExplicitAlternateSelection` stays a *separate* gate
///    (`ExplicitAlternateSelection`) — this type never decides whether an
///    intent is explicit enough to write shared preferences.
///
/// The release decision is also pure (`releaseResolution`): a highlighted, fully
/// visible option commits; a deliberate horizontal slide-out, a deliberate drop
/// below the opening point, or a highlight that is no longer visible, commits
/// nothing. A popup never commits the key it was
/// opened from — a press whose popup never opened is still an ordinary tap, which
/// the panel handles without this type. The panel wires it; this type never
/// dispatches.
public enum AlternateDragPicker {

    /// Static geometry of the option grid, in the popup's content coordinates
    /// (the same space `UIScrollView.convert(_:from:)` produces, so vertical
    /// auto-scroll is accounted for by the caller).
    ///
    /// Horizontal and vertical gaps are separate because the popup places its
    /// cells that way: columns are separated by `spacing` (4pt) while rows are
    /// packed edge to edge (`rowSpacing` 0), and the label frames are built from
    /// exactly these pitches.
    public struct Geometry: Equatable, Sendable {
        public let optionCount: Int
        public let columns: Int
        public let cellWidth: Double
        public let cellHeight: Double
        public let spacing: Double
        public let rowSpacing: Double
        /// Convenience viewport for the common vertical-scroll case: only these
        /// rows are shown, across the full grid width. `nil` = every row.
        public let visibleRows: Range<Int>?
        /// The real popup viewport in **content** coordinates — a scroll view's
        /// bounds, or the safe-area-clamped popup frame. A cell is selectable only
        /// when it is **fully** inside it, so a partially clipped cell (an edge
        /// column cut by the safe bounds, or a row cut by the scroll viewport) is
        /// not selectable even though its content coordinates still exist.
        /// `nil` = the whole grid is visible. When both are given, the effective
        /// viewport is their intersection.
        public let viewport: CGRect?

        public init(
            optionCount: Int, columns: Int, cellWidth: Double,
            cellHeight: Double, spacing: Double, rowSpacing: Double? = nil,
            visibleRows: Range<Int>? = nil, viewport: CGRect? = nil
        ) {
            self.optionCount = max(0, optionCount)
            self.columns = max(1, columns)
            self.cellWidth = max(0, cellWidth)
            self.cellHeight = max(0, cellHeight)
            self.spacing = max(0, spacing)
            self.rowSpacing = max(0, rowSpacing ?? spacing)
            self.visibleRows = visibleRows
            self.viewport = viewport
        }

        /// Rows needed for `optionCount` options; the last row may be partial.
        public var rows: Int { optionCount == 0 ? 0 : (optionCount + columns - 1) / columns }
        public var pitchX: Double { cellWidth + spacing }
        public var pitchY: Double { cellHeight + rowSpacing }
        public var contentWidth: Double {
            Double(columns) * cellWidth + Double(columns - 1) * spacing
        }
        public var contentHeight: Double {
            rows == 0 ? 0 : Double(rows) * cellHeight + Double(rows - 1) * rowSpacing
        }
        /// The grid's own extent in content coordinates.
        public var contentRect: CGRect {
            CGRect(x: 0, y: 0, width: contentWidth, height: contentHeight)
        }

        /// The same grid seen through a different real viewport (for a scroll
        /// view: its current bounds, which move with the edge auto-scroll).
        public func withViewport(_ viewport: CGRect?) -> Geometry {
            Geometry(
                optionCount: optionCount, columns: columns, cellWidth: cellWidth,
                cellHeight: cellHeight, spacing: spacing, rowSpacing: rowSpacing,
                visibleRows: visibleRows, viewport: viewport)
        }

        public func contains(index: Int) -> Bool { index >= 0 && index < optionCount }
        public func column(of index: Int) -> Int { index % columns }
        public func row(of index: Int) -> Int { index / columns }

        /// The intersection of the grid extent, the `visibleRows` shorthand and
        /// the real `viewport`. `.null` when nothing is visible. Every selectable
        /// cell must be fully contained in this rect.
        public var visibleRect: CGRect {
            guard optionCount > 0 else { return .null }
            var rect = contentRect
            if let visibleRows {
                let lower = max(0, min(visibleRows.lowerBound, rows))
                let upper = max(lower, min(visibleRows.upperBound, rows))
                guard upper > lower else { return .null }
                let height = Double(upper - lower) * pitchY - rowSpacing
                rect = rect.intersection(
                    CGRect(
                        x: 0, y: Double(lower) * pitchY,
                        width: contentWidth, height: height))
            }
            if let viewport { rect = rect.intersection(viewport) }
            return rect.isNull ? .null : rect
        }

        /// The cell's frame in content coordinates (`.null` for a non-option).
        public func cellRect(of index: Int) -> CGRect {
            guard contains(index: index) else { return .null }
            return CGRect(
                x: Double(column(of: index)) * pitchX,
                y: Double(row(of: index)) * pitchY,
                width: cellWidth, height: cellHeight)
        }

        /// Absorbs floating-point round-off only. The grid extent is computed as
        /// `columns * cellWidth + gaps` while a cell edge is `column * pitch +
        /// cellWidth`; for a fractional (measured) cell width they can differ by
        /// an ulp, which must not turn the last column into a "clipped" one. Any
        /// real clip is at least a fraction of a pixel, far above this.
        static let containmentTolerance = 1e-6

        /// A cell is selectable only when it is **fully** inside `visibleRect`:
        /// partially clipped cells are never selectable.
        public func isVisible(index: Int) -> Bool {
            guard contains(index: index) else { return false }
            let cell = cellRect(of: index)
            guard cell.width > 0, cell.height > 0 else { return false }
            let rect = visibleRect
            guard !rect.isNull, !rect.isEmpty else { return false }
            let tolerance = Self.containmentTolerance
            return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(cell)
        }

        /// The contiguous span of columns that have a fully-visible cell in
        /// `row`; nil when the row has no fully-visible cell. The span is assumed
        /// contiguous (a viewport cutting a hole in the middle of a row is not a
        /// popup shape), and `clampColumn` still re-checks visibility per cell.
        public func visibleColumns(inRow row: Int) -> ClosedRange<Int>? {
            let columnsInRow = optionCount(inRow: row)
            guard columnsInRow > 0 else { return nil }
            let first = row * columns
            let visible = (0..<columnsInRow).filter { isVisible(index: first + $0) }
            guard let lower = visible.first, let upper = visible.last else { return nil }
            return lower...upper
        }

        /// Rows with at least one fully-visible cell.
        public var visibleRowRange: ClosedRange<Int>? {
            let visible = (0..<rows).filter { visibleColumns(inRow: $0) != nil }
            guard let lower = visible.first, let upper = visible.last else { return nil }
            return lower...upper
        }

        public func isRowVisible(_ row: Int) -> Bool { visibleColumns(inRow: row) != nil }

        /// Number of cells that actually exist in `row` (the last row may be
        /// partial); 0 for a row that does not exist.
        public func optionCount(inRow row: Int) -> Int {
            guard row >= 0, row < rows else { return 0 }
            return min(columns, optionCount - row * columns)
        }

        /// Clamp `column` into the cells of `row` that are both real and fully
        /// visible; nil when the row has no such cell. This is what keeps an empty
        /// trailing position in a partial last row, and a column clipped by the
        /// viewport, from being selected.
        public func clampColumn(_ column: Int, inRow row: Int) -> Int? {
            guard let visible = visibleColumns(inRow: row) else { return nil }
            return min(max(column, visible.lowerBound), visible.upperBound)
        }

        public func centerX(ofColumn column: Int) -> Double {
            Double(column) * pitchX + cellWidth / 2
        }
        public func centerY(ofRow row: Int) -> Double {
            Double(row) * pitchY + cellHeight / 2
        }

        /// The origin's column as a continuous coordinate, not snapped to the
        /// nearest integer cell. Anchoring the blind mapping here (instead of the
        /// nearest column) makes 2- and 3-option popups symmetric about the
        /// finger: a move either way needs the same travel.
        public func continuousColumn(of x: Double) -> Double {
            guard pitchX > 0, x.isFinite else { return 0 }
            return (x - cellWidth / 2) / pitchX
        }

        /// The origin's column, snapped deterministically with ties resolved
        /// toward the **leading** edge. Used when a move carries no horizontal
        /// information (vertical-only drift), so an origin exactly on an even
        /// column boundary never biases to the right.
        public func originColumn(to x: Double) -> Int {
            guard pitchX > 0, x.isFinite else { return 0 }
            let raw = (x - cellWidth / 2) / pitchX
            guard raw.isFinite else { return 0 }
            let tiesLeading = (raw - 0.5).rounded(.up)
            guard tiesLeading.isFinite else { return 0 }
            return min(max(Int(tiesLeading), 0), columns - 1)
        }

        /// Column whose centre is closest to `x`, clamped into the grid so a
        /// finger outside the band still names a stable column.
        public func nearestColumn(to x: Double) -> Int {
            guard pitchX > 0, x.isFinite else { return 0 }
            let raw = ((x - cellWidth / 2) / pitchX).rounded()
            guard raw.isFinite else { return 0 }
            return min(max(Int(raw), 0), columns - 1)
        }

        /// Row whose centre is closest to `y`, clamped into the grid: vertical
        /// travel past the popup keeps selecting the nearest row.
        public func nearestRow(to y: Double) -> Int {
            guard rows > 0, pitchY > 0, y.isFinite else { return 0 }
            let raw = ((y - cellHeight / 2) / pitchY).rounded()
            guard raw.isFinite else { return 0 }
            return min(max(Int(raw), 0), rows - 1)
        }

        /// The row the blind mapping may address: the nearest visible row, or nil
        /// when the popup shows no fully-visible cell at all.
        public func nearestVisibleRow(to y: Double) -> Int? {
            guard rows > 0 else { return nil }
            let target = nearestRow(to: y)
            if visibleColumns(inRow: target) != nil { return target }
            let candidates = (0..<rows).filter { visibleColumns(inRow: $0) != nil }
            guard !candidates.isEmpty else { return nil }
            return candidates.min { abs($0 - target) < abs($1 - target) }
        }
    }

    /// One place for the feel of the blind drag.
    public enum Tuning {
        /// A stationary finger (or sub-threshold jitter) never highlights an
        /// option. The dead zone is **per axis**: an axis only contributes once
        /// the finger has left the origin by this much on *that* axis, so a
        /// diagonal wobble that crosses the radius but neither axis is not a move.
        public static let deadZone: Double = 12
        /// Extra travel needed to leave the currently highlighted cell, per
        /// axis. This is what stops a finger resting on a boundary from
        /// flickering between two options.
        public static let hysteresis: Double = 8
        /// Deliberate horizontal overshoot past the option band that cancels the
        /// pick (keeps "slide out to cancel" in the axis the mapping uses).
        public static let cancelMargin: Double = 28
        /// Deliberate downward travel, in screen points from where the finger
        /// was when the popup opened, that cancels the pick. It is the cancel
        /// that stays reachable when the popup is clamped against a screen edge
        /// and the horizontal overshoot is not. About one and a third key rows:
        /// 44pt was reached by an ordinary sloppy hold and cancelled by accident.
        /// The popup fades with `dropProgress` on the way, so the cancel is seen
        /// coming and can be undone by moving back up.
        public static let cancelDrop: Double = 72
        /// Downward travel below which the popup shows no cancel feedback at all.
        public static let cancelFeedbackStart: Double = 16
    }

    /// What a completed long press resolves to when the finger lifts. Pure value:
    /// the panel still owns dispatch, this only decides *what* to dispatch.
    public enum ReleaseResolution: Equatable, Sendable {
        /// Commit a highlighted, still fully visible alternate.
        case alternate(Int)
        /// Commit nothing: slid out of the band, no highlight, or the highlight is
        /// no longer visible (scrolled out / clipped / out of range).
        case none
    }

    /// The deterministic option an ordinary key's popup opens on, highlighted
    /// before the finger moves: the first option in array order that is fully
    /// visible in `geometry` (normally index 0, the key-face hint). Nil only when
    /// no option is visible at all — then the popup has nothing to offer and
    /// the caller must not treat the press as an opened popup.
    public static func defaultSelection(geometry g: Geometry) -> Int? {
        (0..<g.optionCount).first { g.isVisible(index: $0) }
    }

    /// 0 until `Tuning.cancelFeedbackStart`, rising to 1 at `Tuning.cancelDrop`:
    /// how far a downward pull has gone toward cancelling (drives the fade).
    public static func dropProgress(_ drop: Double) -> Double {
        guard drop.isFinite else { return 0 }
        let span = Tuning.cancelDrop - Tuning.cancelFeedbackStart
        return min(1, max(0, (drop - Tuning.cancelFeedbackStart) / span))
    }

    /// True while the finger is inside the per-axis dead zone around `origin`
    /// (both in popup content coordinates): it has not moved on purpose.
    public static func isWithinDeadZone(origin: CGPoint, point: CGPoint) -> Bool {
        let dx = Double(point.x) - Double(origin.x)
        let dy = Double(point.y) - Double(origin.y)
        guard dx.isFinite, dy.isFinite else { return true }
        return abs(dx) < Tuning.deadZone && abs(dy) < Tuning.deadZone
    }

    /// The one slide-out-cancel predicate.
    ///
    /// - Parameters:
    ///   - point: the finger, in popup **content** coordinates: a horizontal
    ///     overshoot of `Tuning.cancelMargin` past the band cancels.
    ///   - geometry: the popup's grid.
    ///   - drop: the finger's **screen-space** downward travel since the popup
    ///     opened (positive = down, away from the popup). `Tuning.cancelDrop` or
    ///     more cancels. Content-space `y` cannot express this: it shifts with
    ///     the popup's auto-scroll. Upward travel (negative) never cancels.
    public static func isCancelled(point: CGPoint, geometry g: Geometry, drop: Double = 0) -> Bool {
        if drop.isFinite, drop >= Tuning.cancelDrop { return true }
        let x = Double(point.x)
        guard x.isFinite else { return false }
        return x < -Tuning.cancelMargin || x > g.contentWidth + Tuning.cancelMargin
    }

    /// Resolve a release from the last highlight and finger position.
    ///
    /// Only a highlighted, fully visible option commits. A deliberate slide-out
    /// or drop (`isCancelled`, same `drop` as the last `selection`) wins over
    /// any stale highlight, and an invisible / out-of-range highlight never
    /// commits. There is no "commit the primary key" outcome: an ordinary
    /// popup always opens on a visible default (`defaultSelection`), and the
    /// preference-writing pickers must never type their primary action from a
    /// popup.
    public static func releaseResolution(
        highlighted: Int?, point: CGPoint,
        geometry g: Geometry,
        drop: Double = 0
    ) -> ReleaseResolution {
        if isCancelled(point: point, geometry: g, drop: drop) { return .none }
        if let highlighted, g.isVisible(index: highlighted) { return .alternate(highlighted) }
        return .none
    }

    /// Keeps a highlight that is *not* under the finger — the opening default —
    /// from jumping against the finger's motion.
    ///
    /// The blind drag maps the finger's absolute position (so every option stays
    /// reachable on a narrow screen), but an ordinary popup opens on option 0,
    /// which is usually not the cell nearest the finger. Without this guard, a
    /// finger sitting right of the default that drifts *left* past the dead zone
    /// would move the highlight *right* to the cell under it — and a small drift
    /// would commit a different symbol than the one on screen. The rule, per
    /// axis: the highlight may only change toward a higher column/row after the
    /// finger has travelled at least `Tuning.deadZone` in that direction from the
    /// extreme it reached the other way (and symmetrically). Once the highlight
    /// does change, it is under the finger again and the reference restarts
    /// there, so ordinary absolute tracking — including its boundary hysteresis
    /// — is unchanged. It filters only; slide-out cancel (`nil`) and visibility
    /// are still decided by `selection`.
    public struct MotionGuard: Equatable, Sendable {
        private var minX: Double
        private var maxX: Double
        private var minY: Double
        private var maxY: Double

        /// Starts at the long-press origin, in popup content coordinates.
        public init(origin: CGPoint) {
            let x = Double(origin.x), y = Double(origin.y)
            minX = x.isFinite ? x : 0
            maxX = minX
            minY = y.isFinite ? y : 0
            maxY = minY
        }

        private mutating func restart(at x: Double, _ y: Double) {
            minX = x
            maxX = x
            minY = y
            maxY = y
        }

        /// Filters `proposed` (the value `selection` just returned for `point`)
        /// against `current` (the highlight before this move).
        public mutating func resolve(
            proposed: Int?, current: Int?, point: CGPoint,
            geometry g: Geometry
        ) -> Int? {
            let x = Double(point.x), y = Double(point.y)
            guard x.isFinite, y.isFinite else { return proposed }
            minX = min(minX, x)
            maxX = max(maxX, x)
            minY = min(minY, y)
            maxY = max(maxY, y)
            guard let proposed, proposed != current else { return proposed }
            guard let current, g.isVisible(index: current), g.contains(index: proposed) else {
                // Nothing on screen to protect (first pick after a cancel, or a
                // highlight that scrolled away): follow the finger.
                restart(at: x, y)
                return proposed
            }
            let column =
                Self.follows(
                    g.column(of: proposed) - g.column(of: current),
                    value: x, low: minX, high: maxX)
                ? g.column(of: proposed) : g.column(of: current)
            let row =
                Self.follows(
                    g.row(of: proposed) - g.row(of: current),
                    value: y, low: minY, high: maxY)
                ? g.row(of: proposed) : g.row(of: current)
            guard let clamped = g.clampColumn(column, inRow: row) else { return current }
            let result = row * g.columns + clamped
            if result != current { restart(at: x, y) }
            return result
        }

        private static func follows(_ delta: Int, value: Double, low: Double, high: Double) -> Bool {
            if delta == 0 { return true }
            return delta > 0 ? value - low >= Tuning.deadZone : high - value >= Tuning.deadZone
        }
    }

    /// The option the blind drag currently addresses, or nil for "no option"
    /// (stationary finger, slid out horizontally, dropped away below the
    /// opening point, or no visible cell).
    ///
    /// - Parameters:
    ///   - origin: the long-press start, in popup **content** coordinates.
    ///   - point: the current finger position, in popup **content** coordinates.
    ///   - geometry: the popup's grid.
    ///   - current: the option highlighted by the previous call, used for
    ///     hysteresis. Pass nil when nothing is highlighted yet.
    ///   - drop: screen-space downward travel since the popup opened
    ///     (`isCancelled`). Content `point.y` still only chooses the row.
    ///   - anchor: the option highlighted when the popup opened. When given,
    ///     horizontal travel steps through the columns **in order from it** (one
    ///     pitch per option) instead of from the column under the finger, so the
    ///     first move from the opening default always reaches its neighbour.
    public static func selection(
        origin: CGPoint, point: CGPoint,
        geometry g: Geometry, current: Int?,
        drop: Double = 0, anchor: Int? = nil
    ) -> Int? {
        guard g.optionCount > 0 else { return nil }
        guard Double(point.x).isFinite, Double(point.y).isFinite else { return current }

        // 1. Slide-out cancel: a deliberate horizontal overshoot, or a
        //    deliberate drop away from the popup (the one an edge key can
        //    reach). Upward travel and small drift are tolerated (blind drag).
        //    Measured on the real finger position.
        if isCancelled(point: point, geometry: g, drop: drop) { return nil }

        // Anchored mapping: shift the horizontal frame so the origin sits on the
        // anchor's centre; every later step then works relative to it.
        let shift =
            anchor.flatMap {
                g.contains(index: $0)
                    ? g.centerX(ofColumn: g.column(of: $0)) - Double(origin.x) : nil
            } ?? 0
        let origin = CGPoint(x: Double(origin.x) + shift, y: Double(origin.y))
        let x = Double(point.x) + shift
        let y = Double(point.y)
        let dx = x - Double(origin.x)
        let dy = y - Double(origin.y)

        // The fully-visible cells are the only cells the picker may address.
        guard g.visibleRowRange != nil else { return nil }

        // 2. Per-axis dead zone: each axis only contributes once the finger has
        //    left the origin by the dead zone on that axis. A stationary finger
        //    cannot choose a *different* option. A menu that already has a
        //    highlighted default must retain it even when the finger rests
        //    below the popup and the scroll timer checks the same point again.
        let horizontalActive = abs(dx) >= Tuning.deadZone
        let verticalActive = abs(dy) >= Tuning.deadZone
        if !horizontalActive, !verticalActive { return current }

        // 3. Hysteresis: keep the current option until the finger leaves its
        //    cell by a margin, so jitter on a boundary cannot flicker. An option
        //    that is no longer visible does not stick.
        if let current, g.isVisible(index: current) {
            let centreX = g.centerX(ofColumn: g.column(of: current))
            let centreY = g.centerY(ofRow: g.row(of: current))
            if abs(x - centreX) < g.pitchX / 2 + Tuning.hysteresis,
                abs(y - centreY) < g.pitchY / 2 + Tuning.hysteresis
            {
                return current
            }
        }

        // 4. A horizontal-only drag keeps the highlighted row. The finger's
        // opening position is normally below the popup; using that y would
        // clamp into the last (possibly partial) row before MotionGuard runs,
        // making earlier-row columns unreachable. Explicit vertical travel
        // still addresses rows by their real position.
        let retainedRow = [current, anchor].compactMap { $0 }
            .first(where: { g.isVisible(index: $0) }).map { g.row(of: $0) }
        guard
            let row = verticalActive
                ? g.nearestVisibleRow(to: y)
                : (retainedRow ?? g.nearestVisibleRow(to: Double(origin.y)))
        else { return nil }

        // 5. Column.
        //    - a single-column list has no column axis; the row is the choice;
        //    - a real horizontal move maps one pitch per column from the origin's
        //      continuous column (symmetric for even/odd option counts), with a
        //      boundary-local hysteresis;
        //    - without horizontal movement the column may **never** be chosen by
        //      vertical drift: keep the already-chosen column, or on the first
        //      choice take the origin's deterministic column (ties toward the
        //      leading edge, so an even-column boundary never biases right). A
        //      single-row popup has no row information either, so a vertical-only
        //      first move selects nothing.
        var column: Int
        if g.columns == 1 {
            column = 0
        } else if horizontalActive {
            let pitch = max(g.pitchX, 1)
            let base = g.continuousColumn(of: Double(origin.x))
            let continuous = base + dx / pitch
            var mapped = Int(continuous.rounded())
            if let current, g.isVisible(index: current), g.row(of: current) == row,
                g.column(of: current) != mapped
            {
                let boundary = (Double(g.column(of: current)) + Double(mapped)) / 2
                if abs(continuous - boundary) < Tuning.hysteresis / pitch {
                    mapped = g.column(of: current)
                }
            }
            column = mapped
        } else if let current, g.isVisible(index: current) {
            column = g.column(of: current)
        } else if g.rows == 1 {
            return nil
        } else {
            column = g.originColumn(to: Double(origin.x))
        }

        // 6. Invisible cells are not selectable: clamp into the cells of this row
        //    that are real **and** fully visible (an empty trailing position in a
        //    partial last row, or an edge column clipped by the viewport, is not
        //    an option).
        guard let clamped = g.clampColumn(column, inRow: row) else { return nil }
        return min(row * g.columns + clamped, g.optionCount - 1)
    }
}
