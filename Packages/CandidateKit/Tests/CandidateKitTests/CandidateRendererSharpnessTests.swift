import KeyboardCore
import SwiftUI
import XCTest

@testable import CandidateKit

/// Sharpness / no-blur contract of the **shared** candidate rendering path (across 26/14/9, independent of layout).
///
/// Candidate text squeezed into a fixed height with a whole-block `scaleEffect` (offscreen resampling) turns the
/// whole row into a blurry smear. The default `CandidateKit` renderer is shared by 26/14/9 and every state
/// (collapsed, expanded, paging/loading, comments/readings, before/after selection, Chinese/English toggling), so
/// this file uses **real pixels** (`ImageRenderer`) to assert that candidate text is fully opaque and has glyph
/// energy, covering every layout family and every candidate state. It does not replace on-device visual acceptance.
final class CandidateRendererSharpnessTests: XCTestCase {

    // MARK: Render harness

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

    private func makeContext(
        _ candidates: [Candidate], highlighted: Int,
        expanded: Bool, browser: CandidateBrowser = CandidateBrowser(),
        bar: CandidateBarDefinition = .systemDefault
    ) -> CandidateAreaContext {
        let state = CandidatePresentationState(
            preedit: "ni hao", rawInput: "nihao",
            candidates: candidates, highlightedIndex: highlighted,
            pageIndex: 0, canPageBackward: false, canPageForward: true,
            isComposing: true)
        return CandidateAreaContext(
            state: state, bar: bar,
            actions: CandidateAreaActionSink { _ in },
            typography: CandidateTypography(candidateSize: 20, secondarySize: 10),
            browser: browser, isExpanded: expanded)
    }

    /// Wraps the real renderer output with production skin values (dark panel + white candidates).
    private func skinned(_ view: AnyView, width: CGFloat, height: CGFloat) -> some View {
        view
            .frame(width: width, height: height)
            .environment(
                \.candidateSkinToken,
                CandidateSkinToken(
                    candidateColor: .white, secondaryColor: Color.white.opacity(0.8),
                    accentColor: .blue, panelColor: .black)
            )
            .background(Color.black)
    }

    /// Candidate text sharpness: the image has both opaque glyph pixels near pure white (255) and enough
    /// glyph energy (row contrast); blur or masking lowers the brightest pixels and flattens contrast.
    private func assertTextIsSharp(_ r: (w: Int, h: Int, buf: [UInt8]), label: String) throws {
        var maxLum = 0
        var bright = 0
        for y in 0..<r.h {
            for x in 0..<r.w {
                let i = (y * r.w + x) * 4
                let lum = (Int(r.buf[i]) * 299 + Int(r.buf[i + 1]) * 587 + Int(r.buf[i + 2]) * 114) / 1000
                if lum > maxLum { maxLum = lum }
                if lum > 200 { bright += 1 }
            }
        }
        XCTAssertGreaterThan(maxLum, 235, "\(label): candidate text must have sharp glyph pixels near pure white")
        XCTAssertGreaterThan(bright, 12, "\(label): candidate text must have enough glyph energy (not just background)")
    }

    /// Fully opaque: the brightest glyph pixel's alpha must be 255 (no opacity/material/fade).
    private func assertTextIsOpaque(_ r: (w: Int, h: Int, buf: [UInt8]), label: String) throws {
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
        XCTAssertEqual(bestAlpha, 255, "\(label): candidate text must be fully opaque (no translucency/material/mask)")
    }

    // MARK: Layout x state coverage (26 / 14 / 9 share one renderer)

    private func sampleCandidates(comment: Bool, count: Int = 5) -> [Candidate] {
        let texts = ["你好", "您好", "你好世界", "你", "尼奥", "你呢", "拟好", "泥"]
        return (0..<count).map { index in
            Candidate(
                index: index, text: texts[index % texts.count],
                comment: comment ? "nǐ hǎo \(index)" : "")
        }
    }

    /// Collapsed: 26/14/9 with comments / highlight / long candidates must be sharp, opaque and unscaled.
    @MainActor
    func testCollapsedCandidatesRenderSharpForEveryLayoutFamily() throws {
        for layout in CandidateHeaderLayout.allCases {
            for comment in [false, true] {
                for highlighted in [0, 2] {
                    let context = makeContext(
                        sampleCandidates(comment: comment),
                        highlighted: highlighted, expanded: false)
                    let view = skinned(
                        AnyView(DefaultCandidateAreaRenderer().collapsedView(context: context)),
                        width: 380, height: 44)
                    let r = try render(view, width: 380, height: 44)
                    let label = "collapsed \(layout) comment=\(comment) highlight=\(highlighted)"
                    try assertTextIsSharp(r, label: label)
                    try assertTextIsOpaque(r, label: label)
                }
            }
        }
    }

    /// Expanded: 26/14/9, list/grid/adaptive, comments, selected/loading states must be sharp and opaque.
    ///
    /// This renders the **same view production uses**, `ExpandedCandidateRows` (production's `ScrollView` is only its
    /// scroll container): `ImageRenderer` cannot rasterize `ScrollView` content offscreen, but the row content itself
    /// is identical to production, so this covers the real expanded cell layout.
    @MainActor
    func testExpandedCandidatesRenderSharpForEveryLayoutFamilyAndState() throws {
        var list = CandidateBarDefinition.systemDefault
        list.expanded.mode = .list
        var grid = CandidateBarDefinition.systemDefault
        grid.expanded.mode = .grid
        let bars = [("adaptive", CandidateBarDefinition.systemDefault), ("list", list), ("grid", grid)]
        for layout in CandidateHeaderLayout.allCases {
            for (barName, bar) in bars {
                for comment in [false, true] {
                    let context = makeContext(
                        sampleCandidates(comment: comment, count: 8),
                        highlighted: 0, expanded: true, bar: bar)
                    let view = skinned(
                        AnyView(
                            ExpandedCandidateRows(
                                context: context, availableWidth: 376, rowHeight: 44)),
                        width: 380, height: 180)
                    let r = try render(view, width: 380, height: 180)
                    let label = "expanded \(layout) \(barName) comment=\(comment)"
                    try assertTextIsSharp(r, label: label)
                    try assertTextIsOpaque(r, label: label)
                }
            }
        }
    }

    /// Loading state (the browser has more pages): the tail sentinel/loading controls must not blur or mask real candidates.
    @MainActor
    func testExpandedLoadingStateKeepsCandidatesSharp() throws {
        let candidates = sampleCandidates(comment: true, count: 5)
        let state = CandidatePresentationState(
            preedit: "ni hao", rawInput: "nihao", candidates: candidates,
            highlightedIndex: 0, pageIndex: 0, pageSize: 5,
            canPageBackward: false, canPageForward: true, isComposing: true)
        var browser = CandidateBrowser()
        browser.reset(state)
        XCTAssertTrue(browser.hasMore, "precondition: the loading state must have unloaded pages")
        let context = CandidateAreaContext(
            state: state, bar: .systemDefault,
            actions: CandidateAreaActionSink { _ in },
            typography: .init(candidateSize: 20, secondarySize: 10),
            browser: browser, isExpanded: true)
        let view = skinned(
            AnyView(
                ExpandedCandidateRows(
                    context: context, availableWidth: 376, rowHeight: 44)),
            width: 380, height: 180)
        let r = try render(view, width: 380, height: 180)
        try assertTextIsSharp(r, label: "expanded loading")
        try assertTextIsOpaque(r, label: "expanded loading")
    }

    /// **Layout coverage**: the real built-in layouts (26 full pinyin / 26 Xiaohe / 14 / 9) go through the **same** shared
    /// renderer and the output must be pixel-identical; any per-layout special case or patch for sharpness
    /// would diverge here and be caught (the shared renderer must have no layout special cases).
    @MainActor
    func testSharedRendererOutputIsIdenticalAcrossRealLayouts() throws {
        var fingerprints: [String: [UInt8]] = [:]
        for kind in KeyboardLayoutKind.allCases {
            let state = makeContext(
                sampleCandidates(comment: true, count: 5),
                highlighted: 1, expanded: false
            ).state
            let layoutState = CandidatePresentationState(
                schemaID: state.schemaID, preedit: state.preedit, rawInput: state.rawInput,
                candidates: state.candidates, highlightedIndex: state.highlightedIndex,
                pageIndex: state.pageIndex, pageSize: state.pageSize,
                canPageBackward: false, canPageForward: true, isComposing: true,
                layout: String(describing: kind))
            let context = CandidateAreaContext(
                state: layoutState, bar: .systemDefault,
                actions: CandidateAreaActionSink { _ in },
                typography: .init(candidateSize: 20, secondarySize: 10))
            let view = skinned(
                AnyView(DefaultCandidateAreaRenderer().collapsedView(context: context)),
                width: 380, height: 44)
            fingerprints[String(describing: kind)] = try render(view, width: 380, height: 44).buf
        }
        let reference = try XCTUnwrap(fingerprints.values.first)
        XCTAssertEqual(
            Set(fingerprints.keys).count, KeyboardLayoutKind.allCases.count,
            "must cover all real layouts")
        for (layout, buffer) in fingerprints {
            XCTAssertEqual(
                buffer, reference,
                "\(layout): the shared renderer must match the other layouts pixel for pixel (no layout special cases)")
        }
    }

    @MainActor
    func testCollapsedOverflowRowRendersEveryCandidateSharpAndOpaque() throws {
        let texts = ["你好", "您好", "你好世界", "你", "尼奥", "你呢", "拟好", "泥"]
        for count in [6, 12] {
            let candidates = (0..<count).map {
                Candidate(index: $0, text: texts[$0 % texts.count], comment: "nǐ hǎo \($0)")
            }
            let state = CandidatePresentationState(
                preedit: "ni hao", rawInput: "nihao", candidates: candidates,
                highlightedIndex: 0, pageIndex: 0, canPageBackward: false,
                canPageForward: true, isComposing: true)
            var browser = CandidateBrowser()
            browser.reset(state)
            let context = CandidateAreaContext(
                state: state, bar: .systemDefault,
                actions: CandidateAreaActionSink { _ in },
                typography: .init(candidateSize: 20, secondarySize: 10),
                browser: browser, isExpanded: false)
            let entries = context.displayEntries
            let layout = CandidateCollapsedFlow.layout(
                entries: entries, collapsed: CandidateBarDefinition.systemDefault.collapsed,
                typography: context.typography, availableWidth: 372,
                fillsAvailableWidth: false)
            XCTAssertTrue(layout.scrolls, "count=\(count) must cover the real overflow state")

            let view = CollapsedCandidateRow(
                context: context, entries: entries,
                cellWidths: layout.cellWidths, spacing: 0
            )
            .frame(height: 44)
            .environment(
                \.candidateSkinToken,
                CandidateSkinToken(
                    candidateColor: .white, secondaryColor: Color.white.opacity(0.8),
                    accentColor: .blue, panelColor: .black)
            )
            .background(Color.black)
            let total = max(1, Int(layout.cellWidths.reduce(0, +).rounded(.up)))
            let r = try render(view, width: CGFloat(total), height: 44)
            try assertTextIsSharp(r, label: "collapsed overflow count=\(count)")
            try assertTextIsOpaque(r, label: "collapsed overflow count=\(count)")

            let firstCellRight = Int(layout.cellWidths[0])
            let lastCellLeft = Int(layout.cellWidths.dropLast().reduce(0, +))
            XCTAssertGreaterThan(brightColumns(r, in: 0..<min(firstCellRight, r.w)), 0)
            XCTAssertGreaterThan(brightColumns(r, in: min(lastCellLeft, r.w)..<r.w), 0)
        }
    }

    private func brightColumns(_ r: (w: Int, h: Int, buf: [UInt8]), in xs: Range<Int>) -> Int {
        var count = 0
        for y in 0..<r.h {
            for x in xs where x >= 0 && x < r.w {
                let i = (y * r.w + x) * 4
                let lum = (Int(r.buf[i]) * 299 + Int(r.buf[i + 1]) * 587 + Int(r.buf[i + 2]) * 114) / 1000
                if lum > 200 { count += 1 }
            }
        }
        return count
    }
}
