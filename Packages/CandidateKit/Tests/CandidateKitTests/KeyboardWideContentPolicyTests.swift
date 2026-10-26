import LayoutKit
import XCTest

@testable import CandidateKit

/// Wide-surface geometry: threshold, three docks, real widths (never scale), and malformed input.
final class KeyboardWideContentPolicyTests: XCTestCase {
    func testDockResolvesMissingAndUnknownToCenter() {
        XCTAssertEqual(KeyboardContentDock.resolve(nil), .center)
        XCTAssertEqual(KeyboardContentDock.resolve(""), .center)
        XCTAssertEqual(KeyboardContentDock.resolve("Center"), .center)
        XCTAssertEqual(KeyboardContentDock.resolve("LEFT"), .center)
        XCTAssertEqual(KeyboardContentDock.resolve("left"), .left)
        XCTAssertEqual(KeyboardContentDock.resolve("right"), .right)
        XCTAssertEqual(KeyboardContentDock.allCases, [.left, .center, .right])
    }

    func testPhoneSizedSurfacesStayFullWidthForEveryDockAndCap() {
        for width in [0.0, 1, 320, 375, 600] {
            for cap in [nil, 444.0, 520.0] {
                for dock in KeyboardContentDock.allCases {
                    let plan = KeyboardWideContentPolicy.plan(
                        panelWidth: width, maximumContentWidth: cap, dock: dock)
                    XCTAssertEqual(plan, .inactive(panelWidth: width), "width \(width) cap \(String(describing: cap))")
                    XCTAssertEqual(plan.contentWidth, width)
                    XCTAssertEqual(plan.leadingInset, 0)
                    XCTAssertEqual(plan.trailingInset, 0)
                }
            }
        }
    }

    func testSurfaceAboveThresholdActivatesAtTheCap() {
        for width in [600.1, 744.0, 834, 1024, 1366] {
            for cap in [444.0, 520.0] {
                for dock in KeyboardContentDock.allCases {
                    let plan = KeyboardWideContentPolicy.plan(
                        panelWidth: width, maximumContentWidth: cap, dock: dock)
                    XCTAssertTrue(plan.active, "width \(width) cap \(cap)")
                    XCTAssertEqual(plan.contentWidth, cap, accuracy: 0.001)
                    XCTAssertEqual(
                        plan.contentWidth + plan.leadingInset + plan.trailingInset, width,
                        accuracy: 0.001)
                    XCTAssertGreaterThanOrEqual(plan.leadingInset, 0)
                    XCTAssertGreaterThanOrEqual(plan.trailingInset, 0)
                    XCTAssertTrue(plan.contentWidth.isFinite)
                    XCTAssertTrue(plan.leadingInset.isFinite)
                    XCTAssertTrue(plan.trailingInset.isFinite)
                }
            }
        }
    }

    func testDockingPlacesTheCappedContentAtEachEdge() {
        let width = 834.0
        let cap = 520.0
        let left = KeyboardWideContentPolicy.plan(
            panelWidth: width, maximumContentWidth: cap, dock: .left)
        XCTAssertEqual(left.leadingInset, 0, accuracy: 0.001)
        XCTAssertEqual(left.trailingInset, width - cap, accuracy: 0.001)

        let right = KeyboardWideContentPolicy.plan(
            panelWidth: width, maximumContentWidth: cap, dock: .right)
        XCTAssertEqual(right.leadingInset, width - cap, accuracy: 0.001)
        XCTAssertEqual(right.trailingInset, 0, accuracy: 0.001)

        let center = KeyboardWideContentPolicy.plan(
            panelWidth: width, maximumContentWidth: cap, dock: .center)
        XCTAssertEqual(center.leadingInset, (width - cap) / 2, accuracy: 0.001)
        XCTAssertEqual(center.trailingInset, (width - cap) / 2, accuracy: 0.001)

        // Odd leftover pixels stay split within half a point and still tile exactly.
        let odd = KeyboardWideContentPolicy.plan(
            panelWidth: 833, maximumContentWidth: 444, dock: .center)
        XCTAssertEqual(odd.contentWidth, 444, accuracy: 0.001)
        XCTAssertLessThanOrEqual(abs(odd.leadingInset - odd.trailingInset), 0.5)
        XCTAssertEqual(
            odd.contentWidth + odd.leadingInset + odd.trailingInset, 833, accuracy: 0.001)
    }

    func testMissingOrOversizedCapStaysFullWidth() {
        for width in [602.0, 744, 834, 1366] {
            for cap in [nil, width, width + 1, 0, -1, .nan, .infinity] {
                let plan = KeyboardWideContentPolicy.plan(
                    panelWidth: width, maximumContentWidth: cap, dock: .center)
                XCTAssertEqual(plan, .inactive(panelWidth: width), "width \(width) cap \(String(describing: cap))")
                XCTAssertEqual(plan.contentWidth, width)
                XCTAssertEqual(plan.leadingInset, 0)
                XCTAssertEqual(plan.trailingInset, 0)
            }
        }
    }

    func testUncappedLayoutsKeepFullWidthAtEverySurface() {
        for width in [320.0, 600, 602, 834, 1024, 1366] {
            let plan = KeyboardWideContentPolicy.plan(
                panelWidth: width, maximumContentWidth: nil, dock: .center)
            XCTAssertEqual(plan, .inactive(panelWidth: width), "width \(width)")
            XCTAssertEqual(plan.contentWidth, width)
        }
    }

    func testMalformedPanelWidthsNormalizeToFiniteFullWidth() {
        for width in [Double.nan, .infinity, -.infinity, -1, -0.5] {
            let plan = KeyboardWideContentPolicy.plan(
                panelWidth: width, maximumContentWidth: 444, dock: .left)
            XCTAssertFalse(plan.active)
            XCTAssertEqual(plan.contentWidth, 0)
            XCTAssertEqual(plan.leadingInset, 0)
            XCTAssertEqual(plan.trailingInset, 0)
            XCTAssertTrue(plan.contentWidth.isFinite)
            XCTAssertTrue(plan.leadingInset.isFinite)
            XCTAssertTrue(plan.trailingInset.isFinite)
        }
        XCTAssertEqual(KeyboardWideContentPlan.inactive(panelWidth: .nan), .inactive(panelWidth: 0))
    }

    func testOneHandAndWideContentRangesNeverOverlap() {
        for width in stride(from: 300.0, through: 1200.0, by: 1.0) {
            let oneHand = KeyboardOneHandLayoutPolicy.plan(
                mode: .left, panelWidth: width, isAvailable: true)
            let wide = KeyboardWideContentPolicy.plan(
                panelWidth: width, maximumContentWidth: 520, dock: .center)
            XCTAssertFalse(oneHand.active && wide.active, "width \(width)")
            if width > KeyboardSurfaceWidth.phoneMaximum {
                XCTAssertFalse(oneHand.active, "width \(width)")
            } else {
                XCTAssertFalse(wide.active, "width \(width)")
            }
        }
    }

    func testEveryWideTilingIsRealFramesNotScaling() {
        for width in stride(from: 601.0, through: 1100.0, by: 7.0) {
            for cap in [444.0, 520.0] {
                let plan = KeyboardWideContentPolicy.plan(
                    panelWidth: width, maximumContentWidth: cap, dock: .right)
                XCTAssertTrue(plan.active)
                XCTAssertEqual(plan.contentWidth, cap, accuracy: 0.001)
                XCTAssertEqual(
                    plan.contentWidth + plan.leadingInset + plan.trailingInset, width,
                    accuracy: 0.001)
                XCTAssertGreaterThan(plan.leadingInset, 0)
            }
        }
    }
}
