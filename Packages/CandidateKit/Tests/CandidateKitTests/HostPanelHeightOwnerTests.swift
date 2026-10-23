import KeyboardCore
import SwiftUI
import XCTest

@testable import CandidateKit

/// Contract: the panel height has a **single owner**.
///
/// The host computes the one outer height with the same `KeyboardPanelGeometry.presentationShellHeight(...)` the panel
/// uses (= the standard 26-key `fixedPanelHeight`) and constrains the content with it; all layouts/pages/phases/states use
/// that one number, and page differences only redistribute key row heights via `fittedKeyHeight`. A child must not report
/// its height back to the host (that would make the first frame `.frame(height: 0)` and lay out against the previous
/// frame's height). This file verifies:
///  - real rendering shows "budget == natural content height" and candidate state does not change the height (no clipping);
///  - the geometry plan shows the header / main area / control row meet exactly (no shared pixel row);
///  - the cold-start shell height (`KeyboardInitialPresentation`) shares the same fixed budget as ready/loading.
final class HostPanelHeightOwnerTests: XCTestCase {

    // MARK: Render harness (production-equivalent, offscreen)

    @MainActor
    private func render<V: View>(
        _ view: V, width: CGFloat,
        height: CGFloat
    ) throws -> (w: Int, h: Int, buf: [UInt8]) {
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: width, height: height)
        renderer.scale = 1
        var result: (Int, Int, [UInt8])?
        renderer.render { size, draw in
            let w = max(1, Int(size.width)), h = max(1, Int(size.height))
            var buf = [UInt8](repeating: 0, count: w * h * 4)
            guard
                let ctx = CGContext(
                    data: &buf, width: w, height: h, bitsPerComponent: 8,
                    bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            draw(ctx)
            result = (w, h, buf)
        }
        return try XCTUnwrap(result, "ImageRenderer must produce pixels")
    }

    @MainActor
    private func luminance(_ r: (w: Int, h: Int, buf: [UInt8]), x: Int, y: Int) -> Int {
        let i = (y * r.w + x) * 4
        guard i + 2 < r.buf.count else { return 0 }
        let rr = Int(r.buf[i]), gg = Int(r.buf[i + 1]), bb = Int(r.buf[i + 2])
        return (rr * 299 + gg * 587 + bb * 114) / 1000
    }

    @MainActor
    private func rowFractionBrighterThan(
        _ r: (w: Int, h: Int, buf: [UInt8]),
        y: Int, luminance threshold: Int
    ) -> Double {
        guard y >= 0, y < r.h else { return 0 }
        var count = 0
        for x in 0..<r.w where luminance(r, x: x, y: y) > threshold { count += 1 }
        return Double(count) / Double(max(1, r.w))
    }

    /// Production-equivalent skeleton: fixed candidate header + three key rows + control row + `contentTop` above / 4 padding below.
    /// `budgeted` applies the outer budget given by the host/container (`keyboardPanelHeight`);
    /// when off, the content's **natural height** is measured. Equal values mean no clipping within one transaction.
    ///
    /// `hasHeaderContent` only switches the bar **content** (candidates/status vs empty) and **does not** change the geometry:
    /// the production fixed budget keeps the same header band in both states.
    private struct OwnerProbe: View {
        let hasHeaderContent: Bool
        let budgeted: Bool
        var candidateHeight: Double = 44
        var keyHeight: Double = 54

        private var plan: KeyboardPanelLayoutPlan {
            KeyboardPanelGeometry(
                candidateHeight: candidateHeight, keyHeight: keyHeight,
                selectedMainRows: KeyboardPanelGeometry.standardMainRowCount
            )
            .layoutPlan(showsHeader: true)
        }
        private var panel: Color { Color(red: 0.145, green: 0.153, blue: 0.173) }
        private var key: Color { Color(red: 0.267, green: 0.278, blue: 0.306) }
        private var control: Color { Color(red: 0.212, green: 0.239, blue: 0.278) }

        var body: some View {
            let plan = self.plan
            let content = VStack(spacing: 0) {
                CandidateHeaderSurface(height: candidateHeight, backing: panel) {
                    if hasHeaderContent {
                        Text("你好世界").font(.system(size: 20)).foregroundStyle(.white)
                    } else {
                        Color.clear
                    }
                }
                VStack(spacing: 0) {
                    HStack(spacing: 4) { ForEach(0..<6, id: \.self) { _ in key } }
                        .frame(height: keyHeight)
                    Spacer(minLength: 0)
                }
                .frame(height: plan.mainAreaFrame.height, alignment: .top)
                Color.clear.frame(height: KeyboardPanelGeometry.controlSpacing)
                HStack(spacing: 4) { ForEach(0..<4, id: \.self) { _ in control } }
                    .frame(height: keyHeight)
            }
            .padding(.top, CGFloat(plan.contentTop))
            .padding(.bottom, KeyboardPanelGeometry.verticalPadding)
            .background(panel)
            .frame(width: 402)
            if budgeted {
                content.keyboardPanelHeight(CGFloat(plan.panelHeight))
            } else {
                content
            }
        }
    }

    /// Candidate content presence **does not change** the outer height: both states render to the same fixed budget and the
    /// header band is kept in both (the first key row top is always `candidateTopPadding + headerHeight`). Laying out against a
    /// stale budget would clip the bottom control row on a shrinking frame.
    @MainActor
    func testOwnerBudgetEqualsContentHeightAcrossCandidateStates() throws {
        let plan = KeyboardPanelGeometry(
            candidateHeight: 44, keyHeight: 54,
            selectedMainRows: KeyboardPanelGeometry.standardMainRowCount
        )
        .layoutPlan(showsHeader: true)
        let expected = Int(plan.panelHeight.rounded())
        let keyTop = Int(plan.firstKeyRowTop)
        var heights: [Int] = []
        for (name, hasContent) in [("empty", false), ("candidates", true)] {
            let budgeted = try render(
                OwnerProbe(hasHeaderContent: hasContent, budgeted: true),
                width: 402, height: 600)
            let natural = try render(
                OwnerProbe(hasHeaderContent: hasContent, budgeted: false),
                width: 402, height: 600)
            heights.append(budgeted.h)
            XCTAssertEqual(budgeted.h, expected, "\(name): the budget must equal the fixed plan height")
            XCTAssertEqual(
                natural.h, expected,
                "\(name): the natural height must equal the budget (no clipping within one transaction)")
            XCTAssertGreaterThan(budgeted.h, 0, "\(name): the first frame height is non-zero")
            // The first key row top must be visible in both states (the fixed header band protects the key area).
            XCTAssertGreaterThan(
                rowFractionBrighterThan(budgeted, y: keyTop + 4, luminance: 55), 0.8,
                "\(name): the first key row must be visible")
            // The header band must exist in both states and be the panel color (no key color bleeding in).
            XCTAssertLessThan(
                rowFractionBrighterThan(
                    budgeted, y: Int(plan.headerFrame.minY) + 2,
                    luminance: 55), 0.2,
                "\(name): the header band must be the panel color")
            // The bottom control row must be fully visible (a stale-budget layout would clip it).
            let controlY = Int(plan.controlRowFrame.minY) + 5
            XCTAssertGreaterThan(
                rowFractionBrighterThan(budgeted, y: controlY, luminance: 55), 0.8,
                "\(name): the bottom control row must be fully drawn, not clipped")
        }
        XCTAssertEqual(heights[0], heights[1], "candidate state must not change the outer height")
    }

    /// The production plan is **fixed**: the header band is always kept, and the main area/control row positions relative to
    /// the panel bottom do not depend on candidate state (host bottom-anchored). The no-header base height is only a mathematical difference.
    @MainActor
    func testFixedPlanReservesHeaderAndKeepsBandsContiguous() throws {
        let geometry = KeyboardPanelGeometry(
            candidateHeight: 44, keyHeight: 54,
            selectedMainRows: KeyboardPanelGeometry.standardMainRowCount)
        let fixed = geometry.layoutPlan(showsHeader: true)
        let base = geometry.layoutPlan(showsHeader: false)
        XCTAssertEqual(fixed.headerHeight, geometry.headerHeight, "the fixed plan must keep the header")
        XCTAssertEqual(
            fixed.panelHeight - base.panelHeight,
            geometry.headerHeight - KeyboardPanelGeometry.verticalPadding
                + KeyboardPanelGeometry.candidateTopPadding, accuracy: 0.001,
            "the difference between with-header and base height must be exactly one header minus the omitted top padding"
        )
        XCTAssertEqual(
            KeyboardPanelGeometry.fixedPanelHeight(candidateHeight: 44, keyHeight: 54),
            fixed.panelHeight, accuracy: 0.001,
            "the entry shared by host and panel must equal the fixed plan")
        XCTAssertTrue(
            fixed.bandsAreContiguous, "header / main area / control row must meet exactly without overlapping")
        XCTAssertFalse(fixed.headerFrame.intersects(fixed.mainAreaFrame))
        XCTAssertFalse(fixed.mainAreaFrame.intersects(fixed.controlRowFrame))
        XCTAssertEqual(
            fixed.firstKeyRowTop,
            KeyboardPanelGeometry.candidateTopPadding + geometry.headerHeight, accuracy: 0.001,
            "the first key row top must sit exactly below the header (no shared pixel row)")
    }

    /// Cold-start shell height contract: `KeyboardInitialPresentation.shellHeight` shares the same
    /// `presentationShellHeight` (= the selected definition's `fixedPanelHeight`) with the host, so the first `loadView`
    /// frame == every phase == ready, with no header height jump.
    func testColdStartShellHeightEqualsTheFixedProductionPlan() throws {
        let base = KeyboardPanelGeometry.idlePanelHeight(candidateHeight: 44, keyHeight: 54)
        let fixed = KeyboardPanelGeometry.fixedPanelHeight(candidateHeight: 44, keyHeight: 54)
        XCTAssertEqual(base, 236, accuracy: 0.01, "base height without header (mathematical difference only)")
        XCTAssertEqual(fixed, 276, accuracy: 0.01, "fixed production height")
        XCTAssertEqual(
            fixed - base, 40, accuracy: 0.01,
            "the difference is exactly one header (44) minus the 4pt top padding the candidate area omits")
        XCTAssertEqual(
            KeyboardPanelGeometry.presentationShellHeight(candidateHeight: 44, keyHeight: 54, readingRow: true),
            KeyboardPanelGeometry.fixedPanelHeight(
                candidateHeight: 44, keyHeight: 54,
                readingRowReserved: true)
                + KeyboardPanelGeometry.candidateAreaBonus - KeyboardPanelGeometry.readingLayoutBonusCut,
            accuracy: 0.01, "the 14-key shell == the reading-row page's fixed production height + candidate area bonus")
        XCTAssertEqual(
            KeyboardPanelGeometry.presentationShellHeight(candidateHeight: 44, keyHeight: 54, readingRow: false),
            KeyboardPanelGeometry.fixedPanelHeight(candidateHeight: 44, keyHeight: 54)
                + KeyboardPanelGeometry.candidateAreaBonus,
            accuracy: 0.01, "the 26/9-key shell == its standard fixed production height + candidate area bonus")
    }

    /// All phases (including cold start) share one shell height: the fixed and no-header heights stay distinct and the
    /// fixed plan matches the full panel height.
    func testEveryPhaseSharesOneShellHeight() throws {
        for keyHeight in [44.0, 54.0] {
            let fixed = KeyboardPanelGeometry.fixedPanelHeight(candidateHeight: 44, keyHeight: keyHeight)
            XCTAssertEqual(
                fixed,
                KeyboardPanelGeometry.panelHeight(
                    candidateHeight: 44, keyHeight: keyHeight,
                    showsHeader: true),
                accuracy: 0.001)
            XCTAssertNotEqual(
                fixed,
                KeyboardPanelGeometry.idlePanelHeight(candidateHeight: 44, keyHeight: keyHeight),
                "the fixed shell height must not fall back to the header-less base height")
        }
    }
}
