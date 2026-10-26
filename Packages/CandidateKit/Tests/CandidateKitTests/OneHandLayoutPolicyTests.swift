import XCTest

@testable import CandidateKit

/// The narrowing policy is the single owner of one-handed geometry: these tests
/// pin the exact widths callers lay out with and every incompatibility fallback.
final class OneHandLayoutPolicyTests: XCTestCase {

    // MARK: Mode resolution (shared defaults value)

    func testModeResolveDefaultsToOffForMissingAndUnknown() {
        XCTAssertEqual(KeyboardOneHandMode.resolve(nil), .off)
        XCTAssertEqual(KeyboardOneHandMode.resolve(""), .off)
        XCTAssertEqual(KeyboardOneHandMode.resolve("Off"), .off)
        XCTAssertEqual(KeyboardOneHandMode.resolve("center"), .off)
        XCTAssertEqual(KeyboardOneHandMode.resolve("0"), .off)
        for mode in KeyboardOneHandMode.allCases {
            XCTAssertEqual(KeyboardOneHandMode.resolve(mode.rawValue), mode)
        }
    }

    // MARK: Off and incompatible contexts always stay full width

    func testOffModeStaysFullWidthAtEveryPanelWidth() {
        for width in [320.0, 375, 390, 428, 600, 664, 744, 1024, 1366] {
            for mode in [KeyboardOneHandMode.left, .right] {
                let plan = KeyboardOneHandLayoutPolicy.plan(mode: mode, panelWidth: width, isAvailable: false)
                XCTAssertEqual(plan, .inactive(panelWidth: width), "width \(width)")
            }
            let off = KeyboardOneHandLayoutPolicy.plan(mode: .off, panelWidth: width, isAvailable: true)
            XCTAssertEqual(off, .inactive(panelWidth: width))
        }
    }

    func testLandscapePadAndUnknownWidthsStayFullWidth() {
        for width in [0.0, 1, 374.9, 600.1, 664, 744, 1024, 1180, 1366] {
            // Explicit non-portrait facts: landscape phones and all iPad contexts.
            let plan = KeyboardOneHandLayoutPolicy.plan(mode: .left, panelWidth: width, isAvailable: false)
            XCTAssertEqual(plan, .inactive(panelWidth: width), "width \(width)")
        }
    }

    func testAvailabilityFollowsSurfaceRatherThanPhoneIdiom() {
        XCTAssertTrue(
            KeyboardOneHandLayoutPolicy.isAvailable(
                panelWidth: 402, isPhone: true, compactHeight: false, regularWidth: false))
        XCTAssertFalse(
            KeyboardOneHandLayoutPolicy.isAvailable(
                panelWidth: 402, isPhone: true, compactHeight: false, regularWidth: true))
        XCTAssertFalse(
            KeyboardOneHandLayoutPolicy.isAvailable(
                panelWidth: 402, isPhone: true, compactHeight: true, regularWidth: false))
        for width in [320.0, 402, 744, 1024] {
            XCTAssertFalse(
                KeyboardOneHandLayoutPolicy.isAvailable(
                    panelWidth: width, isPhone: false, compactHeight: false, regularWidth: false))
        }
    }

    func testDuoOuterSurfaceSupportsOneHandAtMeasuredWidth() {
        let available = KeyboardOneHandLayoutPolicy.isAvailable(
            panelWidth: 466, isPhone: true, compactHeight: false, regularWidth: false)
        XCTAssertTrue(available)
        for mode in [KeyboardOneHandMode.left, .right] {
            let plan = KeyboardOneHandLayoutPolicy.plan(
                mode: mode, panelWidth: 466, isAvailable: available)
            XCTAssertTrue(plan.active)
            XCTAssertEqual(plan.contentWidth, 396)
            XCTAssertEqual(plan.gutterWidth, 70)
            XCTAssertEqual(plan.gutterOnLeft, mode == .right)
        }
    }

    func testRegularWidthPhoneSurfaceAlwaysStaysFullWidth() {
        for width in [320.0, 375, 402, 450, 466, 550, 600, 744, 1024] {
            let available = KeyboardOneHandLayoutPolicy.isAvailable(
                panelWidth: width, isPhone: true, compactHeight: false, regularWidth: true)
            XCTAssertFalse(available)
            for mode in [KeyboardOneHandMode.left, .right] {
                let plan = KeyboardOneHandLayoutPolicy.plan(
                    mode: mode, panelWidth: width, isAvailable: available)
                XCTAssertEqual(plan, .inactive(panelWidth: width))
            }
        }
    }

    func testFoldingAndResizingRecomputesWithoutChangingSavedMode() {
        for width in [402.0, 744, 1024, 600.1, 402] {
            let available = KeyboardOneHandLayoutPolicy.isAvailable(
                panelWidth: width, isPhone: true, compactHeight: false, regularWidth: false)
            let plan = KeyboardOneHandLayoutPolicy.plan(
                mode: .right, panelWidth: width, isAvailable: available)
            if width == 402 {
                XCTAssertTrue(plan.active)
                XCTAssertEqual(plan.contentWidth, 341)
                XCTAssertTrue(plan.gutterOnLeft)
            } else {
                XCTAssertEqual(plan, .inactive(panelWidth: width))
            }
        }
    }

    // MARK: Standard portrait widths narrow for real

    /// Exact widths for the shipped iPhone portrait sizes: content is floored at
    /// 320pt, the gutter takes the rest and always clears the 44pt control minimum.
    func testStandardPortraitWidthsProduceExactContentAndGutter() {
        let cases: [(width: Double, content: Double)] = [
            (375, 320),  // 375*0.85=318.75 floored 318, then the 320 floor wins; gutter 55
            (390, 331),  // 331.5 -> 331, gutter 59
            (393, 334),  // 334.05 -> 334, gutter 59
            (402, 341),  // 341.7 -> 341, gutter 61
            (414, 351),  // 351.9 -> 351, gutter 63
            (428, 363),  // 363.8 -> 363, gutter 65
            (430, 365),  // 365.5 -> 365, gutter 65
            (440, 374),
            (450, 382),
            (466, 396),
            (600, 510),
        ]
        for (width, content) in cases {
            for mode in [KeyboardOneHandMode.left, .right] {
                let plan = KeyboardOneHandLayoutPolicy.plan(mode: mode, panelWidth: width, isAvailable: true)
                XCTAssertTrue(plan.active, "width \(width)")
                XCTAssertEqual(plan.contentWidth, Double(content), accuracy: 0.001, "width \(width)")
                XCTAssertEqual(plan.gutterWidth, width - Double(content), accuracy: 0.001, "width \(width)")
                XCTAssertGreaterThanOrEqual(
                    plan.gutterWidth,
                    KeyboardOneHandLayoutPolicy.minimumGutterWidth,
                    "gutter must fit the >=44pt restore control")
                XCTAssertGreaterThanOrEqual(
                    plan.contentWidth,
                    KeyboardOneHandLayoutPolicy.minimumContentWidth,
                    "keys must stay usable")
                XCTAssertEqual(plan.contentWidth + plan.gutterWidth, width, accuracy: 0.001)
                // The content hugs the chosen edge: right-handed mode keeps the gutter on the left.
                XCTAssertEqual(plan.gutterOnLeft, mode == .right, "width \(width)")
            }
        }
    }

    /// 320pt content is exactly the floor: a panel whose 85% share would fall
    /// below it still activates by taking the floor (and a wider gutter).
    func testContentFloorBeatsRatioWithoutDisabling() {
        let plan = KeyboardOneHandLayoutPolicy.plan(mode: .left, panelWidth: 375, isAvailable: true)
        XCTAssertEqual(plan.contentWidth, 320)
        XCTAssertEqual(plan.gutterWidth, 55)
    }

    // MARK: The plan is the actual layout contract (no scaling)

    /// The narrowed width is a real laid-out width: content + gutter must tile the
    /// panel exactly, so host code can assign frames without any transform.
    func testPlanTilesPanelExactlyOnBothEdges() {
        for width in stride(from: 375.0, through: 600.0, by: 1.0) {
            for mode in [KeyboardOneHandMode.left, .right] {
                let plan = KeyboardOneHandLayoutPolicy.plan(mode: mode, panelWidth: width, isAvailable: true)
                XCTAssertTrue(plan.active)
                XCTAssertEqual(plan.contentWidth + plan.gutterWidth, width, accuracy: 0.001)
                XCTAssertFalse(plan.contentWidth.isNaN)
            }
        }
    }
}
