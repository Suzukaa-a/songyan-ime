import KeyboardCore
import SwiftUI
import XCTest

@testable import CandidateKit

/// Contract tests for the candidate top bar's fixed surface.
///
/// The idle dark band and the occlusion with candidates have **different root causes**, so this file asserts only
/// provable contracts:
///  - idle: the pixel color equals the SkinKit dark `panel`; it is the normal drawing of the fixed header +
///    `panelBody` padding (an empty top bar), not content overflowing;
///  - with candidates: the candidate block must stay inside the budget and fully visible (not clipped).
///
/// Asserted: fixed height, real z order, the candidate block fully visible within the budget, and pixel layering of
/// the production-equivalent container.
final class CandidateHeaderSurfaceTests: XCTestCase {

    private let layouts: [CandidateHeaderLayout] = [.qwerty26, .phone14, .phone18, .phone9]

    // MARK: Render harness (real pixels, offscreen)

    /// Renders a view into a real pixel buffer (`ImageRenderer`, independent of windows/simulators).
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
            let cs = CGColorSpaceCreateDeviceRGB()
            guard
                let ctx = CGContext(
                    data: &buf, width: w, height: h, bitsPerComponent: 8,
                    bytesPerRow: w * 4, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            draw(ctx)
            result = (w, h, buf)
        }
        let rendered = try XCTUnwrap(result, "ImageRenderer must produce pixels")
        return (rendered.0, rendered.1, rendered.2)
    }

    @MainActor
    private func pixel(_ r: (w: Int, h: Int, buf: [UInt8]), x: Int, y: Int) -> (Int, Int, Int) {
        // Confirmed by measurement: bitmap row 0 == the view top (SwiftUI draw already flips), so y is the view's downward coordinate.
        // Rounding/out-of-range clamping: ImageRenderer's actual size may be smaller than the proposal (shorter content),
        // so sampling must not leave the buffer (explicit height assertions exist in the tests).
        let cx = min(max(0, x), r.w - 1)
        let cy = min(max(0, y), r.h - 1)
        let i = (cy * r.w + cx) * 4
        return (Int(r.buf[i]), Int(r.buf[i + 1]), Int(r.buf[i + 2]))
    }

    /// Horizontal luminance contrast (real glyph energy): compute the row mean, then the mean absolute deviation.
    @MainActor
    private func rowSpread(_ r: (w: Int, h: Int, buf: [UInt8]), y: Int) -> Int {
        var lums: [Int] = []
        lums.reserveCapacity(r.w)
        var sum = 0
        for x in 0..<r.w {
            let (rr, gg, bb) = pixel(r, x: x, y: y)
            let lum = (rr * 299 + gg * 587 + bb * 114) / 1000
            lums.append(lum)
            sum += lum
        }
        let mean = sum / max(1, r.w)
        return lums.reduce(0) { $0 + abs($1 - mean) } / max(1, r.w)
    }

    /// Brightest pixel luminance within a row (to decide that candidate text was really drawn).
    @MainActor
    private func rowMaxLuminance(_ r: (w: Int, h: Int, buf: [UInt8]), y: Int) -> Int {
        var hi = 0
        for x in 0..<r.w {
            let (rr, gg, bb) = pixel(r, x: x, y: y)
            hi = max(hi, (rr * 299 + gg * 587 + bb * 114) / 1000)
        }
        return hi
    }

    /// Brightest pixel luminance within a vertical band: not tied to a "magic row"; as long as candidate text falls in the band
    /// the text is judged clearly visible. Used for stable assertions when the candidate block height varies with content.
    @MainActor
    private func bandMaxLuminance(_ r: (w: Int, h: Int, buf: [UInt8]), rows: Range<Int>) -> Int {
        var hi = 0
        for y in rows where y >= 0 && y < r.h {
            hi = max(hi, rowMaxLuminance(r, y: y))
        }
        return hi
    }

    // MARK: A. Layout x state matrix (a real composition without candidates is not disguised as idle)

    /// Idle (no candidates/no status) is the `.idle` **content kind** on 26/14/9; the fixed budget is always kept,
    /// and `.idle` means the bar draws nothing of its own, not that the top bar does not exist.
    func testIdleContentKindForEveryLayout() {
        for layout in layouts {
            XCTAssertEqual(
                CandidateHeaderSurfacePolicy.content(
                    layout: layout, isEnglish: false, isComposing: false,
                    hasCandidates: false, hasStatus: false, isExpanded: false), .idle)
        }
    }

    /// After a partial commit the engine may still hold raw code without candidates: the fixed budget shows the real state,
    /// which must not be treated as fully idle, and the front end must not fabricate candidates.
    func testComposingWithEmptyCandidatesReportsRealCompositionState() {
        for layout in layouts {
            XCTAssertEqual(
                CandidateHeaderSurfacePolicy.content(
                    layout: layout, isEnglish: false, isComposing: true,
                    hasCandidates: false, hasStatus: false, isExpanded: false), .compositionWithoutCandidates)
        }
    }

    /// Only real candidates make candidate content; expanding only changes the kind; no candidates + status = status; candidates + status = candidates.
    func testCandidatesGateIsCandidatesNotEmptyNotComposing() {
        for layout in layouts {
            XCTAssertEqual(
                CandidateHeaderSurfacePolicy.content(
                    layout: layout, isEnglish: false, isComposing: true,
                    hasCandidates: true, hasStatus: false, isExpanded: false), .candidates)
            XCTAssertEqual(
                CandidateHeaderSurfacePolicy.content(
                    layout: layout, isEnglish: false, isComposing: true,
                    hasCandidates: true, hasStatus: false, isExpanded: true), .candidatesExpanded)
            XCTAssertEqual(
                CandidateHeaderSurfacePolicy.content(
                    layout: layout, isEnglish: false, isComposing: true,
                    hasCandidates: false, hasStatus: true, isExpanded: false), .status)
            XCTAssertEqual(
                CandidateHeaderSurfacePolicy.content(
                    layout: layout, isEnglish: false, isComposing: true,
                    hasCandidates: true, hasStatus: true, isExpanded: false), .candidates)
        }
    }

    func testEnglishIdleContentKindIsIdle() {
        for layout in layouts {
            XCTAssertEqual(
                CandidateHeaderSurfacePolicy.content(
                    layout: layout, isEnglish: true, isComposing: false,
                    hasCandidates: false, hasStatus: false, isExpanded: false), .idle)
            XCTAssertEqual(
                CandidateHeaderSurfacePolicy.content(
                    layout: layout, isEnglish: true, isComposing: true,
                    hasCandidates: true, hasStatus: false, isExpanded: false), .candidates)
            XCTAssertEqual(
                CandidateHeaderSurfacePolicy.content(
                    layout: layout, isEnglish: true, isComposing: true,
                    hasCandidates: true, hasStatus: true, isExpanded: true), .candidatesExpanded)
        }
    }

    /// `CandidateHeaderLayout` is what **production** branches on: 26 has no disambiguation entry, 9/14 do; 9 uses the phone shell.
    func testLayoutFamiliesDriveRealProductionDifferences() {
        XCTAssertFalse(CandidateHeaderLayout.qwerty26.offersAmbiguityPicker)
        XCTAssertTrue(CandidateHeaderLayout.phone14.offersAmbiguityPicker)
        XCTAssertTrue(CandidateHeaderLayout.phone18.offersAmbiguityPicker)
        XCTAssertFalse(CandidateHeaderLayout.phone18.usesPhoneShell)
        XCTAssertEqual(CandidateHeaderLayout(layout: .merged18), .phone18)
        XCTAssertTrue(CandidateHeaderLayout.phone9.offersAmbiguityPicker)
        XCTAssertTrue(CandidateHeaderLayout.phone9.usesPhoneShell)
        XCTAssertFalse(CandidateHeaderLayout.phone14.usesPhoneShell)
        for kind in KeyboardLayoutKind.allCases {
            _ = CandidateHeaderLayout(layout: kind)  // every built-in layout maps without crashing.
        }
    }

    // MARK: B. Visual constraints + real z order (rendered pixels)

    /// Visual constraint + real rendering: candidate text must be fully opaque (alpha = 255) and clearly brighter than the backing.
    /// Not just a constant assertion: verified on real pixels that no translucency/material/fade affects it.
    @MainActor
    func testNormalCandidateTextRendersFullyOpaque() throws {
        XCTAssertTrue(CandidateHeaderSurfacePolicy.forbidsBlurMaterialOpacityForNormalCandidates)
        let backing = Color(red: 0.145, green: 0.153, blue: 0.173)
        let view = CandidateHeaderSurface(height: 44, backing: backing) {
            Text("你好").font(.system(size: 22)).foregroundStyle(.white)
        }
        .frame(width: 200)
        let r = try render(view, width: 200, height: 44)
        // Find the brightest glyph pixel and assert its alpha and luminance: fully opaque, near pure white.
        var bestLum = 0
        var bestAlpha = 0
        for y in 0..<r.h {
            for x in 0..<r.w {
                let i = (y * r.w + x) * 4
                let lum = (Int(r.buf[i]) * 299 + Int(r.buf[i + 1]) * 587 + Int(r.buf[i + 2]) * 114) / 1000
                if lum > bestLum {
                    bestLum = lum
                    bestAlpha = Int(r.buf[i + 3])
                }
            }
        }
        XCTAssertEqual(bestAlpha, 255, "normal candidate text must be fully opaque (no opacity/material/fade)")
        XCTAssertGreaterThan(bestLum, 200, "normal candidate text must be sharp (near pure white), measured \(bestLum)")
    }

    /// The z order is **really applied**: background < content, and in the rendered result the candidate text is drawn
    /// above the backing (the content layer is visible).
    @MainActor
    func testZOrderIsAppliedAndContentDrawsAboveBacking() throws {
        XCTAssertLessThan(
            CandidateHeaderSurfacePolicy.zIndex(.background),
            CandidateHeaderSurfacePolicy.zIndex(.content))
        let backing = Color(red: 0.14, green: 0.15, blue: 0.17)
        let view = CandidateHeaderSurface(height: 44, backing: backing) {
            Text("你好").font(.system(size: 21)).foregroundStyle(.white)
        }
        .frame(width: 200)
        let r = try render(view, width: 200, height: 44)
        // The top bar must contain candidate text pixels clearly brighter than the backing.
        var bright = 0
        for y in 0..<r.h {
            for x in 0..<r.w {
                let (rr, gg, bb) = pixel(r, x: x, y: y)
                if rr > 200 && gg > 200 && bb > 200 { bright += 1 }
            }
        }
        XCTAssertGreaterThan(
            bright, 20, "candidate text must be drawn above the backing and not swallowed by the background")
    }

    // MARK: C. Fixed height + content fitting (not clipping the text)

    func testSurfaceHeightAlwaysEqualsEffectiveBudget() {
        for configured in [36.0, 44.0, 50.0, 56.0, 60.0, 12.0, .infinity, .nan] {
            XCTAssertEqual(
                CandidateHeaderSurfacePolicy.surfaceHeight(configured: configured),
                CandidateBarDefinition.Collapsed.effectiveHeight(configured))
        }
    }

    /// The collapsed state's vertical fitting **only clamps the layout box and never scales**: a whole-block `scaleEffect`
    /// triggers offscreen resampling and turns candidates into a blurry smear. Within the effective appearance range the primary candidate block always equals the original block height.
    func testCollapsedBlockHeightFitsBudgetWithoutScaling() {
        // Within the budget: the block height is kept as-is.
        XCTAssertEqual(
            CandidateCollapsedFlow.fittedBlockHeight(blockHeight: 30, budget: 44),
            30, accuracy: 0.001, "a block within the budget must not change height")
        // Extreme block height: clamped to the budget, with no scaling API involved (scaleEffect is structurally forbidden).
        XCTAssertEqual(
            CandidateCollapsedFlow.fittedBlockHeight(blockHeight: 88, budget: 44),
            44, accuracy: 0.001)
        XCTAssertEqual(
            CandidateCollapsedFlow.fittedBlockHeight(blockHeight: 88, budget: 0),
            88, accuracy: 0.001, "a degenerate budget must not produce a 0/NaN block height")

        for candidateSize in stride(from: 16.0, through: 30.0, by: 1) {
            for secondarySize in stride(from: 10.0, through: 16.0, by: 1) {
                // Production budget = max(config value, primary font line height, 36pt base height).
                for configured in stride(from: 36.0, through: 56.0, by: 1) {
                    let budget = CandidateBarDefinition.Collapsed.effectiveHeight(
                        configured, candidateSize: candidateSize)
                    let typography = CandidateTypography(
                        candidateSize: candidateSize,
                        secondarySize: secondarySize)
                    // The collapsed state keeps only the primary candidate (no comment): within the real budget it must fit **at the original size**
                    // in full, so scaling is never needed (fitted == original block height).
                    let main = CandidateCollapsedFlow.estimatedBlockHeight(
                        typography: typography, hasComment: false)
                    XCTAssertLessThanOrEqual(
                        main, budget,
                        "the primary candidate block must be complete within the effective budget (not shrunk, not clipped)"
                            + " size=\(candidateSize) budget=\(budget)")
                    XCTAssertEqual(
                        CandidateCollapsedFlow.fittedBlockHeight(
                            blockHeight: main, budget: budget), main, accuracy: 0.001,
                        "the primary candidate block must not be clamped smaller within the real budget")
                    // A taller comment block is still only clamped, never scaled (the collapsed state does not show comments).
                    let withComment = CandidateCollapsedFlow.estimatedBlockHeight(
                        typography: typography, hasComment: true)
                    XCTAssertGreaterThan(withComment, main)
                    XCTAssertLessThanOrEqual(
                        CandidateCollapsedFlow.fittedBlockHeight(
                            blockHeight: withComment, budget: budget), budget)
                }
            }
        }
    }

    /// Real SwiftUI: different content always gives a 36 surface height.
    @MainActor
    func testMeasuredSurfaceHeightIsFixedAcrossContent() throws {
        let tall = String(repeating: "汉", count: 40)
        let cases: [(String, AnyView)] = [
            (
                "idle",
                AnyView(
                    CandidateHeaderSurface(height: 36, backing: .black) {
                        Color.clear.frame(width: 44, height: 44)
                    })
            ),
            (
                "tallCandidates",
                AnyView(
                    CandidateHeaderSurface(height: 36, backing: .black) {
                        VStack(spacing: 0) {
                            Text(tall).font(.system(size: 21)).lineLimit(1)
                            Text(tall).font(.system(size: 10)).lineLimit(1)
                            Text(tall).font(.system(size: 10)).lineLimit(1)
                        }.frame(minHeight: 120)
                    })
            ),
            (
                "status",
                AnyView(
                    CandidateHeaderSurface(height: 36, backing: .black) {
                        Text("操作未完成").frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
                    })
            ),
        ]
        for (name, view) in cases {
            let r = try render(view, width: 402, height: 900)
            XCTAssertEqual(r.h, 36, "\(name): the fixed surface height must always be 36")
        }
    }

    // MARK: D. Production-equivalent container: header + first key row (pixel layering)

    /// Production-equivalent container: a complete panel skeleton **driven by `KeyboardPanelLayoutPlan`**
    /// (header / main area / control row / `contentTop` above + 4 padding below), isomorphic to `KeyboardPanelView.panelBody`.
    /// The first key row sits at the top of `mainAreaFrame`; the control row sits in `controlRowFrame`.
    /// The candidate row reuses the real `CandidateCollapsedFlow`.
    private struct HeaderThenFirstKeyRow: View {
        let layout: CandidateHeaderLayout
        let contentKind: CandidateHeaderContent
        let keyCount: Int
        var showsComment = false
        var statusEntry = false

        private var panel: Color { Color(red: 0.145, green: 0.153, blue: 0.173) }  // #25272C
        private var key: Color { Color(red: 0.267, green: 0.278, blue: 0.306) }  // #44474E
        private var control: Color { Color(red: 0.212, green: 0.239, blue: 0.278) }

        /// Lets tests inject a custom candidate height (first-frame stability cases); defaults to the production 44.
        var candidateHeight: Double = 44
        /// Fixture candidate height (explicit 44pt baseline), portrait keyHeight 54, three main rows.
        private var geometry: KeyboardPanelGeometry {
            KeyboardPanelGeometry(candidateHeight: candidateHeight, keyHeight: 54, selectedMainRows: 3)
        }
        /// The production plan is **always** the fixed budget including the header (same entry as `KeyboardPanelView.layoutPlan`):
        /// idle and candidates have the same height and only the bar's drawing changes.
        private var plan: KeyboardPanelLayoutPlan {
            geometry.layoutPlan(showsHeader: true)
        }

        private var entries: [BrowserCandidate] {
            ["你好世界", "您好", "你"].enumerated().map { index, text in
                BrowserCandidate(
                    pageIndex: 0, pageLocalIndex: index,
                    candidate: Candidate(
                        index: index, text: text,
                        comment: showsComment ? "cháng zhùshì" : ""))
            }
        }

        var body: some View {
            VStack(spacing: 0) {
                // The fixed candidate budget is always kept (as in production): idle also draws a surface, leaving no blank band.
                CandidateHeaderSurface(height: plan.headerHeight, backing: panel) {
                    headerContent
                }
                .frame(height: plan.headerFrame.height)
                // Main area: the first key row sits at its top; the whole area height = mainAreaFrame.height.
                VStack(spacing: 0) {
                    HStack(spacing: 4) {
                        ForEach(0..<keyCount, id: \.self) { _ in key }
                    }
                    .frame(height: 54)
                    Spacer(minLength: 0)
                }
                .frame(height: plan.mainAreaFrame.height, alignment: .top)
                // Control row: placed in the control row frame (spacing comes from a production constant).
                Color.clear.frame(height: KeyboardPanelGeometry.controlSpacing)
                HStack(spacing: 4) {
                    ForEach(0..<4, id: \.self) { _ in control }
                }
                .frame(height: plan.controlRowFrame.height)
            }
            .background(panel)
            .frame(width: 402)
            // Same top/bottom padding as production `panelBody`: with a candidate area the top padding is
            // `plan.contentTop` (0) and the bottom padding is still `verticalPadding`.
            .padding(.top, CGFloat(plan.contentTop))
            .padding(.bottom, KeyboardPanelGeometry.verticalPadding)
        }

        /// Full skeleton rendered height == the production fixed panel height (same for idle and candidates).
        var expectedHeight: Int {
            Int(plan.panelHeight)
        }

        @ViewBuilder private var headerContent: some View {
            let typography = CandidateTypography(candidateSize: 21, secondarySize: 10)
            switch contentKind {
            case .idle:
                // Production idle: **draws no content** (no fake description bar, no tools entry).
                // The fixed budget is still kept (geometry unchanged); under the system default the backing is transparent.
                Color.clear
            case .compositionWithoutCandidates:
                Text("当前输入暂无候选").font(.footnote).padding(.horizontal, 8)
            case .status:
                Text("操作未完成").font(.footnote).padding(.horizontal, 8)
            case .candidates, .candidatesExpanded:
                HStack(spacing: 0) {
                    if layout.offersAmbiguityPicker { Text("拼音组合").font(.system(size: 11)) }
                    CollapsedStrip(entries: entries, bar: .systemDefault, typography: typography)
                    Spacer(minLength: 0)
                    if statusEntry { Text("!").frame(width: 44, height: CGFloat(plan.headerHeight)) }
                }
            }
        }
    }

    /// The minimal renderable collapsed strip, **isomorphic to production `DefaultCollapsedCandidateBar`**: it keeps only
    /// the primary candidate and underline, the layout box is clamped into the budget by the shared `CandidateCollapsedFlow`, and **no
    /// whole-block `scaleEffect`** is applied (production and test must share a structure, otherwise the test would hide a blur regression).
    private struct CollapsedStrip: View {
        let entries: [BrowserCandidate]
        let bar: CandidateBarDefinition
        let typography: CandidateTypography

        var body: some View {
            let layout = CandidateCollapsedFlow.layout(
                entries: entries, collapsed: bar.collapsed,
                typography: typography, availableWidth: 380)
            let budget = CGFloat(
                CandidateBarDefinition.Collapsed.effectiveHeight(
                    bar.collapsed.height, candidateSize: typography.candidateSize))
            let blockHeight = CandidateCollapsedFlow.fittedBlockHeight(
                blockHeight: CandidateCollapsedFlow.estimatedBlockHeight(
                    typography: typography, hasComment: false),
                budget: budget)
            HStack(spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    let rawWidth = layout.cellWidths.indices.contains(index) ? layout.cellWidths[index] : 44
                    let padX = min(bar.collapsed.cellPaddingX, max(4, (rawWidth - 40) / 2))
                    VStack(spacing: 1) {
                        Text(entry.text).font(.system(size: typography.candidateSize)).lineLimit(1)
                        Capsule().fill(.white.opacity(0.65)).frame(width: 18, height: 2)
                    }
                    .foregroundStyle(.white)
                    .frame(height: blockHeight)
                    .padding(.horizontal, padX)
                    .frame(width: rawWidth)
                    .frame(minHeight: budget)
                }
            }
        }
    }

    /// Production-equivalent: the header backing never extends into the first key row's top area.
    @MainActor
    func testHeaderBackingNeverExtendsIntoFirstKeyRow() throws {
        // Header state (with content): the first key row top must land exactly on `plan.firstKeyRowTop`.
        let geometry = KeyboardPanelGeometry(candidateHeight: 44, keyHeight: 54, selectedMainRows: 3)
        let plan = geometry.layoutPlan(showsHeader: true)
        for kind in [CandidateHeaderContent.candidates, .status] {
            let view = HeaderThenFirstKeyRow(layout: .qwerty26, contentKind: kind, keyCount: 6)
            let r = try render(view, width: 402, height: 98)
            // Key row center ys derive from the production plan (firstKeyRowTop + half key height); the key color is asserted per key.
            let keyCenters = (0..<6).map { Int(CGFloat($0) * 402 / 6 + 402 / 12) }
            let keyRowTop = Int(plan.firstKeyRowTop)
            for y in [keyRowTop + 4, keyRowTop + 26, keyRowTop + 50] {
                for x in keyCenters {
                    let (rr, gg, bb) = pixel(r, x: x, y: y)
                    XCTAssertGreaterThan(
                        rr + gg + bb, 150,
                        "\(kind): first key row (y=\(y),x=\(x)) must not be covered by the header/backing dark layer, measured \(rr),\(gg),\(bb)"
                    )
                }
            }
            let keyFraction = rowFractionBrighterThan(r, y: keyRowTop + 26, luminance: 55)
            XCTAssertGreaterThan(
                keyFraction, 0.8,
                "\(kind): the key row must be dominated by the key color, not panel-only")
        }
    }

    /// Idle (26/9/14): the production fixed budget still keeps the header band (geometry matches input states, so the
    /// key area does not jump), but idle **draws no content**: no fake description bar, no tools entry, and the first
    /// key row top is not covered by an overflowing layer. Uses the production `showsHeader: true` plan to rule out false greens from a non-production plan.
    @MainActor
    func testIdleHeaderDrawsNoContentWithoutCoveringFirstKeyRow() throws {
        let geometry = KeyboardPanelGeometry(candidateHeight: 44, keyHeight: 54, selectedMainRows: 3)
        let plan = geometry.layoutPlan(showsHeader: true)
        for layout in [CandidateHeaderLayout.qwerty26, .phone9, .phone14] {
            let view = HeaderThenFirstKeyRow(layout: layout, contentKind: .idle, keyCount: 6)
            let r = try render(view, width: 402, height: 98)
            // Production fixed budget: idle also fills the header band (the shell height does not change with state).
            XCTAssertEqual(
                plan.headerHeight, 44,
                "\(layout) idle must share the production source: the fixed header budget, not 0")
            XCTAssertEqual(plan.headerFrame.maxY, plan.firstKeyRowTop, accuracy: 0.001)
            // Idle draws no content: the header band has only the backing color, no readable text/glyph energy.
            let backingLum = (37 * 299 + 39 * 587 + 44 * 114) / 1000
            let textY = Int(plan.headerFrame.minY) + 22
            XCTAssertLessThanOrEqual(
                rowMaxLuminance(r, y: textY), backingLum + 20,
                "\(layout) idle must not fake a description bar (it should be pure backing)")
            XCTAssertLessThan(
                rowSpread(r, y: textY), 6,
                "\(layout) idle must have no glyph energy")
            // The first key row top must still be the key color (the header does not overflow and cover keys).
            let keyFraction = rowFractionBrighterThan(
                r, y: Int(plan.firstKeyRowTop) + 4,
                luminance: 55)
            XCTAssertGreaterThan(
                keyFraction, 0.8,
                "\(layout) idle first key row must be visible, measured fraction \(keyFraction)")
        }
    }

    /// **Production-equivalent skeleton** matrix (26 / 9 / 14 x idle / candidates): uses `HeaderThenFirstKeyRow`
    /// to mirror the `panelBody` geometry; it is **not** a real `KeyboardPanelView` instance. It asserts
    ///  - the rendered height always equals the production fixed panel height (same for idle and candidates; content does not change geometry);
    ///  - the header height always equals the fixed budget (idle is no longer content but is still a fixed band);
    ///  - the idle band is pure backing (no fake description bar) and the candidate state has the renderer's placeholder text;
    ///  - the first key row top is not covered by a dark/opacity/material layer in either state.
    /// Real keyboard candidate visibility is covered by GUI testing, not claimed here.
    @MainActor
    func testProductionEquivalentMatrix() throws {
        let geometry = KeyboardPanelGeometry(candidateHeight: 44, keyHeight: 54, selectedMainRows: 3)
        let fixedPlan = geometry.layoutPlan(showsHeader: true)
        let cases: [(String, CandidateHeaderLayout, CandidateHeaderContent, Bool)] = [
            ("26-idle", .qwerty26, .idle, false),
            ("9-idle", .phone9, .idle, false),
            ("14-idle", .phone14, .idle, false),
            ("14-candidates", .phone14, .candidates, true),
            ("9-candidates", .phone9, .candidates, true),
            ("26-candidates", .qwerty26, .candidates, true),
        ]
        let keyCenters = (0..<6).map { Int(CGFloat($0) * 402 / 6 + 402 / 12) }
        let backingLum = (37 * 299 + 39 * 587 + 44 * 114) / 1000
        for (name, layout, kind, wantsText) in cases {
            let view = HeaderThenFirstKeyRow(
                layout: layout, contentKind: kind,
                keyCount: 6, showsComment: true,
                statusEntry: true)
            let r = try render(view, width: 402, height: 98)
            XCTAssertEqual(
                r.h, view.expectedHeight,
                "\(name): the rendered height must equal the height derived from the production plan")
            XCTAssertEqual(
                fixedPlan.headerHeight, 44,
                "\(name): the header height must come from the production fixed plan")
            XCTAssertEqual(
                view.expectedHeight, Int(fixedPlan.panelHeight),
                "\(name): idle and candidates must have the same height (content does not change geometry)")
            // The first key row top (the production plan value) must be the key color and not covered by any dark/translucent layer.
            let keyTop = Int(fixedPlan.firstKeyRowTop) + 2
            for x in keyCenters {
                let (rr, gg, bb) = pixel(r, x: x, y: keyTop)
                XCTAssertGreaterThan(
                    rr + gg + bb, 150,
                    "\(name): first key row top (y=\(keyTop)) is covered, measured \(rr),\(gg),\(bb)")
            }
            if wantsText {
                // The candidate state must draw **readable content** inside the fixed header.
                XCTAssertGreaterThan(
                    rowMaxLuminance(r, y: Int(fixedPlan.headerFrame.minY) + 14),
                    backingLum + 80,
                    "\(name): candidate text must be clearly visible (not backing-only)")
            } else {
                // The idle band is pure backing: no fake description bar.
                XCTAssertLessThanOrEqual(
                    rowMaxLuminance(r, y: Int(fixedPlan.headerFrame.minY) + 22),
                    backingLum + 20,
                    "\(name): idle must not fake a description bar (it should be pure backing)")
            }
        }
    }

    /// Single geometry owner: the candidate surface height, the budget above the key area and the production fixed plan share **one source**:
    /// `surfaceHeight == plan.headerHeight`, and `plan.headerHeight` is exactly the difference between the fixed height and
    /// the base height plus the top padding the candidate area omits (`verticalPadding - candidateTopPadding`). So the candidate bar and key area never share a pixel row under any config/size class.
    func testHeaderSurfaceHeightIsTheSingleBudgetSharedWithThePanelPlan() {
        for candidateHeight in [36.0, 40.0, 44.0, 50.0, 56.0, 60.0] {
            for keyHeight in [44.0, 54.0] {
                let geometry = KeyboardPanelGeometry(
                    candidateHeight: candidateHeight,
                    keyHeight: keyHeight, selectedMainRows: 3)
                let plan = geometry.layoutPlan(showsHeader: true)
                XCTAssertEqual(
                    plan.headerHeight,
                    CandidateHeaderSurfacePolicy.surfaceHeight(configured: candidateHeight),
                    accuracy: 0.001,
                    "\(candidateHeight): the surface height must equal the plan's header budget")
                XCTAssertEqual(
                    plan.headerHeight,
                    KeyboardPanelGeometry.fixedPanelHeight(
                        candidateHeight: candidateHeight,
                        keyHeight: keyHeight)
                        - geometry.basePanelHeight
                        + KeyboardPanelGeometry.verticalPadding
                        - KeyboardPanelGeometry.candidateTopPadding,
                    accuracy: 0.001,
                    "\(candidateHeight): the header budget must be the difference between the fixed height and the base height (plus the omitted top padding)"
                )
                XCTAssertEqual(
                    plan.firstKeyRowTop,
                    KeyboardPanelGeometry.candidateTopPadding + plan.headerHeight,
                    accuracy: 0.001)
            }
        }
    }

    /// Real rendering: the surface height is **identical** with candidate content and empty content, and equals the plan's header budget in both;
    /// content never crosses the surface's bottom edge (the first key row top).
    @MainActor
    func testSurfaceRendersAtPlanHeaderHeightForEmptyAndCandidateContent() throws {
        let plan = KeyboardPanelGeometry(candidateHeight: 44, keyHeight: 54, selectedMainRows: 3)
            .layoutPlan(showsHeader: true)
        let tall = String(repeating: "汉", count: 60)
        let cases: [(String, AnyView)] = [
            (
                "empty",
                AnyView(
                    CandidateHeaderSurface(height: 44, backing: .black) {
                        Color.clear
                    })
            ),
            (
                "candidates",
                AnyView(
                    CandidateHeaderSurface(height: 44, backing: .black) {
                        Text(tall).font(.system(size: 21)).lineLimit(1)
                            .frame(width: 402, height: 200, alignment: .leading)
                    })
            ),
        ]
        for (name, view) in cases {
            let r = try render(view, width: 402, height: 900)
            XCTAssertEqual(r.h, Int(plan.headerHeight), "\(name): the surface height must equal the plan budget")
        }
    }

    /// **Production-equivalent skeleton** regression (26/14/9): `HeaderThenFirstKeyRow` mirrors
    /// the geometry and candidate content assembly of `KeyboardPanelView.panelBody`, but is **not** a real
    /// `KeyboardPanelView` instance (the app sources are not in this test target). This case therefore proves only
    /// the skeleton geometry contract and does **not** claim real keyboard candidates are verified:
    ///  - the idle band is pure backing (no fake description bar) and has the same height as the candidate state;
    ///  - the collapsed candidate strip's text is visible (placeholder candidate text here, not real engine candidates);
    ///  - the outer height is identical when expanded/collapsed;
    ///  - with a custom candidate height idle and candidates still have the same height, equal to the production fixed entry.
    @MainActor
    func testProductionEquivalentSkeletonIdleCandidatesAndExpandCollapse() throws {
        let backingLum = (37 * 299 + 39 * 587 + 44 * 114) / 1000
        for (name, layout) in [
            ("26", CandidateHeaderLayout.qwerty26),
            ("14", .phone14), ("9", .phone9),
        ] {
            // Expanded / collapsed: different content kinds, identical geometry.
            let collapsed = HeaderThenFirstKeyRow(
                layout: layout, contentKind: .candidates,
                keyCount: 6, showsComment: true)
            let expanded = HeaderThenFirstKeyRow(
                layout: layout, contentKind: .candidatesExpanded,
                keyCount: 6, showsComment: true)
            XCTAssertEqual(
                collapsed.expectedHeight, expanded.expectedHeight,
                "\(name): the outer height when expanded and collapsed must be the same")
            let rc = try render(collapsed, width: 402, height: 98)
            let re = try render(expanded, width: 402, height: 98)
            XCTAssertEqual(rc.h, re.h, "\(name): the rendered height when expanded/collapsed must be the same")
            // The collapsed candidate strip text must be visible (not backing-only); it uses the renderer's placeholder text.
            // Scan the whole header budget band (not tied to a magic row): the collapsed state no longer scales/shows comments,
            // and the primary candidate is centered in the budget, so the assertion checks the whole band for sharp glyphs.
            let plan = KeyboardPanelGeometry(candidateHeight: 44, keyHeight: 54, selectedMainRows: 3)
                .layoutPlan(showsHeader: true)
            let headerBand = Int(plan.headerFrame.minY)..<Int(plan.headerFrame.maxY)
            XCTAssertGreaterThan(
                bandMaxLuminance(rc, rows: headerBand), backingLum + 80,
                "\(name): collapsed candidate text must be clearly visible")
            // The idle band is pure backing (no fake description bar) and has the same height as the candidate state.
            let idle = HeaderThenFirstKeyRow(layout: layout, contentKind: .idle, keyCount: 6)
            let ri = try render(idle, width: 402, height: 98)
            XCTAssertLessThanOrEqual(
                rowMaxLuminance(ri, y: 22), backingLum + 20,
                "\(name): idle must not fake a description bar (it should be pure backing)")
            XCTAssertEqual(ri.h, rc.h, "\(name): idle and the candidate state must have the same height")

            // Custom candidate height: idle and candidates still have the same height, equal to the production fixed entry.
            let customIdle = HeaderThenFirstKeyRow(
                layout: layout, contentKind: .idle,
                keyCount: 6, candidateHeight: 56)
            let customCandidates = HeaderThenFirstKeyRow(
                layout: layout, contentKind: .candidates,
                keyCount: 6, candidateHeight: 56)
            let fixed56 = KeyboardPanelGeometry.fixedPanelHeight(candidateHeight: 56, keyHeight: 54)
            XCTAssertEqual(
                customIdle.expectedHeight, customCandidates.expectedHeight,
                "\(name): idle and candidates still have the same height under a custom candidate height")
            XCTAssertEqual(
                Double(customIdle.expectedHeight), fixed56, accuracy: 1,
                "\(name): a custom candidate height must go through the production fixed entry, with no magic numbers")
        }
    }

    /// Fraction of pixels in a row brighter than the threshold (0...1).
    @MainActor
    private func rowFractionBrighterThan(
        _ r: (w: Int, h: Int, buf: [UInt8]),
        y: Int, luminance: Int
    ) -> Double {
        var count = 0
        for x in 0..<r.w {
            let (rr, gg, bb) = pixel(r, x: x, y: y)
            if (rr * 299 + gg * 587 + bb * 114) / 1000 > luminance { count += 1 }
        }
        return Double(count) / Double(max(1, r.w))
    }

    /// Production-equivalent: in the candidate state the candidate text must be drawn above the backing and fall entirely inside the header's visible area.
    @MainActor
    func testCandidateTextAreaIsNotBackingOnly() throws {
        let geometry = KeyboardPanelGeometry(candidateHeight: 44, keyHeight: 54, selectedMainRows: 3)
        let plan = geometry.layoutPlan(showsHeader: true)
        let view = HeaderThenFirstKeyRow(
            layout: .phone14, contentKind: .candidates,
            keyCount: 6, showsComment: true, statusEntry: true)
        let r = try render(view, width: 402, height: 98)
        let backingLum = (37 * 299 + 39 * 587 + 44 * 114) / 1000
        // Candidate text must fall entirely inside the production header frame [minY, maxY).
        let headerRange = Int(plan.headerFrame.minY)..<Int(plan.headerFrame.maxY)
        var brightInHeader = 0
        for y in headerRange {
            for x in 0..<r.w {
                let (rr, gg, bb) = pixel(r, x: x, y: y)
                if (rr * 299 + gg * 587 + bb * 114) / 1000 > backingLum + 60 { brightInHeader += 1 }
            }
        }
        XCTAssertGreaterThan(
            brightInHeader, 40,
            "candidate text must be drawn above the backing and not clipped out of the visible area")
        // The text band (including comments) has real glyph energy inside the header and contains near-white glyph pixels.
        XCTAssertGreaterThan(
            rowSpread(r, y: headerRange.lowerBound + 14), 20,
            "the candidate text row must have real glyph energy")
        XCTAssertGreaterThan(
            rowMaxLuminance(r, y: headerRange.lowerBound + 14), backingLum + 80,
            "the candidate text row must have sharp glyph pixels (not backing-only)")
    }

    // MARK: F. Explicit 36pt surface and rendered hit regions

    @MainActor
    func testConfiguredThirtySixKeepsRendererTargetsInsideHeader() throws {
        var bar = CandidateBarDefinition.systemDefault
        bar.collapsed.height = 36
        let typography = CandidateTypography(candidateSize: 17, secondarySize: 10)
        XCTAssertEqual(CandidateBarDefinition.Collapsed.effectiveHeight(36), 36)
        XCTAssertEqual(CandidateHeaderSurfacePolicy.surfaceHeight(configured: 36), 36)
        XCTAssertEqual(bar.collapsedHeightBudget, 36)

        let plan = KeyboardPanelGeometry(candidateHeight: 36, keyHeight: 54, selectedMainRows: 3)
            .layoutPlan(showsHeader: true)
        XCTAssertEqual(plan.headerHeight, 36)

        let state = CandidatePresentationState(
            candidates: [Candidate(index: 0, text: "候选")], isComposing: true)
        let context = CandidateAreaContext(
            state: state, bar: bar,
            actions: CandidateAreaActionSink { _ in },
            typography: typography)
        let surface = CandidateHeaderSurface(height: plan.headerHeight, backing: .black) {
            DefaultCandidateAreaRenderer().collapsedView(context: context)
        }.frame(width: 120)
        let rendered = try render(surface, width: 120, height: 80)
        XCTAssertEqual(rendered.h, 36, "with an explicit 36pt config and a normal font size the surface stays 36pt")

        let largeHeader = CandidateHeaderSurfacePolicy.surfaceHeight(configured: 36, candidateSize: 30)
        XCTAssertEqual(largeHeader, 41)
        let largePlan = KeyboardPanelGeometry(
            candidateHeight: 36, keyHeight: 54,
            selectedMainRows: 3, candidateSize: 30
        )
        .layoutPlan(showsHeader: true)
        XCTAssertEqual(largePlan.headerHeight, largeHeader)
        let largeContext = CandidateAreaContext(
            state: state, bar: bar,
            actions: CandidateAreaActionSink { _ in },
            typography: CandidateTypography(
                candidateSize: 30,
                secondarySize: 10))
        let largeSurface = CandidateHeaderSurface(height: 36, candidateSize: 30, backing: .black) {
            DefaultCandidateAreaRenderer().collapsedView(context: largeContext)
        }.frame(width: 120)
        XCTAssertEqual(
            try render(largeSurface, width: 120, height: 80).h, 41,
            "the height needed for a larger candidate font size must fully fit the header budget")
    }
}
