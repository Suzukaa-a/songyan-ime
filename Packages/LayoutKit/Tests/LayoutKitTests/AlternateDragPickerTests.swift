import CoreGraphics
import XCTest

@testable import LayoutKit

/// Blind alternate picking: the long-press popup must be usable by dragging
/// sideways from the key, without landing on a cell, without flicker, and
/// without losing the ability to cancel by sliding out.
final class AlternateDragPickerTests: XCTestCase {

    /// A five-option single-row popup (letter accents / punctuation), centred so
    /// the long-press origin sits exactly on the middle column.
    var singleRow: AlternateDragPicker.Geometry {
        AlternateDragPicker.Geometry(
            optionCount: 5, columns: 5,
            cellWidth: 48, cellHeight: 46, spacing: 4, rowSpacing: 0)
    }

    /// The origin of a real long press: the finger is on the key, i.e. below the
    /// popup, horizontally centred on it.
    func origin(below g: AlternateDragPicker.Geometry) -> CGPoint {
        CGPoint(x: g.contentWidth / 2, y: g.contentHeight + 60)
    }

    func point(_ g: AlternateDragPicker.Geometry, dx: Double, y: Double? = nil) -> CGPoint {
        let o = origin(below: g)
        return CGPoint(x: o.x + dx, y: y ?? o.y)
    }

    /// The blind mapping never manufactures a choice from a stationary finger.
    /// The ordinary popup's visible default is seeded by the caller
    /// (`defaultSelection`), and a stationary finger then keeps it
    /// (`testStationaryHoldKeepsAndCommitsTheOpeningDefault`).
    func testStationaryFingerAddsNoChoiceOfItsOwn() {
        let g = singleRow
        XCTAssertNil(
            AlternateDragPicker.selection(
                origin: origin(below: g), point: origin(below: g),
                geometry: g, current: nil),
            "the mapping itself must not pick an option for an unmoved finger")
    }

    func testStationaryFingerBelowMenuKeepsPreselectedKeyboardAcrossRefreshes() {
        let g = AlternateDragPicker.Geometry(
            optionCount: 5, columns: 1,
            cellWidth: 150, cellHeight: 44, spacing: 4, rowSpacing: 0)
        let heldPoint = origin(below: g)
        // The real menu's scroll timer recomputes the highlight every 60ms. Before
        // this regression fix a non-nil default bypassed the dead zone, and the
        // finger below the popup selected the last row (More Tools) without moving.
        var current: Int? = 0
        for _ in 0..<5 {
            current = AlternateDragPicker.selection(
                origin: heldPoint, point: heldPoint,
                geometry: g, current: current)
            XCTAssertEqual(current, 0)
        }
        XCTAssertEqual(
            AlternateDragPicker.selection(
                origin: heldPoint,
                point: CGPoint(x: heldPoint.x, y: heldPoint.y - 120),
                geometry: g, current: current), 3,
            "an actual drag must still choose another visible row")
    }

    func testDeadZoneSwallowsJitterButNotIntent() {
        let g = singleRow
        XCTAssertNil(
            AlternateDragPicker.selection(
                origin: origin(below: g), point: point(g, dx: 4),
                geometry: g, current: nil))
        XCTAssertNil(
            AlternateDragPicker.selection(
                origin: origin(below: g), point: point(g, dx: 8, y: g.contentHeight + 68),
                geometry: g, current: nil),
            "11.3pt of travel is still inside the dead zone")
        XCTAssertEqual(
            AlternateDragPicker.selection(
                origin: origin(below: g), point: point(g, dx: 12),
                geometry: g, current: nil),
            2, "12pt of travel is an intentional move and keeps the origin's column")
    }

    func testEdgeMultiRowHorizontalDragReachesEveryFirstRowOption() {
        let g = AlternateDragPicker.Geometry(
            optionCount: 9, columns: 8,
            cellWidth: 44, cellHeight: 46,
            spacing: 4, rowSpacing: 0)
        for mirrored in [false, true] {
            let anchor = mirrored ? 7 : 0
            let o = CGPoint(x: g.centerX(ofColumn: anchor), y: g.contentHeight + 25)
            var current: Int? = anchor
            var motion = AlternateDragPicker.MotionGuard(origin: o)
            // Real touches arrive incrementally; exercise the same selection +
            // direction guard pipeline as KeyButton, including a partial last row.
            for step in 1...168 {
                let p = CGPoint(x: o.x + Double(mirrored ? -step : step) * 2, y: o.y)
                let proposed = AlternateDragPicker.selection(
                    origin: o, point: p,
                    geometry: g, current: current, anchor: anchor)
                current = motion.resolve(
                    proposed: proposed, current: current,
                    point: p, geometry: g)
                if step % 24 == 0 {
                    XCTAssertEqual(current, mirrored ? 7 - step / 24 : step / 24)
                }
            }
            let lastRow = CGPoint(x: o.x, y: o.y + 20)
            let proposed = AlternateDragPicker.selection(
                origin: o, point: lastRow,
                geometry: g, current: current, drop: 20, anchor: anchor)
            current = motion.resolve(
                proposed: proposed, current: current,
                point: lastRow, geometry: g)
            XCTAssertEqual(current, 8, "explicit vertical travel reaches the partial row")
            XCTAssertEqual(
                AlternateDragPicker.releaseResolution(
                    highlighted: current,
                    point: lastRow, geometry: g, drop: 20), .alternate(8))
            XCTAssertEqual(
                AlternateDragPicker.releaseResolution(
                    highlighted: current,
                    point: lastRow, geometry: g, drop: 72), .none)
        }
    }

    func testHorizontalDistanceMapsOneColumnPerPitch() {
        let g = singleRow  // pitch 52, origin on column 2 (its centre)
        let o = origin(below: g)
        XCTAssertEqual(
            AlternateDragPicker.selection(
                origin: o, point: point(g, dx: 52),
                geometry: g, current: nil), 3)
        XCTAssertEqual(
            AlternateDragPicker.selection(
                origin: o, point: point(g, dx: -52),
                geometry: g, current: nil), 1)
        XCTAssertEqual(
            AlternateDragPicker.selection(
                origin: o, point: point(g, dx: 104),
                geometry: g, current: nil), 4)
    }

    func testBeyondTheBandClampsInsteadOfLosingTheOption() {
        let g = singleRow
        let o = origin(below: g)
        XCTAssertEqual(
            AlternateDragPicker.selection(
                origin: o, point: point(g, dx: 120),
                geometry: g, current: nil), 4,
            "half a band past the last column still resolves to the last option")
        XCTAssertEqual(
            AlternateDragPicker.selection(
                origin: o, point: point(g, dx: -120),
                geometry: g, current: nil), 0)
    }

    /// Content-space `y` only ever chooses the row; the drop-away cancel is a
    /// separate, screen-space input (`drop`), so these content points far from
    /// the band keep selecting as long as the finger has not dropped on screen.
    func testVerticalTravelOutsideThePopupKeepsSelecting() {
        let g = singleRow  // rows == 1: vertical position is irrelevant
        let o = origin(below: g)
        XCTAssertEqual(
            AlternateDragPicker.selection(
                origin: o,
                point: CGPoint(x: o.x + 52, y: -400),
                geometry: g, current: nil, drop: -460), 3)
        XCTAssertEqual(
            AlternateDragPicker.selection(
                origin: o,
                point: CGPoint(x: o.x + 52, y: g.contentHeight + 300),
                geometry: g, current: nil), 3)
        XCTAssertEqual(
            AlternateDragPicker.selection(
                origin: o,
                point: CGPoint(x: o.x + 52, y: o.y + 30),
                geometry: g, current: nil, drop: 30), 3,
            "ordinary downward drift below the drop threshold is tolerated")
    }

    func testVerticalTravelInsideAMultiRowPopupChangesRowWhenClamped() {
        let g = AlternateDragPicker.Geometry(
            optionCount: 10, columns: 5,
            cellWidth: 48, cellHeight: 46, spacing: 4, rowSpacing: 0)
        let o = origin(below: g)
        // Far below the popup clamps to the last row; far above clamps to the first.
        XCTAssertEqual(
            AlternateDragPicker.selection(
                origin: o, point: CGPoint(x: o.x, y: 4000),
                geometry: g, current: nil), 5 + 2)
        XCTAssertEqual(
            AlternateDragPicker.selection(
                origin: o, point: CGPoint(x: o.x, y: -4000),
                geometry: g, current: nil), 2)
    }

    func testHysteresisStopsBoundaryFlicker() {
        let g = singleRow  // column 3 centre x == 180, boundary with column 2 == 154
        let o = origin(below: g)
        let selected = AlternateDragPicker.selection(
            origin: o, point: point(g, dx: 52),
            geometry: g, current: nil)
        XCTAssertEqual(selected, 3)
        XCTAssertEqual(
            AlternateDragPicker.selection(
                origin: o, point: CGPoint(x: 150, y: o.y),
                geometry: g, current: selected),
            3, "8pt past the boundary is not enough to leave the highlighted cell")
        XCTAssertEqual(
            AlternateDragPicker.selection(
                origin: o, point: CGPoint(x: 146, y: o.y),
                geometry: g, current: selected),
            3, "the sticky rect keeps the option until the finger clears it")
        XCTAssertEqual(
            AlternateDragPicker.selection(
                origin: o, point: CGPoint(x: 145, y: o.y),
                geometry: g, current: selected),
            2, "clearing the sticky rect switches once, without flicker")
    }

    func testSmallJitterAroundTheSameCellKeepsOneOption() {
        let g = singleRow
        let o = origin(below: g)
        var current: Int? = AlternateDragPicker.selection(
            origin: o, point: point(g, dx: 52),
            geometry: g, current: nil)
        XCTAssertEqual(current, 3)
        for jitter in [50.0, 53.0, 51.0, 54.0, 49.0, 52.0] {
            current = AlternateDragPicker.selection(
                origin: o, point: point(g, dx: jitter),
                geometry: g, current: current)
            XCTAssertEqual(current, 3, "dx \(jitter) must not change the option")
        }
    }

    func testHorizontalOvershootCancels() {
        let g = singleRow
        let o = origin(below: g)
        let inside = g.contentWidth + AlternateDragPicker.Tuning.cancelMargin - 1
        XCTAssertNotNil(
            AlternateDragPicker.selection(
                origin: o, point: CGPoint(x: inside, y: o.y),
                geometry: g, current: nil),
            "sliding to the last option and a little beyond still commits it")
        XCTAssertNil(
            AlternateDragPicker.selection(
                origin: o,
                point: CGPoint(x: g.contentWidth + AlternateDragPicker.Tuning.cancelMargin + 1, y: o.y),
                geometry: g, current: 4),
            "a deliberate overshoot past the band cancels, even from a highlighted option")
        XCTAssertNil(
            AlternateDragPicker.selection(
                origin: o,
                point: CGPoint(x: -AlternateDragPicker.Tuning.cancelMargin - 1, y: o.y),
                geometry: g, current: 0))
    }

    func testPartialLastRowNeverAddressesAPastTheEndOption() {
        let g = AlternateDragPicker.Geometry(
            optionCount: 7, columns: 3,
            cellWidth: 44, cellHeight: 46, spacing: 4, rowSpacing: 0)
        let o = origin(below: g)
        let lastInBand = g.contentWidth + AlternateDragPicker.Tuning.cancelMargin - 1
        XCTAssertEqual(
            AlternateDragPicker.selection(
                origin: o, point: CGPoint(x: lastInBand, y: 4000),
                geometry: g, current: nil), 6)
        XCTAssertTrue(g.contains(index: 6))
        XCTAssertFalse(g.contains(index: 7))
    }

    func testExplicitSelectionGateIsUnaffectedByBlindMapping() {
        let g = AlternateDragPicker.Geometry(
            optionCount: 16, columns: 8,
            cellWidth: 44, cellHeight: 46, spacing: 4, rowSpacing: 0)
        let start = origin(below: g)
        var explicit = ExplicitAlternateSelection()
        explicit.begin(x: Double(start.x), y: Double(start.y), overlappingItem: nil)

        // Blind move below the threshold: the picker stays nil, so nothing to gate.
        let jitter = CGPoint(x: start.x + 6, y: start.y)
        let mappedJitter = AlternateDragPicker.selection(origin: start, point: jitter, geometry: g, current: nil)
        XCTAssertNil(mappedJitter)
        XCTAssertNil(explicit.selection(x: Double(jitter.x), y: Double(jitter.y), hitItem: mappedJitter))

        // A real blind drag maps to an option and the explicit gate lets it through.
        let moved = CGPoint(x: start.x + 52, y: start.y)
        let mapped = AlternateDragPicker.selection(origin: start, point: moved, geometry: g, current: nil)
        XCTAssertNotNil(mapped)
        XCTAssertEqual(explicit.selection(x: Double(moved.x), y: Double(moved.y), hitItem: mapped), mapped)
    }

    func testPopupAppearingUnderTheFingerStillRequiresExplicitDeparture() {
        // Layout popups can open over the finger; the preference-writing gate must
        // still refuse a selection made from a stationary finger, and refuse a
        // move that only jitters inside the cell the finger already covers.
        let g = AlternateDragPicker.Geometry(
            optionCount: 4, columns: 1,
            cellWidth: 150, cellHeight: 48, spacing: 4, rowSpacing: 0)
        let start = CGPoint(x: g.contentWidth / 2, y: g.centerY(ofRow: 2))
        var explicit = ExplicitAlternateSelection()
        explicit.begin(x: Double(start.x), y: Double(start.y), overlappingItem: 2)

        let mappedAtRest = AlternateDragPicker.selection(origin: start, point: start, geometry: g, current: nil)
        XCTAssertNil(mappedAtRest, "still inside the dead zone")
        XCTAssertNil(explicit.selection(x: Double(start.x), y: Double(start.y), hitItem: mappedAtRest))

        let jitter = CGPoint(x: start.x + 4, y: start.y + 4)
        let mappedJitter = AlternateDragPicker.selection(origin: start, point: jitter, geometry: g, current: nil)
        XCTAssertNil(mappedJitter)
        XCTAssertNil(explicit.selection(x: Double(jitter.x), y: Double(jitter.y), hitItem: mappedJitter))

        let sameCell = CGPoint(x: start.x, y: start.y - 18)
        let mappedSameCell = AlternateDragPicker.selection(origin: start, point: sameCell, geometry: g, current: nil)
        XCTAssertEqual(mappedSameCell, 2, "the row is addressed by vertical position in a single-column list")
        XCTAssertNil(
            explicit.selection(x: Double(sameCell.x), y: Double(sameCell.y), hitItem: mappedSameCell),
            "movement inside the initially covered cell is not entering a choice")

        let moved = CGPoint(x: start.x, y: start.y - 40)
        let afterMove = AlternateDragPicker.selection(origin: start, point: moved, geometry: g, current: nil)
        XCTAssertEqual(afterMove, 1)
        XCTAssertEqual(explicit.selection(x: Double(moved.x), y: Double(moved.y), hitItem: afterMove), 1)
    }

    func testDegenerateGeometryIsSafe() {
        let empty = AlternateDragPicker.Geometry(
            optionCount: 0, columns: 0,
            cellWidth: 0, cellHeight: 0, spacing: 0, rowSpacing: 0)
        XCTAssertNil(AlternateDragPicker.selection(origin: .zero, point: .zero, geometry: empty, current: nil))
        XCTAssertEqual(empty.columns, 1)
        // A zero-size cell has no area, so it is not "fully visible" and cannot be
        // selected: degenerate geometry fails closed instead of inventing an option.
        let zeroPitch = AlternateDragPicker.Geometry(
            optionCount: 3, columns: 3,
            cellWidth: 0, cellHeight: 0, spacing: 0, rowSpacing: 0)
        XCTAssertFalse(zeroPitch.isVisible(index: 0))
        XCTAssertNil(
            AlternateDragPicker.selection(
                origin: .zero, point: CGPoint(x: 20, y: 0),
                geometry: zeroPitch, current: nil))
    }

    // MARK: Viewport: only fully-visible cells are selectable

    /// The real defect: the popup is clamped by the safe bounds and its edge
    /// columns are clipped, but their content coordinates still exist. A clipped
    /// column must not be selectable.
    func testLeftClippedColumnIsNotSelectable() {
        let g = AlternateDragPicker.Geometry(
            optionCount: 5, columns: 5,
            cellWidth: 48, cellHeight: 46, spacing: 4, rowSpacing: 0,
            viewport: CGRect(x: 52, y: 0, width: 204, height: 46))
        XCTAssertFalse(g.isVisible(index: 0), "column 0 is cut by the left edge")
        XCTAssertTrue(g.isVisible(index: 1))
        XCTAssertEqual(g.visibleColumns(inRow: 0), 1...4)
        XCTAssertEqual(g.visibleRowRange, 0...0)
        // A far-left drag clamps into the visible columns, never the clipped one.
        XCTAssertEqual(
            AlternateDragPicker.selection(
                origin: origin(below: g),
                point: CGPoint(x: 0, y: origin(below: g).y),
                geometry: g, current: nil), 1)
    }

    func testRightClippedColumnIsNotSelectable() {
        let g = AlternateDragPicker.Geometry(
            optionCount: 5, columns: 5,
            cellWidth: 48, cellHeight: 46, spacing: 4, rowSpacing: 0,
            viewport: CGRect(x: 0, y: 0, width: 208, height: 46))
        XCTAssertFalse(g.isVisible(index: 4), "column 4 is cut by the right edge")
        XCTAssertEqual(g.visibleColumns(inRow: 0), 0...3)
        let o = origin(below: g)
        XCTAssertEqual(
            AlternateDragPicker.selection(
                origin: o, point: CGPoint(x: o.x + 155, y: o.y),
                geometry: g, current: nil), 3)
    }

    func testPartiallyClippedCellIsNotSelectable() {
        // One point of the left column is outside the viewport.
        let g = AlternateDragPicker.Geometry(
            optionCount: 5, columns: 5,
            cellWidth: 48, cellHeight: 46, spacing: 4, rowSpacing: 0,
            viewport: CGRect(x: 1, y: 0, width: 255, height: 46))
        XCTAssertFalse(g.isVisible(index: 0), "a cell clipped by 1pt is not fully visible")
        XCTAssertTrue(g.isVisible(index: 4))
    }

    func testVerticallyClippedRowIsNotSelectable() {
        let g = AlternateDragPicker.Geometry(
            optionCount: 5, columns: 5,
            cellWidth: 48, cellHeight: 46, spacing: 4, rowSpacing: 0,
            viewport: CGRect(x: 0, y: 0, width: 256, height: 45))
        XCTAssertNil(g.visibleRowRange)
        XCTAssertFalse(g.isVisible(index: 2))
        XCTAssertNil(
            AlternateDragPicker.selection(
                origin: origin(below: g), point: point(g, dx: 52),
                geometry: g, current: nil))
    }

    /// The panel builds the popup width as `columns * cellWidth + gaps` while a
    /// cell's edge is `column * pitch + cellWidth`; for a fractional measured
    /// cell width the two can disagree by one ulp. That round-off must not make
    /// the last column "clipped" (never selectable, never committed), while a
    /// real sub-pixel clip still is.
    func testLastColumnSurvivesFloatRoundOffButNotARealClip() {
        let width = 63.37  // (2 * 67.37 + 63.37) > (3 * 63.37 + 2 * 4) by one ulp
        let panelWidth = CGFloat(3) * CGFloat(width) + CGFloat(2) * 4
        for viewport in [nil, CGRect(x: 0, y: 0, width: panelWidth, height: 46)] as [CGRect?] {
            let g = AlternateDragPicker.Geometry(
                optionCount: 3, columns: 3,
                cellWidth: width, cellHeight: 46, spacing: 4,
                rowSpacing: 0, viewport: viewport)
            XCTAssertTrue(g.isVisible(index: 2), "round-off must not clip the last column")
            XCTAssertEqual(g.visibleColumns(inRow: 0), 0...2)
            let o = origin(below: g)
            XCTAssertEqual(
                AlternateDragPicker.selection(
                    origin: o, point: CGPoint(x: o.x + 70, y: o.y),
                    geometry: g, current: nil), 2)
            XCTAssertEqual(
                AlternateDragPicker.releaseResolution(
                    highlighted: 2,
                    point: CGPoint(x: o.x + 70, y: o.y),
                    geometry: g), .alternate(2))
        }
        let clipped = AlternateDragPicker.Geometry(
            optionCount: 3, columns: 3,
            cellWidth: width, cellHeight: 46, spacing: 4,
            rowSpacing: 0,
            viewport: CGRect(
                x: 0, y: 0,
                width: panelWidth - 0.01, height: 46))
        XCTAssertFalse(clipped.isVisible(index: 2), "a real 0.01pt clip is still a clip")
    }

    /// A scroll view's bounds *are* the viewport in content coordinates: after
    /// the popup auto-scrolls one row, the row above is out of view and a
    /// blind drag above the popup lands on the first row actually shown.
    func testScrolledViewportAddressesOnlyTheRowsOnScreen() {
        let g = AlternateDragPicker.Geometry(
            optionCount: 21, columns: 7,
            cellWidth: 44, cellHeight: 46, spacing: 4, rowSpacing: 0,
            viewport: CGRect(x: 0, y: 46, width: 332, height: 92))
        XCTAssertEqual(g.visibleRowRange, 1...2)
        let o = origin(below: g)
        XCTAssertEqual(
            AlternateDragPicker.selection(
                origin: o, point: CGPoint(x: o.x, y: -400),
                geometry: g, current: nil), 10,
            "row 0 is scrolled out; the nearest visible row is row 1")
        XCTAssertEqual(
            AlternateDragPicker.releaseResolution(highlighted: 3, point: o, geometry: g),
            .none, "a scrolled-out highlight never commits, and nothing else is typed instead")
        XCTAssertEqual(
            AlternateDragPicker.releaseResolution(highlighted: 10, point: o, geometry: g),
            .alternate(10))
        XCTAssertEqual(
            AlternateDragPicker.defaultSelection(geometry: g), 7,
            "the opening default is the first option actually on screen")
    }

    func testEmptyViewportResolvesNothing() {
        let g = AlternateDragPicker.Geometry(
            optionCount: 5, columns: 5,
            cellWidth: 48, cellHeight: 46, spacing: 4, rowSpacing: 0,
            viewport: .zero)
        XCTAssertNil(
            AlternateDragPicker.selection(
                origin: origin(below: g), point: point(g, dx: 52),
                geometry: g, current: nil))
    }

    func testVisibleRowsAndViewportIntersect() {
        let g = AlternateDragPicker.Geometry(
            optionCount: 10, columns: 5,
            cellWidth: 48, cellHeight: 46, spacing: 4, rowSpacing: 0,
            visibleRows: 0..<2,
            viewport: CGRect(x: 0, y: 46, width: 256, height: 46))
        // Rows 0..<2 ∩ y 46...92 leaves only row 1, and only its fully-visible cells.
        XCTAssertEqual(g.visibleRowRange, 1...1)
        XCTAssertNil(g.visibleColumns(inRow: 0))
        XCTAssertEqual(g.visibleColumns(inRow: 1), 0...4)
    }

    func testViewportClippedMatrixStillLetsTheFullCellsBePicked() {
        let g = AlternateDragPicker.Geometry(
            optionCount: 10, columns: 5,
            cellWidth: 48, cellHeight: 46, spacing: 4, rowSpacing: 0,
            viewport: CGRect(x: 0, y: 46, width: 256, height: 46))
        let o = origin(below: g)
        // Vertical position selects the only visible row (row 1); horizontal picks
        // the column inside it.
        XCTAssertEqual(
            AlternateDragPicker.selection(
                origin: o, point: CGPoint(x: o.x, y: -4000),
                geometry: g, current: nil), 7)
        XCTAssertEqual(
            AlternateDragPicker.selection(
                origin: o, point: CGPoint(x: o.x + 155, y: -4000),
                geometry: g, current: nil), 9)
    }

    func testRowPitchMirrorsThePackedPopupRows() {
        // The popup places rows edge to edge and columns 4pt apart; the picker's
        // vertical pitch must match or the row mapping would drift.
        let g = AlternateDragPicker.Geometry(
            optionCount: 10, columns: 5,
            cellWidth: 48, cellHeight: 46, spacing: 4, rowSpacing: 0)
        XCTAssertEqual(g.pitchX, 52, accuracy: 0.0001)
        XCTAssertEqual(g.pitchY, 46, accuracy: 0.0001)
        XCTAssertEqual(g.contentHeight, 2 * 46, accuracy: 0.0001)
    }

    // MARK: Per-axis dead zone

    func testDiagonalJitterInsideTheDeadZoneOnBothAxesIsNotAMove() {
        let g = singleRow
        let o = origin(below: g)
        // 9pt on each axis is 12.7pt of Euclidean travel — outside the old radial
        // dead zone — but neither axis has moved by the per-axis threshold.
        XCTAssertNil(
            AlternateDragPicker.selection(
                origin: o,
                point: CGPoint(x: o.x + 9, y: o.y - 9),
                geometry: g, current: nil))
        XCTAssertNil(
            AlternateDragPicker.selection(
                origin: o,
                point: CGPoint(x: o.x - 11, y: o.y + 11),
                geometry: g, current: nil))
    }

    func testOneAxisLeavingTheDeadZoneIsAMove() {
        let g = singleRow
        let o = origin(below: g)
        XCTAssertEqual(
            AlternateDragPicker.selection(
                origin: o,
                point: CGPoint(x: o.x + 12, y: o.y - 4),
                geometry: g, current: nil), 2)
    }

    // MARK: 2- and 3-option symmetry

    var twoOptions: AlternateDragPicker.Geometry {
        AlternateDragPicker.Geometry(
            optionCount: 2, columns: 2,
            cellWidth: 48, cellHeight: 46, spacing: 4, rowSpacing: 0)
    }

    var threeOptions: AlternateDragPicker.Geometry {
        AlternateDragPicker.Geometry(
            optionCount: 3, columns: 3,
            cellWidth: 48, cellHeight: 46, spacing: 4, rowSpacing: 0)
    }

    func testTwoOptionsResolveSymmetricallyAboutTheFinger() {
        let g = twoOptions
        let o = origin(below: g)
        // The origin sits exactly between the two cells: the same travel either
        // way must select the corresponding option.
        XCTAssertEqual(
            AlternateDragPicker.selection(
                origin: o, point: CGPoint(x: o.x + 12, y: o.y),
                geometry: g, current: nil), 1)
        XCTAssertEqual(
            AlternateDragPicker.selection(
                origin: o, point: CGPoint(x: o.x - 12, y: o.y),
                geometry: g, current: nil), 0)
        XCTAssertEqual(
            AlternateDragPicker.selection(
                origin: o, point: CGPoint(x: o.x + 40, y: o.y),
                geometry: g, current: nil), 1)
        XCTAssertEqual(
            AlternateDragPicker.selection(
                origin: o, point: CGPoint(x: o.x - 40, y: o.y),
                geometry: g, current: nil), 0)
    }

    func testTwoOptionsNeedAnExplicitMove() {
        let g = twoOptions
        let o = origin(below: g)
        XCTAssertNil(
            AlternateDragPicker.selection(
                origin: o, point: CGPoint(x: o.x + 11, y: o.y),
                geometry: g, current: nil))
        XCTAssertNil(
            AlternateDragPicker.selection(
                origin: o, point: CGPoint(x: o.x - 11, y: o.y),
                geometry: g, current: nil))
    }

    /// The regression this pins: a pure vertical move used to round the origin's
    /// 0.5 continuous column up, so a 13pt vertical drift silently selected the
    /// right-hand option. A single-row popup has no row information, so a
    /// vertical-only move must select nothing at all.
    func testSingleRowTwoOptionsIgnoresPureVerticalTravel() {
        let g = twoOptions
        let o = origin(below: g)
        XCTAssertNil(
            AlternateDragPicker.selection(
                origin: o, point: CGPoint(x: o.x, y: o.y + 13),
                geometry: g, current: nil),
            "13pt down is not a horizontal choice")
        XCTAssertNil(
            AlternateDragPicker.selection(
                origin: o, point: CGPoint(x: o.x, y: o.y - 13),
                geometry: g, current: nil))
        XCTAssertNil(
            AlternateDragPicker.selection(
                origin: o, point: CGPoint(x: o.x, y: o.y + 400),
                geometry: g, current: nil),
            "even a large vertical drift cannot decide the column")
        XCTAssertNil(
            AlternateDragPicker.selection(
                origin: o, point: CGPoint(x: o.x, y: o.y - 400),
                geometry: g, current: nil))
        XCTAssertNil(
            AlternateDragPicker.selection(
                origin: o, point: CGPoint(x: o.x + 11, y: o.y + 400),
                geometry: g, current: nil),
            "sub-threshold horizontal + large vertical is still not a column choice")
    }

    func testSingleRowVerticalTravelKeepsAnAlreadyChosenColumn() {
        let g = twoOptions
        let o = origin(below: g)
        XCTAssertEqual(
            AlternateDragPicker.selection(
                origin: o, point: CGPoint(x: o.x, y: o.y + 400),
                geometry: g, current: 1), 1)
        XCTAssertEqual(
            AlternateDragPicker.selection(
                origin: o, point: CGPoint(x: o.x, y: o.y - 400),
                geometry: g, current: 1), 1)
    }

    /// A multi-row, even-column popup: a vertical-only first move takes the
    /// origin's deterministic column with ties toward the leading edge, so an
    /// origin exactly between two columns does not bias right.
    func testMultiRowVerticalDriftUsesTheLeadingOriginColumn() {
        let g = AlternateDragPicker.Geometry(
            optionCount: 4, columns: 2,
            cellWidth: 48, cellHeight: 46, spacing: 4, rowSpacing: 0)
        // contentWidth 100, contentHeight 92; origin x 50 is exactly between the
        // two columns (continuous 0.5).
        let o = CGPoint(x: 50, y: 92 + 60)
        XCTAssertEqual(g.continuousColumn(of: 50), 0.5, accuracy: 0.0001)
        XCTAssertEqual(g.originColumn(to: 50), 0)
        XCTAssertEqual(
            AlternateDragPicker.selection(
                origin: o, point: CGPoint(x: 50, y: o.y + 60),
                geometry: g, current: nil), 2,
            "row 1, leading (left) column")
    }

    func testMultiRowVerticalDriftKeepsTheChosenColumn() {
        let g = AlternateDragPicker.Geometry(
            optionCount: 4, columns: 2,
            cellWidth: 48, cellHeight: 46, spacing: 4, rowSpacing: 0)
        let o = CGPoint(x: 50, y: 92 + 60)
        // current 1 is the right column of row 0; a vertical move changes the row
        // but not the column.
        XCTAssertEqual(
            AlternateDragPicker.selection(
                origin: o, point: CGPoint(x: 54, y: o.y + 60),
                geometry: g, current: 1), 3)
    }

    func testOriginColumnResolvesTiesTowardTheLeadingEdge() {
        let g = AlternateDragPicker.Geometry(
            optionCount: 4, columns: 2,
            cellWidth: 48, cellHeight: 46, spacing: 4, rowSpacing: 0)
        XCTAssertEqual(g.originColumn(to: 50), 0, "0.5 → leading")
        XCTAssertEqual(g.originColumn(to: 102), 1, "1.5 → leading")
        XCTAssertEqual(g.originColumn(to: 76), 1, "1.0 → that column")
        XCTAssertEqual(g.originColumn(to: 0), 0)
    }

    func testThreeOptionsKeepTheMiddleInsideTheDeadZoneAndPickSidesSymmetrically() {
        let g = threeOptions
        let o = origin(below: g)
        XCTAssertEqual(
            AlternateDragPicker.selection(
                origin: o, point: CGPoint(x: o.x + 12, y: o.y),
                geometry: g, current: nil), 1)
        XCTAssertEqual(
            AlternateDragPicker.selection(
                origin: o, point: CGPoint(x: o.x - 12, y: o.y),
                geometry: g, current: nil), 1)
        // Half a pitch clears the middle cell; both directions need the same.
        XCTAssertEqual(
            AlternateDragPicker.selection(
                origin: o, point: CGPoint(x: o.x + 27, y: o.y),
                geometry: g, current: nil), 2)
        XCTAssertEqual(
            AlternateDragPicker.selection(
                origin: o, point: CGPoint(x: o.x - 27, y: o.y),
                geometry: g, current: nil), 0)
        XCTAssertEqual(
            AlternateDragPicker.selection(
                origin: o, point: CGPoint(x: o.x + 25, y: o.y),
                geometry: g, current: nil), 1)
        XCTAssertEqual(
            AlternateDragPicker.selection(
                origin: o, point: CGPoint(x: o.x - 25, y: o.y),
                geometry: g, current: nil), 1)
    }

    // MARK: Invisible cells are never selectable

    func testScrolledOutRowIsNotSelectable() {
        let g = AlternateDragPicker.Geometry(
            optionCount: 10, columns: 5,
            cellWidth: 48, cellHeight: 46, spacing: 4, rowSpacing: 0,
            visibleRows: 0..<1)
        let o = origin(below: g)
        // Far below would map to the second row; with only row 0 visible it must
        // stay on a visible cell.
        XCTAssertEqual(
            AlternateDragPicker.selection(
                origin: o, point: CGPoint(x: o.x, y: 4000),
                geometry: g, current: nil), 2)
        XCTAssertEqual(
            AlternateDragPicker.selection(
                origin: o, point: CGPoint(x: o.x, y: -4000),
                geometry: g, current: nil), 2)
        XCTAssertFalse(g.isVisible(index: 7))
        XCTAssertTrue(g.isVisible(index: 2))
    }

    func testStaleHighlightInAHiddenRowDoesNotStick() {
        let g = AlternateDragPicker.Geometry(
            optionCount: 10, columns: 5,
            cellWidth: 48, cellHeight: 46, spacing: 4, rowSpacing: 0,
            visibleRows: 0..<1)
        let o = origin(below: g)
        XCTAssertEqual(
            AlternateDragPicker.selection(
                origin: o, point: CGPoint(x: o.x, y: 4000),
                geometry: g, current: 7), 2)
    }

    func testEmptyVisibleRangeResolvesNothing() {
        let g = AlternateDragPicker.Geometry(
            optionCount: 5, columns: 5,
            cellWidth: 48, cellHeight: 46, spacing: 4, rowSpacing: 0,
            visibleRows: 2..<2)
        XCTAssertNil(
            AlternateDragPicker.selection(
                origin: origin(below: g),
                point: point(g, dx: 52),
                geometry: g, current: nil))
    }

    func testTrailingEmptyCellOfAPartialLastRowIsNotSelectable() {
        let g = AlternateDragPicker.Geometry(
            optionCount: 7, columns: 3,
            cellWidth: 44, cellHeight: 46, spacing: 4, rowSpacing: 0)
        let o = origin(below: g)
        let lastInBand = g.contentWidth + AlternateDragPicker.Tuning.cancelMargin - 1
        // The last row has a single real cell (index 6, column 0); dragging to the
        // right edge of that row must not invent columns 1/2.
        XCTAssertEqual(g.optionCount(inRow: 2), 1)
        XCTAssertEqual(g.clampColumn(2, inRow: 2), 0)
        XCTAssertEqual(
            AlternateDragPicker.selection(
                origin: o, point: CGPoint(x: lastInBand, y: 4000),
                geometry: g, current: nil), 6)
    }
}
