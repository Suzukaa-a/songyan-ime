import CoreGraphics
import XCTest

@testable import LayoutKit

extension AlternateDragPickerTests {
    // MARK: Edges, cancel and fast swipes

    func testCancelIsAnExclusiveEdge() {
        let g = singleRow
        let o = origin(below: g)
        let justInside = g.contentWidth + AlternateDragPicker.Tuning.cancelMargin
        XCTAssertFalse(AlternateDragPicker.isCancelled(point: CGPoint(x: justInside, y: o.y), geometry: g))
        XCTAssertTrue(AlternateDragPicker.isCancelled(point: CGPoint(x: justInside + 1, y: o.y), geometry: g))
        XCTAssertTrue(
            AlternateDragPicker.isCancelled(
                point: CGPoint(x: -AlternateDragPicker.Tuning.cancelMargin - 1, y: o.y), geometry: g))
        XCTAssertFalse(
            AlternateDragPicker.isCancelled(
                point: CGPoint(x: -AlternateDragPicker.Tuning.cancelMargin, y: o.y), geometry: g))
    }

    func testDropCancelIsAnInclusiveThresholdOnDownwardTravelOnly() {
        let g = singleRow
        let o = origin(below: g)
        let drop = AlternateDragPicker.Tuning.cancelDrop
        XCTAssertFalse(AlternateDragPicker.isCancelled(point: o, geometry: g, drop: drop - 0.5))
        XCTAssertTrue(AlternateDragPicker.isCancelled(point: o, geometry: g, drop: drop))
        XCTAssertFalse(
            AlternateDragPicker.isCancelled(point: o, geometry: g, drop: -4000),
            "upward overshoot toward and through the popup never cancels")
        XCTAssertFalse(AlternateDragPicker.isCancelled(point: o, geometry: g, drop: .nan))
        XCTAssertFalse(
            AlternateDragPicker.isCancelled(point: o, geometry: g),
            "the default drop is 0: callers that do not measure it keep the old contract")
        XCTAssertGreaterThan(
            drop, AlternateDragPicker.Tuning.deadZone + AlternateDragPicker.Tuning.hysteresis,
            "the drop is well past jitter and boundary drift")
        XCTAssertLessThan(drop, 54 * 2, "reachable within two key rows (or the system band) below the held key")
    }

    /// A deliberate pull down, away from the popup, cancels even from the
    /// opening default and even though the finger is still inside the band.
    func testDropAwayFromThePopupCancelsTheOpeningDefault() {
        let g = singleRow
        let o = origin(below: g)
        let drop = AlternateDragPicker.Tuning.cancelDrop
        var guardrail = AlternateDragPicker.MotionGuard(origin: o)
        var current = AlternateDragPicker.defaultSelection(geometry: g)
        var trace: [Int?] = []
        for dy in [6.0, 20, 36, drop] {
            let p = CGPoint(x: o.x, y: o.y + dy)
            let proposed = AlternateDragPicker.selection(
                origin: o, point: p, geometry: g,
                current: current, drop: dy)
            current = guardrail.resolve(proposed: proposed, current: current, point: p, geometry: g)
            trace.append(current)
        }
        XCTAssertEqual(trace, [0, 0, 0, nil], "drift keeps the default, the drop clears it")
        XCTAssertEqual(
            AlternateDragPicker.releaseResolution(
                highlighted: 0, point: CGPoint(x: o.x, y: o.y + drop),
                geometry: g, drop: drop),
            .none, "a dropped release commits nothing, even with a stale highlight")
        // Coming back up without moving on purpose shows nothing; the
        // picker only follows the finger again once it really moves.
        let back = CGPoint(x: o.x + 4, y: o.y + 4)
        XCTAssertNil(AlternateDragPicker.selection(origin: o, point: back, geometry: g, current: nil, drop: 4))
        XCTAssertEqual(
            AlternateDragPicker.selection(
                origin: o, point: CGPoint(x: o.x + 52, y: o.y),
                geometry: g, current: nil, drop: 0), 3)
    }

    /// An edge key's popup is clamped flush to the 6pt safe inset, so the
    /// outward horizontal overshoot is off screen; the drop is still reachable.
    func testEdgeKeyPopupsAlwaysHaveAReachableCancel() {
        let screenWidth = 390.0, safeInset = 6.0
        // Left edge: `q` on a 390pt screen, popup clamped to x = 6.
        let left = singleRow
        let reachableLeft = -safeInset  // the finger at the screen's own left edge
        XCTAssertFalse(
            AlternateDragPicker.isCancelled(point: CGPoint(x: reachableLeft, y: 0), geometry: left),
            "outward horizontal cancel is physically unreachable for a left-edge popup")
        // Mirror case, a right-edge key (`p`): the same popup flush against
        // screenWidth - 6, so the finger can reach at most 6pt past its band.
        let reachableRight = left.contentWidth + safeInset
        XCTAssertFalse(AlternateDragPicker.isCancelled(point: CGPoint(x: reachableRight, y: 0), geometry: left))
        // A popup as wide as the screen has no reachable horizontal cancel at all.
        let wide = AlternateDragPicker.Geometry(
            optionCount: 7, columns: 7, cellWidth: 48,
            cellHeight: 46, spacing: 4, rowSpacing: 0)
        XCTAssertLessThanOrEqual(wide.contentWidth, screenWidth - 2 * safeInset)
        for x in stride(from: -safeInset, through: screenWidth - safeInset, by: 1) {
            XCTAssertFalse(AlternateDragPicker.isCancelled(point: CGPoint(x: x, y: 0), geometry: wide))
        }
        // The drop cancels on every one of them, wherever the finger is.
        for (g, x) in [(left, 12.0), (left, reachableRight), (wide, 12.0), (wide, wide.contentWidth - 12)] {
            let o = CGPoint(x: x, y: g.contentHeight + 60)
            XCTAssertNil(
                AlternateDragPicker.selection(
                    origin: o, point: CGPoint(x: x, y: o.y + 50), geometry: g,
                    current: 0, drop: AlternateDragPicker.Tuning.cancelDrop))
            XCTAssertEqual(
                AlternateDragPicker.releaseResolution(
                    highlighted: 0, point: o, geometry: g,
                    drop: AlternateDragPicker.Tuning.cancelDrop),
                .none)
        }
    }

    /// The drop is screen-space by contract: a popup that auto-scrolled moves
    /// the finger's content `y` without the finger moving, which must neither
    /// cancel nor hide a real drop.
    func testDropIsIndependentOfThePopupScrollOffset() {
        let g = AlternateDragPicker.Geometry(
            optionCount: 15, columns: 5,
            cellWidth: 48, cellHeight: 46, spacing: 4, rowSpacing: 0)
        let o = origin(below: g)
        let scrolled = g.withViewport(CGRect(x: 0, y: 46, width: g.contentWidth, height: 92))
        // Same screen point, content y shifted by the 46pt scroll: no drop.
        let shifted = CGPoint(x: o.x + 52, y: o.y + 46)
        XCTAssertEqual(
            AlternateDragPicker.selection(
                origin: o, point: shifted, geometry: scrolled,
                current: nil, drop: 0), 10 + 3)
        XCTAssertNil(
            AlternateDragPicker.selection(
                origin: o, point: CGPoint(x: o.x + 52, y: o.y - 46),
                geometry: scrolled, current: nil,
                drop: AlternateDragPicker.Tuning.cancelDrop),
            "a real drop cancels even where scrolling left the content y above the origin")
    }

    func testFastSwipeResolvesInASingleCall() {
        let g = singleRow
        let o = origin(below: g)
        // One sample far from the origin (a flick) still lands on a definite,
        // clamped option instead of needing intermediate samples. 155pt stays
        // inside the band's cancel margin.
        XCTAssertEqual(
            AlternateDragPicker.selection(
                origin: o, point: CGPoint(x: o.x + 155, y: o.y),
                geometry: g, current: nil), 4)
        XCTAssertEqual(
            AlternateDragPicker.selection(
                origin: o, point: CGPoint(x: o.x - 155, y: o.y),
                geometry: g, current: nil), 0)
    }

    func testFastSwipeDiagonallyIntoAMultiRowGrid() {
        let g = AlternateDragPicker.Geometry(
            optionCount: 10, columns: 5,
            cellWidth: 48, cellHeight: 46, spacing: 4, rowSpacing: 0)
        let o = origin(below: g)
        XCTAssertEqual(
            AlternateDragPicker.selection(
                origin: o, point: CGPoint(x: o.x + 155, y: -400),
                geometry: g, current: nil), 4)
    }

    func testFastSwipeOutOfTheBandCancels() {
        let g = singleRow
        let o = origin(below: g)
        XCTAssertNil(
            AlternateDragPicker.selection(
                origin: o, point: CGPoint(x: o.x + 2000, y: o.y - 2000),
                geometry: g, current: 4))
    }

    // MARK: Pure release resolution

    /// An ordinary long press opens on the first alternate (the key-face hint),
    /// visibly selected; holding still — across the popup's 60ms refreshes —
    /// keeps it, and lifting without any motion commits exactly it.
    func testStationaryHoldKeepsAndCommitsTheOpeningDefault() {
        let g = singleRow
        let o = origin(below: g)  // finger on column 2, default on column 0
        let opening = AlternateDragPicker.defaultSelection(geometry: g)
        XCTAssertEqual(opening, 0)
        var guardrail = AlternateDragPicker.MotionGuard(origin: o)
        var current = opening
        for tremor in [0.0, 3, -4, 6, -11.5, 11.5, 0] {
            let p = CGPoint(x: o.x + tremor, y: o.y + tremor / 2)
            let proposed = AlternateDragPicker.selection(origin: o, point: p, geometry: g, current: current)
            current = guardrail.resolve(proposed: proposed, current: current, point: p, geometry: g)
            XCTAssertEqual(current, 0, "sub-dead-zone tremor \(tremor) keeps the default")
        }
        XCTAssertEqual(
            AlternateDragPicker.releaseResolution(highlighted: current, point: o, geometry: g),
            .alternate(0))
    }

    func testReleaseWithoutAHighlightCommitsNothing() {
        let g = singleRow
        let o = origin(below: g)
        XCTAssertEqual(
            AlternateDragPicker.releaseResolution(highlighted: nil, point: o, geometry: g),
            .none, "a popup never types the key it was opened from")
        let menu = AlternateDragPicker.Geometry(
            optionCount: 4, columns: 1,
            cellWidth: 150, cellHeight: 48, spacing: 4, rowSpacing: 0)
        XCTAssertEqual(
            AlternateDragPicker.releaseResolution(
                highlighted: nil,
                point: CGPoint(x: 75, y: menu.contentHeight + 60),
                geometry: menu),
            .none, "a preference picker with no explicit selection commits nothing")
    }

    func testHighlightedReleaseCommitsTheAlternate() {
        let g = singleRow
        XCTAssertEqual(
            AlternateDragPicker.releaseResolution(
                highlighted: 3, point: point(g, dx: 52),
                geometry: g),
            .alternate(3))
    }

    func testCancelledReleaseCommitsNothingEvenWithAStaleHighlight() {
        let g = singleRow
        let cancelled = CGPoint(x: g.contentWidth + AlternateDragPicker.Tuning.cancelMargin + 1, y: 0)
        XCTAssertEqual(
            AlternateDragPicker.releaseResolution(highlighted: 4, point: cancelled, geometry: g),
            .none)
    }

    func testHiddenHighlightDoesNotCommitAnAlternate() {
        let g = AlternateDragPicker.Geometry(
            optionCount: 10, columns: 5,
            cellWidth: 48, cellHeight: 46, spacing: 4, rowSpacing: 0,
            visibleRows: 0..<1)
        let o = origin(below: g)
        XCTAssertEqual(
            AlternateDragPicker.releaseResolution(highlighted: 7, point: o, geometry: g),
            .none)
        XCTAssertEqual(
            AlternateDragPicker.releaseResolution(highlighted: 10, point: o, geometry: g),
            .none, "an out-of-range highlight never commits")
    }

    // MARK: Opening default

    func testDefaultIsTheFirstFullyVisibleOptionInArrayOrder() {
        XCTAssertEqual(AlternateDragPicker.defaultSelection(geometry: singleRow), 0)
        let twoRows = AlternateDragPicker.Geometry(
            optionCount: 10, columns: 5,
            cellWidth: 48, cellHeight: 46, spacing: 4, rowSpacing: 0)
        XCTAssertEqual(AlternateDragPicker.defaultSelection(geometry: twoRows), 0)
        // Row 0 half scrolled out: its cells are clipped, row 1 is the first shown.
        XCTAssertEqual(
            AlternateDragPicker.defaultSelection(
                geometry: twoRows.withViewport(CGRect(x: 0, y: 23, width: 256, height: 69))), 5)
        // Column 0 clipped by the viewport: the first visible option is index 1.
        XCTAssertEqual(
            AlternateDragPicker.defaultSelection(
                geometry: singleRow.withViewport(CGRect(x: 1, y: 0, width: 255, height: 46))), 1)
        XCTAssertNil(
            AlternateDragPicker.defaultSelection(geometry: singleRow.withViewport(.zero)),
            "nothing on screen: no default, and the caller must not open a popup")
        XCTAssertNil(
            AlternateDragPicker.defaultSelection(
                geometry: .init(optionCount: 0, columns: 1, cellWidth: 44, cellHeight: 46, spacing: 4)))
    }

    func testWithViewportKeepsTheGridAndReplacesOnlyTheViewport() {
        let g = AlternateDragPicker.Geometry(
            optionCount: 7, columns: 3, cellWidth: 51.5, cellHeight: 46,
            spacing: 4, rowSpacing: 0, visibleRows: 0..<2)
        let viewport = CGRect(x: 0, y: 46, width: 162.5, height: 92)
        let moved = g.withViewport(viewport)
        XCTAssertEqual(
            moved,
            AlternateDragPicker.Geometry(
                optionCount: 7, columns: 3, cellWidth: 51.5,
                cellHeight: 46, spacing: 4, rowSpacing: 0,
                visibleRows: 0..<2, viewport: viewport))
        XCTAssertEqual(moved.withViewport(nil), g)
    }

    func testDeadZonePredicateMatchesTheMapping() {
        let o = CGPoint(x: 100, y: 200)
        XCTAssertTrue(AlternateDragPicker.isWithinDeadZone(origin: o, point: o))
        XCTAssertTrue(AlternateDragPicker.isWithinDeadZone(origin: o, point: CGPoint(x: 111.9, y: 188.1)))
        XCTAssertFalse(AlternateDragPicker.isWithinDeadZone(origin: o, point: CGPoint(x: 112, y: 200)))
        XCTAssertFalse(AlternateDragPicker.isWithinDeadZone(origin: o, point: CGPoint(x: 100, y: 188)))
    }

    // MARK: Motion guard (opening default not under the finger)

    /// Feeds a finger path through `selection` + `MotionGuard`, as the panel does.
    private func guardedPath(
        _ g: AlternateDragPicker.Geometry, origin o: CGPoint, opening: Int?,
        _ points: [CGPoint]
    ) -> [Int?] {
        var guardrail = AlternateDragPicker.MotionGuard(origin: o)
        var current = opening
        return points.map { p in
            let proposed = AlternateDragPicker.selection(origin: o, point: p, geometry: g, current: current)
            current = guardrail.resolve(proposed: proposed, current: current, point: p, geometry: g)
            return current
        }
    }

    /// Default on column 0, finger on column 2. Drifting left past the dead zone
    /// must not move the highlight *right* to the cell under the finger.
    func testDriftTowardTheDefaultNeverJumpsAway() {
        let g = singleRow
        let o = origin(below: g)
        let path = [-12.0, -20, -30].map { CGPoint(x: o.x + $0, y: o.y) }
        XCTAssertEqual(guardedPath(g, origin: o, opening: 0, path), [0, 0, 0])
        // The unguarded absolute mapping would have jumped against the motion.
        XCTAssertEqual(AlternateDragPicker.selection(origin: o, point: path[0], geometry: g, current: 0), 2)
    }

    /// A deliberate move away from the default follows the finger immediately and
    /// every option stays reachable.
    func testDeliberateMoveLeavesTheDefaultInTheFingersDirection() {
        let g = singleRow
        let o = origin(below: g)
        let path = [12.0, 52, 104].map { CGPoint(x: o.x + $0, y: o.y) }
        XCTAssertEqual(guardedPath(g, origin: o, opening: 0, path), [2, 3, 4])
    }

    /// Having drifted onto the default's side, turning back re-follows the finger
    /// as soon as it has really moved that way — not only once it passes the origin.
    func testTurningBackAfterReachingTheDefaultFollowsTheFinger() {
        let g = singleRow  // pitch 52; column centres 24, 76, 128, ...
        let o = origin(below: g)  // x = 128
        let xs: [Double] = [100, 60, 30, 24, 40, 60, 80]
        let result = guardedPath(g, origin: o, opening: 0, xs.map { CGPoint(x: $0, y: o.y) })
        XCTAssertEqual(
            result, [0, 0, 0, 0, 0, 1, 1],
            "x=60 is 36pt right of the leftmost point and past the 0|1 boundary hysteresis")
    }

    func testTremorAgainstTheDefaultDoesNotSwitch() {
        let g = singleRow
        let o = origin(below: g)
        let xs: [Double] = [-13, -21, -13, -21, -14]
        XCTAssertEqual(
            guardedPath(g, origin: o, opening: 0, xs.map { CGPoint(x: o.x + $0, y: o.y) }),
            [0, 0, 0, 0, 0], "an 8pt back-and-forth is not a move")
    }

    /// A multi-row popup opens on the top-left option while the finger rests
    /// below it (nearest the bottom row). Neither a sideways move nor lifting the
    /// finger toward the popup may drop the highlight to the bottom row.
    func testMultiRowDefaultKeepsItsRowUntilTheFingerMovesThatWay() {
        let g = AlternateDragPicker.Geometry(
            optionCount: 10, columns: 5,
            cellWidth: 48, cellHeight: 46, spacing: 4, rowSpacing: 0)
        let o = origin(below: g)  // below row 1, on column 2
        XCTAssertEqual(AlternateDragPicker.defaultSelection(geometry: g), 0)
        let sideways = guardedPath(
            g, origin: o, opening: 0,
            [CGPoint(x: o.x + 12, y: o.y), CGPoint(x: o.x + 52, y: o.y)])
        XCTAssertEqual(sideways, [2, 3], "the column follows, the row stays the default's")
        // Up toward the popup: still row 0 while below it, row 0 when on it, and
        // then moving down selects row 1.
        let ys: [Double] = [o.y - 30, 60, 23, 40, 70]
        let vertical = guardedPath(g, origin: o, opening: 0, ys.map { CGPoint(x: o.x, y: $0) })
        XCTAssertEqual(vertical, [0, 0, 0, 0, 5])
    }

    func testSlideOutStillCancelsThroughTheGuard() {
        let g = singleRow
        let o = origin(below: g)
        let out = CGPoint(x: g.contentWidth + AlternateDragPicker.Tuning.cancelMargin + 1, y: o.y)
        let result = guardedPath(g, origin: o, opening: 0, [CGPoint(x: o.x + 20, y: o.y), out])
        XCTAssertEqual(result.last, .some(nil))
        XCTAssertEqual(AlternateDragPicker.releaseResolution(highlighted: 4, point: out, geometry: g), .none)
        let left = CGPoint(x: -AlternateDragPicker.Tuning.cancelMargin - 1, y: o.y)
        XCTAssertEqual(
            guardedPath(g, origin: o, opening: 0, [left]), [nil],
            "overshooting past the default's own edge cancels too")
    }

    /// When the highlight is under the finger the guard is transparent: the
    /// guarded path equals the plain mapping over a full sweep, including a
    /// slide-out and re-entry.
    func testGuardIsTransparentWhenTheHighlightIsUnderTheFinger() {
        let g = singleRow
        let o = CGPoint(x: g.centerX(ofColumn: 0), y: g.contentHeight + 60)
        var xs: [Double] = []
        xs += stride(from: 0.0, through: 290, by: 2).map { o.x + $0 }
        xs += stride(from: 290.0, through: -60, by: -2).map { o.x + $0 }
        let points = xs.map { CGPoint(x: $0, y: o.y) }
        var plain: [Int?] = []
        var current: Int? = 0
        for p in points {
            current = AlternateDragPicker.selection(origin: o, point: p, geometry: g, current: current)
            plain.append(current)
        }
        XCTAssertEqual(guardedPath(g, origin: o, opening: 0, points), plain)
        XCTAssertTrue(plain.contains(4) && plain.contains(nil), "the sweep really reaches the end and cancels")
    }

    /// Sliding after a long-press follows order: with the popup opened at item 0, one step right is item 1 whatever column the finger is in.
    func testAnchoredSlideStepsFromTheOpeningDefaultInOrder() {
        let g = singleRow
        let o = origin(below: g)  // finger under the middle column (2)
        let step = g.pitchX
        XCTAssertEqual(
            AlternateDragPicker.selection(
                origin: o, point: point(g, dx: step), geometry: g,
                current: 0, anchor: 0), 1)
        XCTAssertEqual(
            AlternateDragPicker.selection(
                origin: o, point: point(g, dx: 2 * step), geometry: g,
                current: 1, anchor: 0), 2)
        // Unanchored keeps the old absolute mapping (finger column + 1).
        XCTAssertEqual(
            AlternateDragPicker.selection(
                origin: o, point: point(g, dx: step), geometry: g,
                current: nil), 3)
        // A stationary finger keeps the anchor.
        XCTAssertEqual(
            AlternateDragPicker.selection(
                origin: o, point: o, geometry: g,
                current: 0, anchor: 0), 0)
    }

    /// Dragging down cancels: only past 72pt, fading proportionally on the way.
    func testDropProgressRampsToTheCancel() {
        XCTAssertEqual(AlternateDragPicker.dropProgress(0), 0)
        XCTAssertEqual(AlternateDragPicker.dropProgress(AlternateDragPicker.Tuning.cancelFeedbackStart), 0)
        XCTAssertEqual(AlternateDragPicker.dropProgress(AlternateDragPicker.Tuning.cancelDrop), 1)
        XCTAssertEqual(AlternateDragPicker.dropProgress(-40), 0)
        XCTAssertGreaterThan(
            AlternateDragPicker.Tuning.cancelDrop, 54, "longer than one key row so ordinary hand jitter does not cancel"
        )
        XCTAssertFalse(AlternateDragPicker.isCancelled(point: .zero, geometry: singleRow, drop: 50))
    }
}
