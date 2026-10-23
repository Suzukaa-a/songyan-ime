import KeyboardCore
import SwiftUI
import XCTest

@testable import CandidateKit

/// Focused contract for candidate touch feedback, expanded list bounds and scroll reset.
///
/// The pixel cases use macOS `ImageRenderer` to verify the **drawing structure** (press fill beneath the glyphs, inset within the hit region,
/// glyph opacity/luminance unchanged, candidates in a row not misaligned by comments); they are **not** UIKit on-device touch acceptance:
/// `UIScrollView` delayed touches, real press timing and VoiceOver/Voice Control still need confirming on a device.
final class CandidateTouchFeedbackTests: XCTestCase {

    // MARK: Geometry and strength (pure values)

    func testPressBackingStaysInsideEveryHitHeight() {
        XCTAssertEqual(
            CandidateTouchMetrics.pillHeight(hitHeight: 44), 36,
            "default 44pt word row: 36pt pill, keeping the full hit region")
        XCTAssertEqual(
            CandidateTouchMetrics.pillHeight(hitHeight: 36), 28,
            "36pt reading row: 28pt pill, not intruding on the adjacent word row")
        for hit in [36.0, 40, 44, 47.5, 56] as [CGFloat] {
            let pill = CandidateTouchMetrics.pillHeight(hitHeight: hit)
            XCTAssertGreaterThan(pill, 0)
            XCTAssertEqual(
                pill + CandidateTouchMetrics.verticalInset * 2, hit, accuracy: 0.0001,
                "\(hit)pt: the pill leaves \(CandidateTouchMetrics.verticalInset)pt above and below and never exceeds the hit region"
            )
        }
        XCTAssertEqual(CandidateTouchMetrics.pillHeight(hitHeight: .nan), 0)
        XCTAssertEqual(CandidateTouchMetrics.pillHeight(hitHeight: -1), 0)
        XCTAssertEqual(CandidateTouchMetrics.pillHeight(hitHeight: 4), 0)
    }

    func testControlChipCoincidesWithItsPressBackingInsideThe44ptTarget() {
        let inset = CandidateTouchMetrics.controlHorizontalInset
        XCTAssertEqual(
            CandidateTouchMetrics.controlChipWidth + inset * 2,
            CandidateTouchMetrics.controlHitWidth, accuracy: 0.0001)
        XCTAssertEqual(
            CandidateTouchMetrics.controlHitWidth, 44, "the control hit width stays at the minimum touch width")
    }

    func testPressAndIndicatorStrengthFollowIncreasedContrast() {
        XCTAssertEqual(
            CandidateTouchMetrics.pressedOpacity(increasedContrast: false),
            KeyboardPressPhysics.overlayOpacity, "candidate press strength shares the key cap's darkening amount")
        XCTAssertGreaterThan(
            CandidateTouchMetrics.pressedOpacity(increasedContrast: true),
            CandidateTouchMetrics.pressedOpacity(increasedContrast: false))
        XCTAssertLessThanOrEqual(
            CandidateTouchMetrics.pressedOpacity(increasedContrast: true), 0.3,
            "still a faint fill under Increase Contrast, never darkening the glyphs")
        XCTAssertEqual(CandidateTouchMetrics.indicatorOpacity(increasedContrast: true), 1)
        XCTAssertLessThan(CandidateTouchMetrics.indicatorOpacity(increasedContrast: false), 1)
    }

    func testPressIsImmediateAndReleaseRespectsReduceMotion() {
        XCTAssertNil(
            CandidateTouchMetrics.highlightAnimation(pressed: true, reduceMotion: false),
            "appears immediately on press (same touch-down contract as key caps)")
        XCTAssertNil(CandidateTouchMetrics.highlightAnimation(pressed: true, reduceMotion: true))
        XCTAssertNil(
            CandidateTouchMetrics.highlightAnimation(pressed: false, reduceMotion: true),
            "Reduce Motion: disappears immediately on release")
        XCTAssertNotNil(
            CandidateTouchMetrics.highlightAnimation(pressed: false, reduceMotion: false),
            "by default release follows the shared release timing")
    }

    // MARK: Expanded viewport (single bottom inset + whole rows + pixel alignment)

    func testExpandedViewportHasOneBottomInsetAndWholePixelAlignedRows() {
        for total in [120.0, 162, 180, 206.5, 240] as [CGFloat] {
            let viewport = CandidateExpandedFlow.viewportHeight(totalHeight: total)
            XCTAssertEqual(
                viewport + CandidateExpandedFlow.bottomInset, total, accuracy: 0.0001,
                "the bottom inset is counted once (outside the viewport)")
            let rowArea = CandidateExpandedFlow.rowAreaHeight(totalHeight: total)
            XCTAssertEqual(rowArea + CandidateExpandedFlow.topInset, viewport, accuracy: 0.0001)
            for spacing in [0.0, 4] as [CGFloat] {
                for scale in [2.0, 3] as [CGFloat] {
                    let row = CandidateExpandedFlow.fittedRowHeight(
                        rowAreaHeight: rowArea, spacing: spacing,
                        displayScale: scale)
                    let count = floor((rowArea + spacing) / (44 + spacing))
                    let content = CandidateExpandedFlow.topInset + count * row + (count - 1) * spacing
                    let label = "total=\(total) spacing=\(spacing) @\(scale)x"
                    XCTAssertGreaterThanOrEqual(row, 44, "\(label): every row keeps the minimum touch height")
                    XCTAssertEqual(
                        row * scale, (row * scale).rounded(), accuracy: 0.0001,
                        "\(label): the row height lands on device pixels")
                    XCTAssertLessThanOrEqual(
                        content, viewport + 0.0001,
                        "\(label): the sum of whole rows that fit does not exceed the viewport (no extra draggable slack)"
                    )
                    XCTAssertLessThan(
                        viewport - content, count / scale + 0.0001,
                        "\(label): slack is under one pixel per row (no half row showing)")
                }
            }
        }
        XCTAssertEqual(CandidateExpandedFlow.fittedRowHeight(rowAreaHeight: 20, spacing: 0, displayScale: 3), 44)
        XCTAssertEqual(CandidateExpandedFlow.fittedRowHeight(rowAreaHeight: .nan, spacing: 0, displayScale: 3), 44)
        XCTAssertEqual(CandidateExpandedFlow.viewportHeight(totalHeight: .infinity), 0)
        XCTAssertEqual(CandidateExpandedFlow.rowAreaHeight(totalHeight: 4), 0)
    }

    // MARK: Scroll reset identity

    private func state(
        raw: String, texts: [String], page: Int = 0, revision: Int,
        canBackward: Bool = false
    ) -> CandidatePresentationState {
        CandidatePresentationState(
            schemaID: "s", preedit: raw, rawInput: raw,
            candidates: texts.enumerated().map { Candidate(index: $0.offset, text: $0.element) },
            highlightedIndex: 0, pageIndex: page, pageSize: 2,
            canPageBackward: canBackward, canPageForward: true, isComposing: true, revision: revision)
    }

    private func context(
        _ state: CandidatePresentationState, browser: CandidateBrowser,
        visible: [BrowserCandidate]? = nil
    ) -> CandidateAreaContext {
        CandidateAreaContext(
            state: state, bar: .systemDefault, actions: CandidateAreaActionSink { _ in },
            typography: .init(candidateSize: 20, secondarySize: 11),
            browser: browser, isExpanded: false, visibleEntries: visible)
    }

    private func visible(_ texts: [String], pages: [Int]) -> [BrowserCandidate] {
        zip(texts, pages).map { text, page in
            BrowserCandidate(
                pageIndex: page, pageLocalIndex: 0,
                candidate: Candidate(index: 0, text: text, comment: "reading"))
        }
    }

    func testScrollIdentitySurvivesReadOnlyLoadingButResetsForANewComposition() {
        let first = state(raw: "ni", texts: ["你", "尼"], revision: 1)
        var browser = CandidateBrowser()
        browser.reset(first)
        let initial = context(first, browser: browser).scrollIdentity

        XCTAssertTrue(
            browser.append(
                pageIndex: 1,
                candidates: [
                    Candidate(index: 0, text: "泥"),
                    Candidate(index: 1, text: "拟"),
                ], pageSize: 2))
        XCTAssertEqual(
            context(first, browser: browser).scrollIdentity, initial,
            "scroll appends within one composition must not pull the user back to the start")

        let typed = state(raw: "nih", texts: ["你好", "你还"], revision: 2)
        browser.reset(typed)
        XCTAssertNotEqual(
            context(typed, browser: browser).scrollIdentity, initial,
            "a new composition returns to the first candidate instead of reusing the old offset")

        let refreshed = state(raw: "ni", texts: ["你", "尼"], revision: 3)
        var sameRaw = CandidateBrowser()
        sameRaw.reset(refreshed)
        XCTAssertNotEqual(
            context(refreshed, browser: sameRaw).scrollIdentity, initial,
            "the same code with a changed real engine state (revision) also resets")
    }

    func testScrollIdentityIgnoresEarlierPagePrepend() {
        let anchored = state(raw: "ni", texts: ["丙", "丁"], page: 1, revision: 4, canBackward: true)
        var browser = CandidateBrowser()
        browser.reset(anchored)
        XCTAssertTrue(browser.needsEarlier)
        let before = context(anchored, browser: browser).scrollIdentity
        XCTAssertTrue(
            browser.append(
                pageIndex: 0,
                candidates: [
                    Candidate(index: 0, text: "甲"),
                    Candidate(index: 1, text: "乙"),
                ], pageSize: 2))
        XCTAssertEqual(
            browser.entries.first?.text, "甲", "precondition: filling the earlier page did change the first entry")
        XCTAssertEqual(
            context(anchored, browser: browser).scrollIdentity, before,
            "filling earlier pages is a read-only append within the same composition and does not reset (avoids being pulled back mid-scroll)"
        )
    }

    func testScrollIdentityResetsWhenTheReadingFilterChangesNotWhenItAppends() {
        let composing = state(raw: "64", texts: ["你", "尼"], revision: 5)
        var browser = CandidateBrowser()
        browser.reset(composing)
        let unfiltered = context(composing, browser: browser).scrollIdentity
        let readingA = context(composing, browser: browser, visible: visible(["你", "拟"], pages: [0, 3]))
        let readingAMore = context(composing, browser: browser, visible: visible(["你", "拟", "腻"], pages: [0, 3, 4]))
        let readingB = context(composing, browser: browser, visible: visible(["米", "迷"], pages: [2, 5]))

        XCTAssertNotEqual(readingA.scrollIdentity, unfiltered, "turning on the reading filter returns to the start")
        XCTAssertEqual(readingAMore.scrollIdentity, readingA.scrollIdentity, "appending filter results does not reset")
        XCTAssertNotEqual(
            readingB.scrollIdentity, readingA.scrollIdentity, "switching to another reading returns to the start")
        XCTAssertEqual(
            context(composing, browser: browser).scrollIdentity, unfiltered,
            "clearing the filter returns to the unfiltered identity")
    }

    // MARK: Pixels: the press fill sits beneath the glyphs, inset, glyphs unchanged

    @MainActor
    private func render<V: View>(
        _ view: V, width: CGFloat,
        height: CGFloat?
    ) throws -> (w: Int, h: Int, buf: [UInt8]) {
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: width, height: height)
        renderer.scale = 1
        var result: (Int, Int, [UInt8])?
        renderer.render { size, draw in
            let w = max(1, Int(size.width.rounded(.up))), h = max(1, Int(size.height.rounded(.up)))
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
        let rendered = try XCTUnwrap(result, "ImageRenderer must produce pixels")
        return (rendered.0, rendered.1, rendered.2)
    }

    private func luminance(_ r: (w: Int, h: Int, buf: [UInt8]), _ x: Int, _ y: Int) -> Int {
        let i = (y * r.w + x) * 4
        return (Int(r.buf[i]) * 299 + Int(r.buf[i + 1]) * 587 + Int(r.buf[i + 2]) * 114) / 1000
    }

    /// (brightest pixel luminance, its alpha).
    private func brightest(_ r: (w: Int, h: Int, buf: [UInt8])) -> (lum: Int, alpha: Int) {
        var best = (lum: 0, alpha: 0)
        for y in 0..<r.h {
            for x in 0..<r.w {
                let lum = luminance(r, x, y)
                if lum > best.lum { best = (lum, Int(r.buf[(y * r.w + x) * 4 + 3])) }
            }
        }
        return best
    }

    @MainActor
    private func pressProbe(pressed: Bool, height: CGFloat = 36) throws -> (w: Int, h: Int, buf: [UInt8]) {
        let view = Text("你")
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(Color.white)
            .frame(width: 80, height: height)
            .candidatePressHighlight(isPressed: pressed, tint: .white)
            .background(Color.black)
        return try render(view, width: 80, height: height)
    }

    @MainActor
    func testPressBackingIsAnInsetFillUnderOpaqueUnchangedGlyphs() throws {
        let idle = try pressProbe(pressed: false)
        let pressed = try pressProbe(pressed: true)
        XCTAssertEqual(idle.w, 80)
        XCTAssertEqual(pressed.h, 36)

        // Interior, glyph-free pixel (the glyph is centred around x≈40).
        XCTAssertEqual(luminance(idle, 6, 18), 0, "not pressed: no fill at all")
        let fill = luminance(pressed, 6, 18)
        XCTAssertTrue(
            (20...45).contains(fill),
            "pressed: the faint fill is visible (about 12% of the candidate foreground), actual \(fill)")
        // Outside the inset backing: top/bottom 4pt band and the 1pt side inset stay untouched.
        for (x, y) in [(6, 1), (6, 34), (0, 18), (79, 18)] {
            XCTAssertEqual(
                luminance(pressed, x, y), 0, "(\(x),\(y)): the press fill must be inset within the hit region")
        }

        let idleGlyph = brightest(idle)
        let pressedGlyph = brightest(pressed)
        XCTAssertGreaterThan(idleGlyph.lum, 235, "precondition: the probe does have sharp glyphs")
        XCTAssertEqual(
            pressedGlyph.lum, idleGlyph.lum, "pressing must not change glyph luminance (no darkening, no overlay)")
        XCTAssertEqual(pressedGlyph.alpha, 255, "candidate glyphs stay fully opaque while pressed")
    }

    @MainActor
    func testDefaultWordRowPressBackingFits44ptWithoutDimmingGlyph() throws {
        let idle = try pressProbe(pressed: false, height: 44)
        let pressed = try pressProbe(pressed: true, height: 44)
        XCTAssertEqual(pressed.h, 44)
        XCTAssertEqual(luminance(idle, 6, 22), 0)
        XCTAssertTrue((20...45).contains(luminance(pressed, 6, 22)))
        for (x, y) in [(6, 1), (6, 42), (0, 22), (79, 22)] {
            XCTAssertEqual(luminance(pressed, x, y), 0, "the press fill in a 44pt top bar must not touch the boundary")
        }
        XCTAssertEqual(brightest(pressed).lum, brightest(idle).lum)
        XCTAssertEqual(brightest(pressed).alpha, 255)
    }

    // MARK: Pixels: candidates in one row are not misaligned or stretched by the presence of comments

    private func expandedContext(_ candidates: [Candidate], bar: CandidateBarDefinition) -> CandidateAreaContext {
        let state = CandidatePresentationState(
            preedit: "ni", rawInput: "ni", candidates: candidates, highlightedIndex: 0,
            pageIndex: 0, canPageBackward: false, canPageForward: false, isComposing: true)
        return CandidateAreaContext(
            state: state, bar: bar, actions: CandidateAreaActionSink { _ in },
            typography: .init(candidateSize: 20, secondarySize: 11),
            isExpanded: true)
    }

    @MainActor
    private func expandedRow(
        _ candidates: [Candidate],
        bar: CandidateBarDefinition
    ) throws -> (w: Int, h: Int, buf: [UInt8]) {
        let view = ExpandedCandidateRows(
            context: expandedContext(candidates, bar: bar),
            availableWidth: 376, rowHeight: 44
        )
        .environment(
            \.candidateSkinToken,
            CandidateSkinToken(
                candidateColor: .white, secondaryColor: Color.white.opacity(0.6),
                accentColor: .blue, panelColor: .black)
        )
        .background(Color.black)
        return try render(view, width: 376, height: nil)
    }

    /// Top-most bright (candidate glyph) row within `xs`.
    private func glyphTop(_ r: (w: Int, h: Int, buf: [UInt8]), xs: Range<Int>) -> Int? {
        for y in 0..<r.h where xs.contains(where: { luminance(r, $0, y) > 200 }) { return y }
        return nil
    }

    @MainActor
    func testMixedCommentRowKeepsOneHeightAndOneTextLine() throws {
        var grid = CandidateBarDefinition.systemDefault
        grid.expanded.mode = .grid
        for (name, bar) in [("adaptive", CandidateBarDefinition.systemDefault), ("grid", grid)] {
            let withComment = Candidate(index: 0, text: "你好", comment: "nǐ hǎo")
            let plain = Candidate(index: 1, text: "您好")
            let mixed = try expandedRow([withComment, plain], bar: bar)
            let allComments = try expandedRow(
                [withComment, Candidate(index: 1, text: "您好", comment: "nín hǎo")],
                bar: bar)
            XCTAssertEqual(
                mixed.h, allComments.h,
                "\(name): with one commented and one uncommented cell, the row height must not grow from baseline misalignment"
            )

            let widths: [Int]
            if bar.expanded.isAdaptive {
                let rows = CandidateExpandedFlow.layout(
                    entries: [withComment, plain].map {
                        BrowserCandidate(
                            pageIndex: 0, pageLocalIndex: $0.index,
                            candidate: $0)
                    },
                    expanded: bar.expanded, typography: .init(candidateSize: 20, secondarySize: 11),
                    cellPaddingX: bar.collapsed.cellPaddingX, availableWidth: 376)
                XCTAssertEqual(rows.count, 1, "precondition: two short candidates share one row")
                widths = rows[0].widths.map { Int($0) }
            } else {
                widths = [188, 188]
            }
            let first = try XCTUnwrap(glyphTop(mixed, xs: 0..<widths[0]))
            let second = try XCTUnwrap(glyphTop(mixed, xs: widths[0]..<(widths[0] + widths[1])))
            XCTAssertLessThanOrEqual(abs(first - second), 1, "\(name): candidate text in one row sits on one line")
        }
    }
}
