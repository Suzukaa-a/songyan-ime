import XCTest

@testable import LayoutKit

/// Geometry regression suite for the phone (T9) shell.
///
/// Every assertion is a *pure* fact about `PhoneKeypadMetrics`, so the exact
/// frame that the SwiftUI shell installs is provable without a simulator: the
/// shell reads `columnRect` / `rowY` / `railSlots` / `contentWidth` verbatim.
///
/// The widths include the devices called out in review (320 / 375 / 390 / 402 /
/// 412 / 430) at the point-scale the panel actually proposes: the screen width
/// minus the panel's 4pt outer insets on each side. `iPhone Air` is 420pt wide →
/// 412pt content, the reference case.
final class PhoneKeypadMetricsTests: XCTestCase {
    /// (screen width, expected content width after the panel's 4pt insets).
    private let devices: [(name: String, screen: Double, content: Double)] = [
        ("iPhone SE 1st", 320, 312),
        ("iPhone SE 2/3", 375, 367),
        ("iPhone 13 mini", 375, 367),
        ("iPhone 15", 393, 385),
        ("iPhone 16", 393, 385),
        ("iPhone 12/13/14", 390, 382),
        ("iPhone 16 Pro", 402, 394),
        ("iPhone Air", 420, 412),
        ("iPhone 15 Pro Max", 430, 422),
        ("iPhone 16 Pro Max", 440, 432),
    ]

    // MARK: Width identity

    func testContentWidthIsExactlyRailsPlusGapsPlusDigits() {
        for device in devices {
            let m = PhoneKeypadMetrics.resolve(width: device.content)
            XCTAssertEqual(
                m.computedContentWidth, m.contentWidth, accuracy: 0.0001,
                "\(device.name): rail + gaps + 3 digits must equal content width")
            XCTAssertEqual(
                m.railWidth * 2 + m.mainWidth + m.spacing * 2, m.contentWidth,
                accuracy: 0.0001, "\(device.name): explicit width identity")
            XCTAssertEqual(m.mainWidth, m.digitWidth * 3 + m.spacing * 2, accuracy: 0.0001)
            // The whole shell fits its content box with the outer margin used twice.
            XCTAssertEqual(
                m.contentWidth + m.outerInset * 2, device.content, accuracy: 0.0001,
                "\(device.name): the shell fills the content box symmetrically")
        }
    }

    func testBottomControlRowSharesTheGridContentWidth() {
        for device in devices {
            let m = PhoneKeypadMetrics.resolve(width: device.content)
            let grid = m.columnRect(.leadingRail).minX
            let gridRight = m.columnRect(.trailingRail).maxX
            let control = m.controlRowRect()
            XCTAssertEqual(control.width, m.contentWidth, accuracy: 0.0001, device.name)
            XCTAssertEqual(
                control.minX, grid, accuracy: 0.0001,
                "\(device.name): control row and grid share the left content edge")
            XCTAssertEqual(
                control.maxX, gridRight, accuracy: 0.0001,
                "\(device.name): control row and grid share the right content edge")
            // The exact drift that this fix removes: no centring inset may be
            // inserted *between* the grid and the control row.
            XCTAssertEqual(
                m.outerInset, 0, accuracy: 0.0001,
                "\(device.name): supported phones must not need a side margin")
        }
    }

    // MARK: Touch targets

    func testEverySlotIsAtLeast44ptOnSupportedPhones() {
        for device in devices {
            let m = PhoneKeypadMetrics.resolve(width: device.content)
            XCTAssertGreaterThanOrEqual(m.railWidth, 44 - 0.0001, device.name)
            XCTAssertGreaterThanOrEqual(m.digitWidth, 44 - 0.0001, device.name)
            XCTAssertGreaterThanOrEqual(m.rowHeight, 44 - 0.0001, device.name)
        }
    }

    func testRailsNeverOutScaleTheDigits() {
        for device in devices {
            let m = PhoneKeypadMetrics.resolve(width: device.content)
            XCTAssertLessThanOrEqual(m.railWidth, m.digitWidth + 0.0001, device.name)
        }
    }

    // MARK: Symmetry

    func testRailsAreMirrorSymmetricAboutTheCentreline() {
        for device in devices {
            let m = PhoneKeypadMetrics.resolve(width: device.content)
            XCTAssertTrue(m.railsAreSymmetric(), device.name)
            let left = m.columnRect(.leadingRail)
            let right = m.columnRect(.trailingRail)
            XCTAssertEqual(left.width, right.width, accuracy: 0.0001, device.name)
            XCTAssertEqual(
                left.midX + right.midX, m.contentWidth, accuracy: 0.0001,
                "\(device.name): rail centres mirror about the shell centre")
        }
    }

    func testDigitColumnsAreEvenlyPitchedAndSymmetric() {
        for device in devices {
            let m = PhoneKeypadMetrics.resolve(width: device.content)
            let d0 = m.columnRect(.digit(0))
            let d1 = m.columnRect(.digit(1))
            let d2 = m.columnRect(.digit(2))
            XCTAssertEqual(
                d1.midX, m.centerlineX, accuracy: 0.0001,
                "\(device.name): middle digit column is exactly centred")
            XCTAssertEqual(d0.width, d1.width, accuracy: 0.0001, device.name)
            XCTAssertEqual(d1.width, d2.width, accuracy: 0.0001, device.name)
            // Uniform column pitch: d1.minX - d0.minX == d2.minX - d1.minX.
            XCTAssertEqual(d1.minX - d0.minX, d2.minX - d1.minX, accuracy: 0.0001, device.name)
            // Left edge of d0 mirrors the right edge of d2 about the centreline.
            XCTAssertEqual(
                d0.minX + d2.maxX, m.contentWidth, accuracy: 0.0001,
                "\(device.name): outer digit edges are symmetric")
        }
    }

    func testHorizontalGapsAreAllExactlyTheSharedSpacing() {
        for device in devices {
            let m = PhoneKeypadMetrics.resolve(width: device.content)
            XCTAssertEqual(m.spacing, PhoneKeypadMetrics.spacing, accuracy: 0.0001, device.name)
            let d0 = m.columnRect(.digit(0))
            let d1 = m.columnRect(.digit(1))
            let d2 = m.columnRect(.digit(2))
            XCTAssertEqual(d1.minX - d0.maxX, m.spacing, accuracy: 0.0001, device.name)
            XCTAssertEqual(d2.minX - d1.maxX, m.spacing, accuracy: 0.0001, device.name)
            XCTAssertEqual(
                d0.minX - m.columnRect(.leadingRail).maxX, m.spacing,
                accuracy: 0.0001, device.name)
            XCTAssertEqual(
                m.columnRect(.trailingRail).minX - d2.maxX, m.spacing,
                accuracy: 0.0001, device.name)
        }
    }

    // MARK: Rows and baselines

    func testRailSlotsShareTheDigitRowBaselines() {
        for device in devices {
            let m = PhoneKeypadMetrics.resolve(width: device.content)
            // Leading rail: one slot per digit row.
            let leading = m.railSlots(.leading, spans: [1, 1, 1])
            XCTAssertEqual(leading.count, 3)
            for row in 0..<3 {
                XCTAssertEqual(
                    leading[row].minY, m.rowY(row), accuracy: 0.0001,
                    "\(device.name): leading rail slot \(row) starts on digit row \(row)")
                XCTAssertEqual(leading[row].height, m.rowHeight, accuracy: 0.0001, device.name)
            }
            // Trailing rail (generic span example): a double-height key on rows
            // 0–1 and a single-row key on row 2.
            let trailing = m.railSlots(.trailing, spans: [2, 1])
            XCTAssertEqual(trailing.count, 2)
            XCTAssertEqual(trailing[0].minY, m.rowY(0), accuracy: 0.0001, device.name)
            XCTAssertEqual(
                trailing[0].maxY, m.rowY(1) + m.rowHeight, accuracy: 0.0001,
                "\(device.name): double-height slot ends exactly on digit row 1")
            XCTAssertEqual(
                trailing[1].minY, m.rowY(2), accuracy: 0.0001,
                "\(device.name): single-row slot starts exactly on digit row 2")
            XCTAssertEqual(
                trailing[1].maxY, m.mainHeight, accuracy: 0.0001,
                "\(device.name): separator ends exactly on the grid's bottom edge")
        }
    }

    func testRowPitchIsUniformAndMatchesSpacing() {
        for device in devices {
            let m = PhoneKeypadMetrics.resolve(width: device.content)
            XCTAssertEqual(m.rowY(1) - (m.rowY(0) + m.rowHeight), m.spacing, accuracy: 0.0001)
            XCTAssertEqual(m.rowY(2) - (m.rowY(1) + m.rowHeight), m.spacing, accuracy: 0.0001)
            XCTAssertEqual(m.mainHeight, m.rowHeight * 3 + m.spacing * 2, accuracy: 0.0001, device.name)
        }
    }

    /// The user-reported vertical drift: a rail key looked ~2px lower than the
    /// same-row digit keys. A double-height key spans digit rows 0–1, so its visual
    /// top must equal digit row 0's visual top; a single-row key on row 2 must match
    /// digit row 2's. Any per-key vertical inset applied inconsistently is caught
    /// here.
    func testDoubleHeightAndSingleRowRailVisualTopsMatchTheirDigitRows() {
        for device in devices {
            let m = PhoneKeypadMetrics.resolve(width: device.content, rowHeight: 54)
            let insertX = 2.0
            let insertY = 2.0
            let doubleHeight = m.railSlots(.trailing, spans: [2, 1])[0]
            let singleRow = m.railSlots(.trailing, spans: [2, 1])[1]
            let row0Visual = m.digitCellRect(row: 0, column: 0).visualRect(insetX: insertX, insetY: insertY)
            let row2Visual = m.digitCellRect(row: 2, column: 0).visualRect(insetX: insertX, insetY: insertY)
            XCTAssertEqual(
                doubleHeight.visualRect(insetX: insertX, insetY: insertY).minY,
                row0Visual.minY, accuracy: 0.0001,
                "\(device.name): double-height rail key's visual top must match digit row 0")
            XCTAssertEqual(
                singleRow.visualRect(insetX: insertX, insetY: insertY).minY,
                row2Visual.minY, accuracy: 0.0001,
                "\(device.name): row-2 rail key's visual top must match digit row 2")
            // The same holds for the leading rail's rows.
            for row in 0..<3 {
                let railVisual = m.railSlots(.leading, spans: [1, 1, 1])[row]
                    .visualRect(insetX: insertX, insetY: insertY)
                let digitVisual = m.digitCellRect(row: row, column: 0)
                    .visualRect(insetX: insertX, insetY: insertY)
                XCTAssertEqual(
                    railVisual.minY, digitVisual.minY, accuracy: 0.0001,
                    "\(device.name): leading rail row \(row) visual baseline")
                XCTAssertEqual(
                    railVisual.maxY, digitVisual.maxY, accuracy: 0.0001,
                    "\(device.name): leading rail row \(row) visual bottom")
            }
        }
    }

    func testBottomControlRowIsOutsideTheThreeRowGrid() {
        for device in devices {
            let m = PhoneKeypadMetrics.resolve(width: device.content)
            XCTAssertEqual(
                m.controlRowRect().minY, m.mainHeight + m.spacing, accuracy: 0.0001,
                "\(device.name): control row is one gap below the grid")
            XCTAssertEqual(m.totalHeight, m.mainHeight + m.spacing + m.rowHeight, accuracy: 0.0001)
            // Digit cells never overlap the control row.
            for row in 0..<3 {
                XCTAssertLessThanOrEqual(m.mainRowRect(row).maxY, m.controlRowY + 0.0001, device.name)
            }
        }
    }

    // MARK: Rails with different key counts

    func testRailSlotsAreDeterministicRegardlessOfTheOtherRail() {
        // One key -> spans the whole grid; two keys -> [2, 1]; three -> [1, 1, 1].
        XCTAssertEqual(PhoneKeypadMetrics.slotSpans(keyCount: 1), [3])
        XCTAssertEqual(PhoneKeypadMetrics.slotSpans(keyCount: 2), [2, 1])
        XCTAssertEqual(PhoneKeypadMetrics.slotSpans(keyCount: 3), [1, 1, 1])
        // Four or more keys keep one row each and scroll past the grid.
        XCTAssertEqual(PhoneKeypadMetrics.slotSpans(keyCount: 4), [1, 1, 1, 1])
        XCTAssertEqual(PhoneKeypadMetrics.slotSpans(keyCount: 0), [])

        let m = PhoneKeypadMetrics.resolve(width: 412)
        // Different key counts on the two rails still produce the same row rhythm.
        let oneKey = m.railSlots(.trailing, spans: PhoneKeypadMetrics.slotSpans(keyCount: 1))
        let twoKeys = m.railSlots(.trailing, spans: PhoneKeypadMetrics.slotSpans(keyCount: 2))
        XCTAssertEqual(oneKey[0].height, m.mainHeight, accuracy: 0.0001)
        XCTAssertEqual(twoKeys[0].minY, oneKey[0].minY, accuracy: 0.0001)
        XCTAssertEqual(twoKeys[1].minY, m.rowY(2), accuracy: 0.0001)
        XCTAssertEqual(twoKeys[1].maxY, m.mainHeight, accuracy: 0.0001)
    }

    // MARK: Visual inset independence

    func testVisualInsetNeverChangesTheLayoutFrameOrHitRegion() {
        for device in devices {
            let m = PhoneKeypadMetrics.resolve(width: device.content)
            for column in [PhoneKeypadMetrics.Column.leadingRail, .digit(0), .digit(2), .trailingRail] {
                let slot = m.columnRect(column)
                for inset in [0.0, 2, 4] {
                    let visual = slot.visualRect(insetX: inset, insetY: inset)
                    XCTAssertEqual(slot.minX, slot.minX, accuracy: 0.0001)
                    XCTAssertEqual(visual.minX, slot.minX + inset, accuracy: 0.0001)
                    XCTAssertEqual(visual.width, max(0, slot.width - inset * 2), accuracy: 0.0001)
                    XCTAssertEqual(visual.minY, slot.minY + inset, accuracy: 0.0001)
                    XCTAssertEqual(visual.height, max(0, slot.height - inset * 2), accuracy: 0.0001)
                }
            }
        }
    }

    // MARK: Landscape / dynamic row heights

    func testCompactAndPortraitRowHeightsKeepTheSameHorizontalGeometry() {
        let portrait = PhoneKeypadMetrics.resolve(width: 412, rowHeight: 54)
        let landscape = PhoneKeypadMetrics.resolve(width: 812, rowHeight: 44)
        XCTAssertEqual(portrait.mainHeight, 54 * 3 + 4 * 2, accuracy: 0.0001)
        XCTAssertEqual(landscape.mainHeight, 44 * 3 + 4 * 2, accuracy: 0.0001)
        // Row height never changes the width solution.
        XCTAssertEqual(
            PhoneKeypadMetrics.resolve(width: 412, rowHeight: 44).railWidth,
            portrait.railWidth, accuracy: 0.0001)
        XCTAssertEqual(
            PhoneKeypadMetrics.resolve(width: 412, rowHeight: 44).digitWidth,
            portrait.digitWidth, accuracy: 0.0001)
    }

    /// Dynamic type may change glyph sizes but the geometry must be invariant:
    /// every row height in the supported 44...60pt range keeps the identical
    /// rail/digit widths and row baselines.
    func testGeometryIsInvariantAcrossSupportedRowHeights() {
        let reference = PhoneKeypadMetrics.resolve(width: 412, rowHeight: 54)
        for rowHeight in stride(from: 44.0, through: 60.0, by: 1.0) {
            let m = PhoneKeypadMetrics.resolve(width: 412, rowHeight: rowHeight)
            XCTAssertEqual(m.railWidth, reference.railWidth, accuracy: 0.0001, "\(rowHeight)")
            XCTAssertEqual(m.digitWidth, reference.digitWidth, accuracy: 0.0001, "\(rowHeight)")
            XCTAssertEqual(m.mainHeight, rowHeight * 3 + 8, accuracy: 0.0001, "\(rowHeight)")
            XCTAssertEqual(m.rowY(2), (rowHeight + 4) * 2, accuracy: 0.0001, "\(rowHeight)")
        }
    }

    /// The shell's height budget must equal the panel's own geometry
    /// (`KeyboardPanelGeometry`): `mainAreaHeight = 3·row + 2·gap` and
    /// `panelHeight = header + mainAreaHeight + row + 12`. The T9 shell reports
    /// `totalHeight = mainHeight + gap + rowHeight`, i.e. the same budget, so the
    /// panel height never jumps when T9 is selected.
    func testShellHeightBudgetMatchesThePanelGeometry() {
        for rowHeight in [44.0, 54.0] {
            let m = PhoneKeypadMetrics.resolve(width: 412, rowHeight: rowHeight)
            let panelMainAreaHeight = 3 * rowHeight + 8
            XCTAssertEqual(m.mainHeight, panelMainAreaHeight, accuracy: 0.0001, "\(rowHeight)")
            XCTAssertEqual(
                m.totalHeight, panelMainAreaHeight + m.spacing + rowHeight,
                accuracy: 0.0001, "\(rowHeight)")
            XCTAssertEqual(m.totalHeight, rowHeight * 4 + 12, accuracy: 0.0001, "\(rowHeight)")
        }
    }

    // MARK: Degenerate inputs

    func testTinyOrInvalidWidthsAreFiniteAndNeverOverflow() {
        for width in [0.0, 44, 100, 180, 250, -1, .nan, .infinity] {
            let m = PhoneKeypadMetrics.resolve(width: width)
            XCTAssertTrue(m.spacing.isFinite && m.spacing >= 0)
            XCTAssertTrue(m.railWidth.isFinite && m.railWidth >= 0, "\(width)")
            XCTAssertTrue(m.digitWidth.isFinite && m.digitWidth >= 0)
            XCTAssertTrue(m.outerInset.isFinite && m.outerInset >= 0)
            XCTAssertLessThanOrEqual(
                m.railWidth, m.digitWidth + 0.0001,
                "a rail must never out-scale the digits at \(width)")
            let expected = width.isFinite ? max(0, width) : 0
            XCTAssertLessThanOrEqual(
                m.contentWidth, expected + 0.0001,
                "invalid width \(width) must not overflow")
        }
        for rowHeight in [-1.0, .nan, .infinity, 0] {
            let m = PhoneKeypadMetrics.resolve(width: 412, rowHeight: rowHeight)
            XCTAssertTrue(m.rowHeight.isFinite && m.rowHeight >= 0)
            XCTAssertTrue(m.mainHeight.isFinite && m.mainHeight >= 0)
        }
    }

    func testVeryNarrowPreviewsScaleAsOneUnitAndStillFillTheWidth() {
        // Below rail(44) + digit(44)×3 + gaps(16) = 236pt the shell scales as one
        // unit; at/above it the rails stay at the touch minimum and the digits grow.
        let minimumContent: Double = 44 * 2 + 44 * 3 + 4 * 4
        for width in [44.0, 100, 180, minimumContent - 1] {
            let m = PhoneKeypadMetrics.resolve(width: width)
            XCTAssertEqual(
                m.contentWidth, width, accuracy: 0.0001,
                "preview \(width) still fills its content box")
            XCTAssertEqual(
                m.railWidth, m.digitWidth, accuracy: 0.0001,
                "preview \(width) scales rails and digits together")
            XCTAssertEqual(m.contentWidth + m.outerInset * 2, width, accuracy: 0.0001)
        }
        let justAbove = PhoneKeypadMetrics.resolve(width: minimumContent + 1)
        XCTAssertGreaterThanOrEqual(justAbove.railWidth, 44 - 0.0001)
        XCTAssertGreaterThanOrEqual(justAbove.digitWidth, 44 - 0.0001)
        XCTAssertEqual(justAbove.contentWidth, minimumContent + 1, accuracy: 0.0001)
    }

    // MARK: Monotonicity

    func testContentWidthIsMonotonicAcrossWidths() {
        var previous = 0.0
        for width in stride(from: 0.0, through: 1200.0, by: 7.0) {
            let m = PhoneKeypadMetrics.resolve(width: width)
            XCTAssertGreaterThanOrEqual(m.contentWidth, previous - 0.0001, "\(width)")
            // The grid never exceeds its content box.
            XCTAssertLessThanOrEqual(m.contentWidth, max(0, width) + 0.0001, "\(width)")
            previous = m.controlRowRect().maxX
        }
    }

    // MARK: Control row identity

    /// The bottom control row is laid out by `KeyboardControlPolicy`. Its slot
    /// widths must fill exactly the grid's content width (no hidden side slack and
    /// no overflow), which is the property the screenshot violated.
    func testControlRowPolicyFillsTheGridContentWidthExactly() {
        for device in devices {
            let m = PhoneKeypadMetrics.resolve(width: device.content)
            for globe in [false, true] {
                let policy = KeyboardControlPolicy(
                    page: .letters, isEnglishMode: false,
                    hasGlobe: globe, isPhoneLayout: true,
                    usesASCIIPunctuation: false)
                let metrics = policy.metrics(width: m.contentWidth)
                let slots = policy.slots
                let total =
                    slots.reduce(0.0) { $0 + metrics[$1] }
                    + metrics.spacing * Double(max(0, slots.count - 1))
                XCTAssertEqual(
                    total, m.contentWidth, accuracy: 0.0001,
                    "\(device.name) globe=\(globe): control row must fill the grid width")
                XCTAssertEqual(metrics.spacing, m.spacing, accuracy: 0.0001, device.name)
            }
        }
    }

    // MARK: The screenshot defect, in points

    /// Reproduces the user's screenshot measurements on iPhone Air: the panel
    /// proposes 412pt, so the grid must span 0...412 — **not** the old 8...404
    /// (which left the grid visibly 8pt inside the control row on each side).
    func testiPhoneAirGridFillsTheControlRowInsteadOfLeavingSideSlack() {
        let m = PhoneKeypadMetrics.resolve(width: 412, rowHeight: 54)
        XCTAssertEqual(m.contentWidth, 412, accuracy: 0.0001)
        XCTAssertEqual(m.digitWidth, PhoneKeypadMetrics.preferredDigitWidth, accuracy: 0.0001)
        // Rails absorb the surplus: (412 − 252 − 16) / 2 = 72pt each.
        XCTAssertEqual(m.railWidth, 72, accuracy: 0.0001)
        XCTAssertEqual(m.outerInset, 0, accuracy: 0.0001)
        XCTAssertEqual(m.columnRect(.leadingRail).minX, 0, accuracy: 0.0001)
        XCTAssertEqual(m.columnRect(.leadingRail).maxX, 72, accuracy: 0.0001)
        XCTAssertEqual(m.columnRect(.digit(0)).minX, 76, accuracy: 0.0001)
        XCTAssertEqual(m.columnRect(.digit(0)).maxX, 160, accuracy: 0.0001)
        XCTAssertEqual(m.columnRect(.digit(1)).minX, 164, accuracy: 0.0001)
        XCTAssertEqual(m.columnRect(.digit(2)).maxX, 336, accuracy: 0.0001)
        XCTAssertEqual(m.columnRect(.trailingRail).minX, 340, accuracy: 0.0001)
        XCTAssertEqual(m.columnRect(.trailingRail).maxX, 412, accuracy: 0.0001)
        XCTAssertEqual(m.centerlineX, 206, accuracy: 0.0001)
    }
}
