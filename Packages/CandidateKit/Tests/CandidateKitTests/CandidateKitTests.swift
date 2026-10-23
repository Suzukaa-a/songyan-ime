import KeyboardCore
import SwiftUI
import XCTest

@testable import CandidateKit

final class CandidateKitTests: XCTestCase {
    func testDefaultsAndStrictDecode() throws {
        let bar = try CandidateBarDefinition.decode(
            Data(##"{"formatVersion":1,"id":"my-bar","name":"大候选","expanded":{"mode":"list"}}"##.utf8))
        XCTAssertEqual(bar.compositionRow.visible, .composingOnly)
        XCTAssertEqual(bar.collapsed.height, 44, "v1 omitted height keeps the historical default")
        XCTAssertEqual(CandidateBarDefinition.systemDefault.collapsed.height, 40)
        XCTAssertEqual(bar.expanded.mode, .list)
        XCTAssertEqual(bar.expandedEffectiveColumns, 1)
        XCTAssertEqual(bar.controls.pagePosition, .both)
        // Default = the cleanest UX: no composition row without input.
        let idle = CandidatePresentationState()
        XCTAssertFalse(idle.showsCompositionRow(bar))
        // Export and re-import agree for omitted fields.
        XCTAssertEqual(try CandidateBarDefinition.decode(bar.encoded()), bar)
        // Unknown fields / wrong versions / invalid values are rejected.
        for json in [
            #"{"formatVersion":2,"id":"x","name":"x"}"#,
            #"{"formatVersion":1,"id":"../x","name":"x"}"#,
            #"{"formatVersion":1,"id":"x","name":"x","collapsed":{"height":60}}"#,
            #"{"formatVersion":1,"id":"x","name":"x","expanded":{"columns":5}}"#,
            #"{"formatVersion":1,"id":"x","name":"x","renderer":"evil"}"#,
            #"{"formatVersion":1,"id":"x","name":"x","candidates":["假候选"]}"#,
        ] {
            XCTAssertThrowsError(try CandidateBarDefinition.decode(Data(json.utf8)), json)
        }
    }

    func testDefaultHeaderHeightAndFontAwareEffectiveBudget() throws {
        XCTAssertEqual(CandidateBarDefinition.Collapsed().height, 44)
        // The built-in system default is tightened to 40pt; importing with an omitted height still uses v1's 44pt.
        XCTAssertEqual(CandidateBarDefinition.systemDefault.collapsed.height, 40)
        XCTAssertEqual(CandidateBarDefinition.Collapsed.effectiveHeight(36), 36)
        XCTAssertEqual(CandidateBarDefinition.Collapsed.effectiveHeight(36, candidateSize: 17), 36)
        XCTAssertEqual(CandidateBarDefinition.Collapsed.effectiveHeight(36, candidateSize: 30), 41)
        XCTAssertEqual(CandidateBarDefinition.Collapsed.effectiveHeight(36, candidateSize: 50), 66)

        for height in [44.0, 50.0, 56.0] {
            XCTAssertEqual(CandidateBarDefinition.Collapsed.effectiveHeight(height), height)
        }
        let persisted = try CandidateBarDefinition.decode(
            Data(
                #"{"formatVersion":1,"id":"old","name":"old","collapsed":{"height":50}}"#.utf8))
        XCTAssertEqual(persisted.collapsed.height, 50)
        XCTAssertEqual(
            persisted.collapsedHeightBudget, 50,
            "an explicitly saved 44...56pt config must be kept at the default font size")
    }

    func testPresentationStateVisibilityRules() {
        let composing = CandidatePresentationState(
            preedit: "ni hao", rawInput: "nihao",
            candidates: [Candidate(index: 0, text: "你好"), Candidate(index: 1, text: "您好", comment: "nín hǎo")],
            highlightedIndex: 0, pageIndex: 0, canPageForward: true, isComposing: true)
        var bar = CandidateBarDefinition.systemDefault
        XCTAssertTrue(composing.showsCompositionRow(bar))
        XCTAssertTrue(composing.showsCandidateBar)
        XCTAssertTrue(composing.showsExpandedArea)
        bar.compositionRow.visible = .hidden
        XCTAssertFalse(composing.showsCompositionRow(bar))
        XCTAssertTrue(composing.showsCandidateBar, "hiding the composition row does not affect the candidate strip")
        bar.compositionRow.visible = .composingWithIdleRaw
        XCTAssertTrue(
            CandidatePresentationState().showsCompositionRow(bar),
            "advanced users can opt to show the raw-code row when empty")
        XCTAssertTrue(CandidatePresentationState(isEnglishMode: true).isEnglishMode)
        XCTAssertFalse(CandidatePresentationState(isEnglishMode: true).showsCandidateBar)
        let engineEnglish = CandidatePresentationState(
            candidates: [Candidate(index: 2, text: "hello")], pageSize: 5,
            isComposing: true, isEnglishMode: true)
        XCTAssertTrue(engineEnglish.showsCandidateBar)
        XCTAssertTrue(engineEnglish.showsExpandedArea)
        let afterCommit = CandidatePresentationState(
            preedit: "", rawInput: "",
            candidates: [Candidate(index: 0, text: "世界")], pageSize: 5,
            isComposing: true)
        XCTAssertTrue(
            afterCommit.showsExpandedArea, "a real prediction segment has no input code but still reports composing")
    }

    func testActionSinkForwardsRealIndexOnly() {
        var performed: [CandidateAreaAction] = []
        let sink = CandidateAreaActionSink { performed.append($0) }
        sink.perform(.select(2))
        sink.perform(.pageForward)
        sink.perform(.expand)
        XCTAssertEqual(performed, [.select(2), .pageForward, .expand])
    }

    func testRendererRegistryFallback() {
        CandidateRendererRegistry.register(
            CandidateRendererDescriptor(
                id: DefaultCandidateAreaRenderer.rendererID,
                makeCollapsed: { _ in AnyView(EmptyView()) },
                makeExpanded: { _ in AnyView(EmptyView()) }))
        XCTAssertEqual(
            CandidateRendererRegistry.renderer(id: "not-registered").id,
            DefaultCandidateAreaRenderer.rendererID)
        XCTAssertTrue(CandidateRendererRegistry.availableIDs.contains("default"))
    }

    // MARK: - Cross-page candidate accumulation (read-only page reads / revision identity / frontier / empty page clears old state)

    private func page(
        _ index: Int, _ texts: [String], schema: String = "s",
        raw: String = "ab", preedit: String = "ab", revision: Int = 1,
        canForward: Bool = true, canBackward: Bool = true
    ) -> CandidatePresentationState {
        CandidatePresentationState(
            schemaID: schema, preedit: preedit, rawInput: raw,
            candidates: texts.enumerated().map { Candidate(index: $0.offset, text: $0.element) },
            highlightedIndex: 0, pageIndex: index, pageSize: 2,
            canPageBackward: canBackward, canPageForward: canForward,
            isComposing: true, revision: revision)
    }

    private func items(_ texts: [String]) -> [Candidate] {
        texts.enumerated().map { Candidate(index: $0.offset, text: $0.element) }
    }

    // MARK: - Expanded adaptive layout (text-width flow / long words take a full row / user config preserved)

    private func entry(
        _ text: String, comment: String = "", page: Int = 0, local: Int = 0,
        selectKey: String? = nil, selectLabel: String? = nil
    ) -> BrowserCandidate {
        BrowserCandidate(
            pageIndex: page, pageLocalIndex: local,
            candidate: Candidate(
                index: local, text: text, comment: comment,
                selectKey: selectKey, selectLabel: selectLabel))
    }

    func testEngineSelectionBadgePrefersLabelWithoutFabricatingFallback() {
        XCTAssertEqual(entry("甲", selectKey: "a", selectLabel: "壹").selectionBadge, "壹")
        XCTAssertEqual(entry("甲", selectKey: "a", selectLabel: "  ").selectionBadge, "a")
        XCTAssertNil(entry("甲", comment: "comment is not a label").selectionBadge)
    }

    func testSelectionBadgeParticipatesInCollapsedAndExpandedWidthBudgets() {
        let typography = CandidateTypography(candidateSize: 20, secondarySize: 10)
        let plain = entry("甲")
        let labelled = entry("甲", selectLabel: "标签")
        XCTAssertGreaterThan(
            CandidateExpandedFlow.cellWidth(for: labelled, typography: typography, cellPaddingX: 2),
            CandidateExpandedFlow.cellWidth(for: plain, typography: typography, cellPaddingX: 2))
        XCTAssertGreaterThan(
            CandidateCollapsedFlow.intrinsicCellWidth(
                text: labelled.text, comment: labelled.comment, selectionBadge: labelled.selectionBadge,
                typography: typography, cellPaddingX: 2),
            CandidateCollapsedFlow.intrinsicCellWidth(
                text: plain.text, comment: plain.comment,
                typography: typography, cellPaddingX: 2))
    }

    /// Default expanded = adaptive; an explicit `grid`/`list` config (including column count) is kept as-is and re-imports.
    func testExpandedDefaultIsAdaptiveAndExplicitModesPreserved() throws {
        XCTAssertEqual(CandidateBarDefinition.systemDefault.expanded.mode, .adaptive)
        XCTAssertTrue(CandidateBarDefinition.systemDefault.expanded.isAdaptive)

        let grid = try CandidateBarDefinition.decode(
            Data(
                ##"{"formatVersion":1,"id":"g","name":"g","expanded":{"mode":"grid","columns":3}}"##.utf8))
        XCTAssertEqual(grid.expanded.mode, .grid)
        XCTAssertFalse(grid.expanded.isAdaptive)
        XCTAssertEqual(grid.expandedEffectiveColumns, 3, "an explicit user column count must be kept")

        let list = try CandidateBarDefinition.decode(
            Data(
                ##"{"formatVersion":1,"id":"l","name":"l","expanded":{"mode":"list"}}"##.utf8))
        XCTAssertEqual(list.expanded.mode, .list)
        XCTAssertEqual(list.expandedEffectiveColumns, 1)

        let adaptive = try CandidateBarDefinition.decode(
            Data(
                ##"{"formatVersion":1,"id":"a","name":"a","expanded":{"mode":"adaptive"}}"##.utf8))
        XCTAssertEqual(adaptive.expanded.mode, .adaptive)
        XCTAssertEqual(try CandidateBarDefinition.decode(adaptive.encoded()), adaptive, "export and re-import agree")

        // An unknown mode is still strictly rejected.
        XCTAssertThrowsError(
            try CandidateBarDefinition.decode(
                Data(
                    ##"{"formatVersion":1,"id":"x","name":"x","expanded":{"mode":"weird"}}"##.utf8)))
    }

    /// Short candidates fill greedily by actual text width rather than fixed equal two columns.
    func testExpandedAdaptivePacksShortCandidatesByTextWidth() {
        let typography = CandidateTypography(candidateSize: 20, secondarySize: 10)
        // Each single CJK character ~ 20pt + 12pt padding on each side = 44pt (raised to the minimum touch width).
        let entries = ["是", "时", "事", "实", "十", "师", "使"].enumerated()
            .map { entry($0.element, local: $0.offset) }
        let rows = CandidateExpandedFlow.layout(
            entries: entries, expanded: .init(),
            typography: typography, cellPaddingX: 12,
            availableWidth: 300)
        // 6 x 44 + 5 x 4 = 284 <= 300; adding a 7th needs 4 + 44 = 332 > 300, so it wraps.
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].entries.count, 6)
        XCTAssertEqual(rows[1].entries.count, 1)
        XCTAssertTrue(
            rows.allSatisfy { row in row.widths.allSatisfy { $0 == 44 } },
            "a single-character cell hugs its text (== minimum touch width) and no longer spreads across half the screen"
        )
    }

    /// Wrap boundary: no wrap when it fits exactly, wrap when 1pt short.
    func testExpandedAdaptiveWrapsOnlyWhenRowOverflows() {
        let typography = CandidateTypography(candidateSize: 20, secondarySize: 10)
        let two = [entry("是", local: 0), entry("时", local: 1)]
        // Two 44-wide cells + 4 spacing = 92.
        XCTAssertEqual(
            CandidateExpandedFlow.layout(
                entries: two, expanded: .init(), typography: typography,
                cellPaddingX: 12, availableWidth: 92
            ).count, 1)
        XCTAssertEqual(
            CandidateExpandedFlow.layout(
                entries: two, expanded: .init(), typography: typography,
                cellPaddingX: 12, availableWidth: 91
            ).count, 2)
    }

    /// A long word takes its own row and is capped to the available width (readable and scrollable).
    func testExpandedAdaptiveLongCandidateOwnsRowCappedToAvailableWidth() {
        let typography = CandidateTypography(candidateSize: 20, secondarySize: 10)
        let long = String(repeating: "汉", count: 20)  // ~ 400pt, over the 300 available width.
        let entries = [entry("是", local: 0), entry(long, local: 1), entry("时", local: 2)]
        let rows = CandidateExpandedFlow.layout(
            entries: entries, expanded: .init(),
            typography: typography, cellPaddingX: 12,
            availableWidth: 300)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[1].entries.first?.text, long)
        XCTAssertEqual(
            rows[1].widths, [300], "a long word is capped at the available width and does not break the expanded area")
    }

    /// The threshold config takes effect: text/comments over the threshold take their own row (long phrases stay readable).
    func testExpandedAdaptiveFullRowThresholdForcesOwnRow() {
        let typography = CandidateTypography(candidateSize: 20, secondarySize: 10)
        var expanded = CandidateBarDefinition.Expanded()
        expanded.fullRowTextLength = 1
        let entries = [entry("你好", local: 0), entry("您好", local: 1)]
        // Under the default threshold the two sit side by side; with threshold = 1, 2 characters > 1, so each takes its own row.
        XCTAssertEqual(
            CandidateExpandedFlow.layout(
                entries: entries, expanded: .init(), typography: typography,
                cellPaddingX: 12, availableWidth: 300
            ).count, 1)
        let forced = CandidateExpandedFlow.layout(
            entries: entries, expanded: expanded, typography: typography,
            cellPaddingX: 12, availableWidth: 300)
        XCTAssertEqual(forced.count, 2)
        XCTAssertEqual(forced[0].widths, [300])
        // A comment over 3x the threshold also takes its own row.
        XCTAssertTrue(CandidateExpandedFlow.wantsOwnRow(entry("甲", comment: "四个字注释"), fullRowTextLength: 1))
    }

    /// Text metrics: CJK is wider than Latin, spaces/invalid font sizes degrade, and comments count toward cell width.
    func testExpandedAdaptiveTextMetricsAndCommentWidth() {
        XCTAssertEqual(CandidateTextMetrics.estimatedWidth("", fontSize: 20), 0)
        XCTAssertEqual(CandidateTextMetrics.estimatedWidth("ab", fontSize: 20), 2 * 20 * 0.62, accuracy: 0.001)
        XCTAssertGreaterThan(
            CandidateTextMetrics.estimatedWidth("汉", fontSize: 20),
            CandidateTextMetrics.estimatedWidth("a", fontSize: 20))
        XCTAssertEqual(CandidateTextMetrics.estimatedWidth("汉", fontSize: 0), 0)
        let typography = CandidateTypography(candidateSize: 20, secondarySize: 10)
        let withComment = CandidateExpandedFlow.cellWidth(
            for: entry("甲", comment: "很长很长的注释内容"), typography: typography, cellPaddingX: 12)
        let plain = CandidateExpandedFlow.cellWidth(
            for: entry("甲"), typography: typography, cellPaddingX: 12)
        XCTAssertGreaterThan(withComment, plain, "the cell width grows when the comment is wider")
    }

    /// Degenerate input does not crash: no candidates gives no rows; a non-finite available width degrades to no wrapping.
    func testExpandedAdaptiveDegenerateInputs() {
        let typography = CandidateTypography(candidateSize: 20, secondarySize: 10)
        XCTAssertTrue(
            CandidateExpandedFlow.layout(
                entries: [], expanded: .init(), typography: typography,
                cellPaddingX: 12, availableWidth: 300
            ).isEmpty)
        let entries = [entry("是", local: 0), entry("时", local: 1)]
        let rows = CandidateExpandedFlow.layout(
            entries: entries, expanded: .init(), typography: typography,
            cellPaddingX: 12, availableWidth: .infinity)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].widths, [44, 44])
    }

    // MARK: - Collapsed strip readability (3-character words complete / long words reachable / short candidates filled evenly)

    /// With many candidates in the collapsed strip, the intrinsic width of a three-character word (the top candidate)
    /// must be >= text width + padding, not a fixed 44pt, and gets its full width in scrolling mode.
    func testCollapsedThreeCharWordGetsIntrinsicWidthNotFixed44() {
        let typography = CandidateTypography(candidateSize: 20, secondarySize: 10)
        let intrinsic = CandidateCollapsedFlow.intrinsicCellWidth(
            text: "早上好", comment: "", typography: typography, cellPaddingX: 12)
        // 3x20 + 2x12 + slack = 88; a fixed 44 would truncate the word to one character plus an ellipsis.
        XCTAssertEqual(intrinsic, 88, accuracy: 0.001)
        XCTAssertGreaterThan(intrinsic, 60, "must at least hold the 3 CJK glyphs themselves")

        // Too many candidates to fit: scroll, with each three-character word at its intrinsic width (not 44).
        let entries = ["早上好", "最", "造成", "早上", "最长", "噪声", "最后"]
            .enumerated().map { entry($0.element, local: $0.offset) }
        let layout = CandidateCollapsedFlow.layout(
            entries: entries, collapsed: .init(), typography: typography, availableWidth: 356)
        XCTAssertTrue(layout.scrolls, "when several do not fit it must scroll rather than shrink or truncate")
        XCTAssertEqual(layout.cellWidths.count, entries.count)
        XCTAssertEqual(layout.cellWidths[0], 88, accuracy: 0.001, "the top three-character word keeps its full width")
        XCTAssertTrue(layout.cellWidths.allSatisfy { $0 >= 44 }, "not below the touch minimum")
    }

    /// Few short candidates: even-width fill (no scrolling), each no smaller than its intrinsic width.
    func testCollapsedFewShortCandidatesFillEvenly() {
        let typography = CandidateTypography(candidateSize: 20, secondarySize: 10)
        let entries = ["的", "是", "在"].enumerated().map { entry($0.element, local: $0.offset) }
        let layout = CandidateCollapsedFlow.layout(
            entries: entries, collapsed: .init(), typography: typography, availableWidth: 356)
        XCTAssertFalse(layout.scrolls, "three single characters should fill at equal width without scrolling")
        XCTAssertEqual(Set(layout.cellWidths).count, 1, "equal width")
        let even = layout.cellWidths[0]
        XCTAssertGreaterThanOrEqual(even, 44)
        XCTAssertLessThanOrEqual(even, CandidateCollapsedFlow.maximumEvenCellWidth)
        // Fill: 3 cells + 2 spacings ~ available width (when the 120 cap is not hit).
        XCTAssertEqual(even * 3 + 4 * 2, 356, accuracy: 0.5)
    }

    /// The compact default keeps the same cell width for few/appended candidates, so read-only loading does not shift words already shown.
    func testCompactCollapsedWidthsStayStableWhenCandidatesAppend() {
        let typography = CandidateTypography(candidateSize: 20, secondarySize: 10)
        var collapsed = CandidateBarDefinition.Collapsed()
        collapsed.cellPaddingX = 7
        collapsed.cellSpacing = 0
        let entries = ["早上好", "早上", "早"].enumerated().map { entry($0.element, local: $0.offset) }
        let initial = CandidateCollapsedFlow.layout(
            entries: entries, collapsed: collapsed,
            typography: typography, availableWidth: 356, fillsAvailableWidth: false)
        let appended = CandidateCollapsedFlow.layout(
            entries: entries + [entry(String(repeating: "长", count: 20), local: 3)],
            collapsed: collapsed, typography: typography, availableWidth: 356, fillsAvailableWidth: false)
        XCTAssertFalse(initial.scrolls)
        XCTAssertTrue(appended.scrolls)
        XCTAssertEqual(initial.cellWidths, Array(appended.cellWidths.prefix(3)))
        XCTAssertEqual(initial.cellWidths, [78, 58, 44])
    }

    /// Even-width fill applies only when everything fits by total width; with a long word cells use their intrinsic width (not shrunk).
    func testCollapsedLongWordKeepsIntrinsicNotShrunk() {
        let typography = CandidateTypography(candidateSize: 20, secondarySize: 10)
        let long = String(repeating: "汉", count: 8)  // 160pt + 24 + slack
        let entries = [entry("的", local: 0), entry(long, local: 1)]
        let layout = CandidateCollapsedFlow.layout(
            entries: entries, collapsed: .init(), typography: typography, availableWidth: 356)
        // Not even-width (88*2+4 would overflow or shrink the long word): the long word keeps its intrinsic width; the total 240 is still inside the viewport.
        XCTAssertEqual(
            layout.cellWidths[1], 188, accuracy: 0.001, "the long word uses its intrinsic width and is not shrunk")
        XCTAssertFalse(
            layout.scrolls, "total 48+188+4=240 <= 356, no scrolling needed (scrolls reflects real overflow)")

        // Several items that really overflow: scrolls=true, each cell still at its intrinsic width.
        let overflow = CandidateCollapsedFlow.layout(
            entries: [entry(long, local: 0), entry(long, local: 1)], collapsed: .init(),
            typography: typography, availableWidth: 356)
        XCTAssertTrue(overflow.scrolls, "scroll only when the total 188+188+4=380 > 356")
        XCTAssertEqual(overflow.cellWidths, [188, 188])
    }

    /// An over-long word is **not capped to the viewport**: a cell may exceed the viewport, and the same horizontal ScrollView
    /// shows the full text; only a finite multiple of the available width guards against pathological frames from extreme text.
    func testCollapsedLongCellExceedsViewportAndIsBounded() {
        let typography = CandidateTypography(candidateSize: 20, secondarySize: 10)
        let long = String(repeating: "汉", count: 40)  // 800 + 24 + 4 = 828
        let layout = CandidateCollapsedFlow.layout(
            entries: [entry(long, local: 0)], collapsed: .init(),
            typography: typography, availableWidth: 300)
        XCTAssertTrue(layout.scrolls, "a 828 cell > the 300 viewport means a real horizontal offset")
        XCTAssertEqual(
            layout.cellWidths[0], 828, accuracy: 0.001, "uses the full intrinsic text width, no longer capped at 300")

        // Extreme text: a finite guard rail (available width x4 = 1200); the output stays finite and scrollable, never infinite.
        let extreme = String(repeating: "汉", count: 1000)
        let bounded = CandidateCollapsedFlow.layout(
            entries: [entry(extreme, local: 0)], collapsed: .init(),
            typography: typography, availableWidth: 300)
        XCTAssertTrue(bounded.cellWidths[0].isFinite)
        XCTAssertEqual(
            bounded.cellWidths[0],
            CandidateCollapsedFlow.maximumCellWidth(availableWidth: 300), accuracy: 0.001)
        XCTAssertEqual(bounded.cellWidths[0], 1200, accuracy: 0.001)
        XCTAssertTrue(bounded.scrolls)
    }

    /// Uniform tolerance: four items with intrinsic = 88, spacing 4, available 362:
    /// total width 88*4+4*3 = 364 > 362 must scroll; it must not stay even-width by accumulating overflow through a per-cell 0.5pt tolerance.
    func testCollapsedEvenFillUsesTotalWidthNotPerCellTolerance() {
        let typography = CandidateTypography(candidateSize: 20, secondarySize: 10)
        let entries = ["早上好", "中午好", "下午好", "晚上好"]
            .enumerated().map { entry($0.element, local: $0.offset) }
        let layout = CandidateCollapsedFlow.layout(
            entries: entries, collapsed: .init(), typography: typography, availableWidth: 362)
        XCTAssertTrue(layout.scrolls, "total 364 > 362, so it cannot fill at equal width")
        XCTAssertEqual(layout.cellWidths, [88, 88, 88, 88])
        // Equal width only when it fits exactly (364 >= 364).
        let exact = CandidateCollapsedFlow.layout(
            entries: entries, collapsed: .init(), typography: typography, availableWidth: 364)
        XCTAssertFalse(exact.scrolls)
        XCTAssertEqual(Set(exact.cellWidths), [88])
    }

    /// The collapsed state draws no comments, so a long reading cannot crowd out the primary candidate; degenerate input still does not crash.
    func testCollapsedCommentsDoNotAffectVisibleWidthsOrScroll() {
        let typography = CandidateTypography(candidateSize: 20, secondarySize: 10)
        let plain = CandidateCollapsedFlow.intrinsicCellWidth(
            text: "甲", comment: "", typography: typography, cellPaddingX: 12)
        let withComment = CandidateCollapsedFlow.intrinsicCellWidth(
            text: "甲", comment: "很长很长的注释", typography: typography, cellPaddingX: 12)
        XCTAssertEqual(withComment, plain)

        let words = [entry("甲", local: 0), entry("早上好", local: 1), entry("乙", local: 2)]
        let annotated = words.enumerated().map {
            entry($0.element.text, comment: String(repeating: "读音", count: 80), local: $0.offset)
        }
        let bare = CandidateCollapsedFlow.layout(
            entries: words, collapsed: .init(), typography: typography, availableWidth: 260)
        let withNotes = CandidateCollapsedFlow.layout(
            entries: annotated, collapsed: .init(), typography: typography, availableWidth: 260)
        XCTAssertEqual(withNotes, bare)
        XCTAssertFalse(withNotes.scrolls)
        XCTAssertEqual(withNotes.cellWidths, [48, 88, 48])

        XCTAssertEqual(
            CandidateCollapsedFlow.layout(
                entries: [], collapsed: .init(), typography: typography, availableWidth: 356),
            CandidateCollapsedLayout(cellWidths: [], scrolls: false))
        // Degenerate available width: no crash, cell width stays >= 44 (zero width scrolls), a non-finite width degrades to even-width fill.
        let zero = CandidateCollapsedFlow.layout(
            entries: [entry("甲", local: 0)], collapsed: .init(), typography: typography,
            availableWidth: 0)
        XCTAssertTrue(zero.scrolls)
        XCTAssertEqual(zero.cellWidths, [CandidateCollapsedFlow.minimumCellWidth])
        let unbounded = CandidateCollapsedFlow.layout(
            entries: [entry("甲", local: 0)], collapsed: .init(), typography: typography,
            availableWidth: .infinity)
        XCTAssertFalse(unbounded.scrolls)
        XCTAssertEqual(unbounded.cellWidths, [CandidateCollapsedFlow.maximumEvenCellWidth])
    }

    func testWholeRowBudgetKeepsSpacingAndMinimumTouchHeight() {
        for (height, spacing) in [(160.0, 0.0), (160.0, 4.0), (112.0, 0.0)] {
            let row = CandidateExpandedFlow.fittedRowHeight(availableHeight: height, spacing: spacing)
            let count = floor((height + spacing) / (44 + spacing))
            XCTAssertGreaterThanOrEqual(row, 44)
            XCTAssertEqual(row * count + (count - 1) * spacing, height, accuracy: 0.001)
        }
        XCTAssertEqual(CandidateExpandedFlow.fittedRowHeight(availableHeight: .nan, spacing: 0), 44)
    }

    func testSchemaDisplayFallbackDoesNotOverrideSourceProvidedNames() {
        XCTAssertEqual(
            KeyboardSchemaDescriptor(id: "double_pinyin_flypy", name: "double_pinyin_flypy").displayName, "小鹤双拼")
        XCTAssertEqual(KeyboardSchemaDescriptor(id: "double_pinyin_jiajia", name: "").displayName, "拼音加加双拼")
        XCTAssertEqual(KeyboardSchemaDescriptor(id: "double_pinyin_flypy", name: "我的双拼").displayName, "我的双拼")
        XCTAssertEqual(KeyboardSchemaDescriptor(id: "user_schema", name: "个人方案").displayName, "个人方案")
    }

    func testCompactCopyPersistsActualLayout() throws {
        var copy = CandidateBarDefinition.systemDefault.copy()
        copy.name = "改名仍紧凑"
        let restored = try CandidateBarDefinition.decode(copy.encoded())
        XCTAssertEqual(restored, copy)
        XCTAssertEqual(restored.collapsed, CandidateBarDefinition.systemDefault.collapsed)
        XCTAssertEqual(restored.expanded, CandidateBarDefinition.systemDefault.expanded)
        XCTAssertEqual(restored.collapsed.fillsAvailableWidth, false)
        let words = [entry("早上好", local: 0), entry("早", local: 1)]
        let layout = CandidateCollapsedFlow.layout(
            entries: words, collapsed: restored.collapsed,
            typography: .init(candidateSize: 20, secondarySize: 10), availableWidth: 356)
        XCTAssertEqual(
            layout.cellWidths, [78, 44], "the saved natural-width strategy is consumed directly by the layout function")

        var diy = CandidateBarDefinition.systemDefault
        diy.id = "existing-diy"
        diy.collapsed.fillsAvailableWidth = nil
        let decoded = try CandidateBarDefinition.decode(diy.encoded())
        XCTAssertNil(decoded.collapsed.fillsAvailableWidth, "an omitted strategy is still even split")
    }

    /// Default filling on decode must not erase explicit user values: an explicit `grid/3` is never treated as the default.
    func testStrictDecodeDoesNotTreatExplicitGridAsDefault() throws {
        let explicitGrid = try CandidateBarDefinition.decode(
            Data(
                ##"{"formatVersion":1,"id":"g3","name":"g3","expanded":{"mode":"grid","columns":3}}"##.utf8))
        XCTAssertEqual(explicitGrid.expanded.mode, .grid)
        XCTAssertEqual(explicitGrid.expanded.columns, 3)
        XCTAssertEqual(explicitGrid.expandedEffectiveColumns, 3)
        let omitted = try CandidateBarDefinition.decode(
            Data(
                ##"{"formatVersion":1,"id":"d","name":"d"}"##.utf8))
        XCTAssertEqual(omitted.expanded.mode, .adaptive)
    }

    /// When the identity changes, reset rebuilds anchored on the real current page (earlier pages are pending).
    func testBrowserResetAnchorsOnRealPageAndBackfillsPrefix() {
        var browser = CandidateBrowser()
        // The engine's real current page = 2 (earlier pages 0/1 exist but are not loaded).
        browser.reset(page(2, ["戊", "己"], revision: 5, canForward: false))
        XCTAssertEqual(browser.entries.map(\.text), ["戊", "己"])
        XCTAssertEqual(browser.enginePageIndex, 2)
        // Earlier pages are filled first: the frontier points at the earliest unloaded earlier page.
        XCTAssertTrue(browser.needsEarlier)
        XCTAssertTrue(browser.hasMore)
        XCTAssertEqual(browser.nextPageToLoad, 0)
        // Fill 0 and 1 read-only (earlier pages are always full pages); afterwards no earlier page remains and the last page rests.
        XCTAssertTrue(browser.append(pageIndex: 0, candidates: items(["甲", "乙"]), pageSize: 2))
        XCTAssertTrue(browser.append(pageIndex: 1, candidates: items(["丙", "丁"]), pageSize: 2))
        XCTAssertEqual(
            browser.entries.map { "\($0.pageIndex):\($0.pageLocalIndex)" },
            ["0:0", "0:1", "1:0", "1:1", "2:0", "2:1"],
            "candidates sort by absolute index, never reversed or duplicated")
        XCTAssertFalse(browser.needsEarlier)
        XCTAssertFalse(browser.hasMore)
        XCTAssertNil(browser.nextPageToLoad)
    }

    /// A non-zero current page that can page forward: fill earlier pages first, then continue with later ones.
    func testBrowserBackfillsPrefixThenContinuesForward() {
        var browser = CandidateBrowser()
        browser.reset(page(2, ["戊", "己"], revision: 5, canForward: true))
        XCTAssertEqual(browser.nextPageToLoad, 0)
        XCTAssertTrue(browser.append(pageIndex: 0, candidates: items(["甲", "乙"]), pageSize: 2))
        XCTAssertEqual(browser.nextPageToLoad, 1)
        XCTAssertTrue(browser.append(pageIndex: 1, candidates: items(["丙", "丁"]), pageSize: 2))
        XCTAssertEqual(browser.nextPageToLoad, 3, "after earlier pages are filled, continue past the real current page")
        XCTAssertTrue(browser.append(pageIndex: 3, candidates: items(["庚"]), pageSize: 2))
        XCTAssertFalse(browser.hasMore, "a backward read-back shorter than a page = the last page")
    }

    /// A display-only refresh (identity unchanged, e.g. a read-only options query) must not clear cross-page browsing.
    func testBrowserResetIsNoOpWhenIdentityUnchanged() {
        var browser = CandidateBrowser()
        browser.reset(page(0, ["甲", "乙"], revision: 7, canBackward: false))
        XCTAssertTrue(browser.append(pageIndex: 1, candidates: items(["丙", "丁"]), pageSize: 2))
        XCTAssertEqual(browser.entries.count, 4)
        // Resetting again with the same identity (options-only refresh / activation republishing the same cached snapshot) keeps browsing.
        browser.reset(page(0, ["甲", "乙"], revision: 7, canBackward: false))
        XCTAssertEqual(browser.entries.count, 4, "an unchanged identity must keep loaded pages")
        XCTAssertEqual(browser.nextPageToLoad, 2)
        // preedit is not part of the identity: preedit changes with an unchanged revision still keep the pages (pages are not lost to a highlighted candidate's preedit).
        browser.reset(page(0, ["甲", "乙"], preedit: "DIFFERENT", revision: 7, canBackward: false))
        XCTAssertEqual(browser.entries.count, 4)
    }

    /// A real revision change (through a real session action/recomputation) invalidates authoritatively and keeps only the new current page.
    func testBrowserRevisionChangeInvalidatesSameRawIdentity() {
        var browser = CandidateBrowser()
        browser.reset(page(0, ["甲", "乙"], raw: "ab", revision: 1, canBackward: false))
        XCTAssertTrue(browser.append(pageIndex: 1, candidates: items(["丙", "丁"]), pageSize: 2))
        XCTAssertEqual(browser.entries.count, 4)
        browser.reset(page(0, ["新一", "新二"], raw: "ab", revision: 2, canBackward: false))
        XCTAssertEqual(browser.entries.map(\.text), ["新一", "新二"])
    }

    func testBrowserAppendRejectsDuplicateAndOutOfIdentityPage() {
        var browser = CandidateBrowser()
        browser.reset(page(0, ["甲", "乙"], canBackward: false))
        XCTAssertTrue(browser.append(pageIndex: 1, candidates: items(["丙", "丁"]), pageSize: 2))
        // Reading the same page read-only again: rejected, no duplicate entries and no repeated engine load.
        XCTAssertFalse(browser.append(pageIndex: 1, candidates: items(["丙", "丁"]), pageSize: 2))
        XCTAssertEqual(browser.entries.count, 4)
        // An invalid page number is rejected.
        XCTAssertFalse(browser.append(pageIndex: -1, candidates: items(["x"]), pageSize: 2))
    }

    /// The generation's stableID is stable (same identity gives the same string, different identities differ) for sentinel identity binding.
    func testGenerationStableIDIsDeterministicAcrossIdentity() {
        let a = CandidateGeneration(
            revision: 3, schemaID: "s", layout: "l",
            rawInput: "ab", pageSize: 5, isComposing: true)
        let b = CandidateGeneration(
            revision: 3, schemaID: "s", layout: "l",
            rawInput: "ab", pageSize: 5, isComposing: true)
        let c = CandidateGeneration(
            revision: 4, schemaID: "s", layout: "l",
            rawInput: "ab", pageSize: 5, isComposing: true)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.stableID, b.stableID)
        XCTAssertNotEqual(a.stableID, c.stableID, "a new composition must give a different sentinel identity")
    }

    /// A separator appearing inside a field must not cause a collision. Bare concatenation would give both of the following the same stableID
    /// (`3|s|l|x|ab|5|true`); with length-prefixed encoding they must differ.
    func testGenerationIdentityIsUnambiguousUnderSeparatorCollision() {
        let a = CandidateGeneration(
            revision: 3, schemaID: "s|l", layout: "x",
            rawInput: "ab", pageSize: 5, isComposing: true)
        let b = CandidateGeneration(
            revision: 3, schemaID: "s", layout: "l|x",
            rawInput: "ab", pageSize: 5, isComposing: true)
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a.stableID, b.stableID, "string field boundaries must be uniquely parseable")

        // The structured sentinel identity also distinguishes field by field, and frontier / view kind changes must be distinguished too.
        let sentinelA = CandidateSentinelIdentity(generation: a, frontier: 0, kind: .collapsedTail)
        let sentinelB = CandidateSentinelIdentity(generation: b, frontier: 0, kind: .collapsedTail)
        XCTAssertNotEqual(sentinelA, sentinelB)
        XCTAssertEqual(
            sentinelA,
            CandidateSentinelIdentity(generation: a, frontier: 0, kind: .collapsedTail))
        XCTAssertNotEqual(
            sentinelA,
            CandidateSentinelIdentity(generation: a, frontier: 1, kind: .collapsedTail))
        XCTAssertNotEqual(
            sentinelA,
            CandidateSentinelIdentity(generation: a, frontier: 0, kind: .expandedTail))
    }

    /// An empty candidate result must not keep old pages (a real state change).
    func testBrowserEmptyResultClearsOldPage() {
        var browser = CandidateBrowser()
        browser.reset(page(0, ["甲", "乙"], canBackward: false))
        XCTAssertTrue(browser.append(pageIndex: 1, candidates: items(["丙", "丁"]), pageSize: 2))
        XCTAssertEqual(browser.entries.count, 4)
        browser.reset(
            CandidatePresentationState(
                schemaID: "s", rawInput: "ab", pageIndex: 0, pageSize: 2, isComposing: true, revision: 2))
        XCTAssertTrue(browser.isEmpty, "an empty result must clear old pages")
        XCTAssertFalse(browser.hasMore)
    }

    /// Empty candidates under the same identity (same revision) must also authoritatively clear old browsing,
    /// and recovering to non-empty under the same identity after a clear must rebuild, not stay a permanent no-op.
    func testBrowserSameIdentityEmptyResultClearsOldBrowsingAndRecovers() {
        var browser = CandidateBrowser()
        browser.reset(page(0, ["甲", "乙"], revision: 7, canBackward: false))
        XCTAssertTrue(browser.append(pageIndex: 1, candidates: items(["丙", "丁"]), pageSize: 2))
        XCTAssertEqual(browser.entries.count, 4)
        XCTAssertEqual(browser.nextPageToLoad, 2)
        // Same revision, same identity, empty candidates: old entries/frontier must be cleared first.
        browser.reset(page(0, [], revision: 7, canBackward: false))
        XCTAssertTrue(browser.isEmpty, "an empty result under the same identity must not keep old candidates")
        XCTAssertFalse(browser.hasMore)
        XCTAssertNil(browser.nextPageToLoad)
        XCTAssertTrue(browser.loadedPages.isEmpty || browser.loadedPages == [0])
        XCTAssertFalse(browser.hasIncompletePage)
        // Recovering to non-empty under the same identity rebuilds instead of staying empty forever.
        browser.reset(page(0, ["新甲"], revision: 7, canBackward: false))
        XCTAssertEqual(
            browser.entries.map(\.text), ["新甲"], "non-empty under the same identity after a clear must rebuild")
    }

    /// A short/empty page before the anchor must not be registered as complete; the frontier stays, is retryable and leaves no hole.
    func testBrowserEarlierShortPageStaysRetryableWithoutHole() {
        var browser = CandidateBrowser()
        // The real current page = 2; earlier pages 0/1 are pending.
        browser.reset(page(2, ["戊", "己"], revision: 5, canForward: false))
        XCTAssertEqual(browser.nextPageToLoad, 0)
        // An empty page 0 must not be registered as loaded and skipped; the frontier must stay on earlier page 0.
        XCTAssertFalse(
            browser.append(pageIndex: 0, candidates: [], pageSize: 2),
            "an empty page before the anchor is not EOF and must not be sealed as read")
        XCTAssertEqual(browser.nextPageToLoad, 0, "the frontier must stay and must not skip earlier pages")
        XCTAssertTrue(browser.hasIncompletePage)
        XCTAssertTrue(browser.hasIncompleteEarlierPage)
        XCTAssertTrue(browser.canAppend(pageIndex: 0), "an incomplete page stays retryable")
        XCTAssertTrue(browser.loadedPages.contains(2))
        XCTAssertFalse(browser.loadedPages.contains(0))
        // A successful retry (a full page) seals and advances without accumulating twice.
        XCTAssertEqual(
            browser.append(pageIndex: 0, result: .page(items(["甲", "乙"])), pageSize: 2),
            .appended)
        XCTAssertEqual(browser.nextPageToLoad, 1)
        XCTAssertFalse(browser.hasIncompletePage)
        XCTAssertEqual(browser.entries.filter { $0.pageIndex == 0 }.count, 2)
    }

    /// `.unavailable` (failed/unsupported) is never EOF at any position and the frontier stays retryable;
    /// only a real successful short read at the tail is EOF.
    func testBrowserUnavailableReadDoesNotConcludeEOF() {
        var browser = CandidateBrowser()
        browser.reset(page(0, ["甲", "乙"], revision: 1))
        XCTAssertEqual(browser.nextPageToLoad, 1)
        XCTAssertEqual(browser.append(pageIndex: 1, result: .unavailable, pageSize: 2), .incomplete)
        XCTAssertTrue(browser.hasMore, "a failed read must not claim the last page")
        XCTAssertEqual(browser.nextPageToLoad, 1)
        XCTAssertTrue(browser.hasIncompletePage)
        XCTAssertFalse(browser.loadedPages.contains(1))
        // A successful short read at the tail = real EOF.
        XCTAssertEqual(
            browser.append(pageIndex: 1, result: .page(items(["丙"])), pageSize: 2),
            .appended)
        XCTAssertFalse(browser.hasMore)
        XCTAssertFalse(browser.hasIncompletePage)
    }

    /// Production contract: `CandidatePageReadResult.reading` is the single decision point in KeyboardController:
    /// a throw must map to `.unavailable` (retryable), and a successful empty/short return maps to `.page`
    /// (append decides EOF). This keeps "read failed" and "real EOF" apart at the wiring layer.
    func testCandidateReadResultMappingSeparatesFailureFromEOF() {
        enum ReadFailure: Error { case engineDown }
        XCTAssertEqual(
            CandidateBrowser.CandidatePageReadResult.reading { throw ReadFailure.engineDown },
            .unavailable, "a throw must never be treated as empty/EOF")
        XCTAssertEqual(CandidateBrowser.CandidatePageReadResult.reading { [] }, .page([]))
        XCTAssertEqual(
            CandidateBrowser.CandidatePageReadResult.reading { items(["甲"]) },
            .page(items(["甲"])))
    }

    /// Production contract (simulating the read + append sequence of KeyboardController.loadMoreCandidates):
    /// a tail read that throws stays retryable and is not EOF; after recovery a successful empty read ends normally at EOF.
    func testProductionLoadMoreKeepsFailureRetryableThenEOF() {
        enum ReadFailure: Error { case engineDown }
        // Mirror the Controller wiring: nextPageToLoad -> reading(throws) -> append(result:).
        func load(
            _ browser: inout CandidateBrowser, pageSize: Int,
            read: () throws -> [Candidate]
        ) {
            guard let page = browser.nextPageToLoad, browser.hasMore else { return }
            let result = CandidateBrowser.CandidatePageReadResult.reading(read)
            browser.append(pageIndex: page, result: result, pageSize: pageSize)
        }
        var browser = CandidateBrowser()
        browser.reset(page(0, ["甲", "乙"], revision: 1))
        XCTAssertEqual(browser.nextPageToLoad, 1)
        // Read failed: not EOF, the frontier stays, retryable, no automatic endless requests (identity unchanged).
        load(&browser, pageSize: 2) { throw ReadFailure.engineDown }
        XCTAssertEqual(browser.nextPageToLoad, 1, "the frontier must stay after a failure")
        XCTAssertTrue(browser.hasMore)
        XCTAssertTrue(browser.hasIncompletePage)
        XCTAssertFalse(browser.loadedPages.contains(1))
        // After recovery a successful empty read at the tail = real EOF and browsing ends normally.
        load(&browser, pageSize: 2) { [] }
        XCTAssertFalse(browser.hasMore, "a successful empty read after recovery should end normally at EOF")
        XCTAssertFalse(browser.hasIncompletePage)
        XCTAssertTrue(browser.loadedPages.contains(1))
    }

    /// Production contract (earlier page failure): a throwing read before the anchor also stays retryable and leaves no permanent hole.
    func testProductionLoadMoreEarlierFailureStaysRetryable() {
        enum ReadFailure: Error { case engineDown }
        var browser = CandidateBrowser()
        browser.reset(page(2, ["戊", "己"], revision: 5, canForward: false))
        XCTAssertEqual(browser.nextPageToLoad, 0)
        let result = CandidateBrowser.CandidatePageReadResult.reading { throw ReadFailure.engineDown }
        XCTAssertEqual(browser.append(pageIndex: 0, result: result, pageSize: 2), .incomplete)
        XCTAssertEqual(browser.nextPageToLoad, 0, "an earlier page failure must not jump to later pages")
        XCTAssertTrue(browser.hasIncompleteEarlierPage)
        XCTAssertTrue(browser.canAppend(pageIndex: 0))
        // A retry that succeeds with a full page advances.
        let retry = CandidateBrowser.CandidatePageReadResult.reading { items(["甲", "乙"]) }
        XCTAssertEqual(browser.append(pageIndex: 0, result: retry, pageSize: 2), .appended)
        XCTAssertEqual(browser.nextPageToLoad, 1)
        XCTAssertFalse(browser.hasIncompletePage)
    }

    func testBrowserResetClearsOnEndCompositionOrEnglish() {
        var browser = CandidateBrowser()
        browser.reset(page(0, ["甲", "乙"], canBackward: false))
        browser.reset(CandidatePresentationState(isComposing: false))
        XCTAssertTrue(browser.isEmpty)
        browser.reset(page(0, ["甲", "乙"], canBackward: false))
        browser.reset(CandidatePresentationState(isEnglishMode: true))
        XCTAssertTrue(browser.isEmpty)
    }

    func testBrowserKeepsEngineEnglishAndEmptyInputPredictionMenus() {
        var browser = CandidateBrowser()
        let english = CandidatePresentationState(
            schemaID: "user-schema", rawInput: "hell",
            candidates: [Candidate(index: 2, text: "hello")], pageSize: 5,
            isComposing: true, isEnglishMode: true, revision: 20)
        browser.reset(english)
        XCTAssertEqual(browser.entries.map(\.candidate.text), ["hello"])
        XCTAssertEqual(browser.generation?.isComposing, true)
        var predictionSnapshot = EngineSnapshot(
            candidates: [Candidate(index: 0, text: "world")], pageSize: 5, isLastPage: false)
        predictionSnapshot.schemaID = "user-schema"
        predictionSnapshot.isPrediction = true
        let predicted = CandidatePresentationState(
            snapshot: predictionSnapshot, isEnglishMode: false,
            revision: 21)
        XCTAssertFalse(predicted.isComposing)
        XCTAssertTrue(predicted.showsCandidateBar)
        XCTAssertTrue(predicted.showsExpandedArea)
        XCTAssertFalse(predicted.showsCompositionRow(.systemDefault))
        browser.reset(predicted)
        XCTAssertEqual(browser.entries.map(\.candidate.text), ["world"])
        XCTAssertEqual(browser.generation?.isComposing, false)
        XCTAssertEqual(browser.generation?.isPrediction, true)
        XCTAssertEqual(browser.nextPageToLoad, 1)
        XCTAssertTrue(browser.canAppend(pageIndex: 1))
        XCTAssertEqual(
            browser.append(
                pageIndex: 1,
                result: .page([Candidate(index: 0, text: "again")]),
                pageSize: 5), .appended)
        XCTAssertEqual(browser.entries.map(\.candidate.text), ["world", "again"])
        let predictionIdentity = browser.generation
        var composingSnapshot = predictionSnapshot
        composingSnapshot.isPrediction = false
        composingSnapshot.isComposing = true
        browser.reset(
            CandidatePresentationState(
                snapshot: composingSnapshot, isEnglishMode: false,
                revision: 21))
        XCTAssertNotEqual(browser.generation, predictionIdentity)
        XCTAssertNotEqual(browser.generation?.stableID, predictionIdentity?.stableID)
        XCTAssertEqual(browser.entries.map(\.text), ["world"], "menu-kind changes invalidate old pages")
        browser.reset(CandidatePresentationState(isEnglishMode: true))
        XCTAssertTrue(browser.isEmpty, "without engine candidates no previous word or guessed word may remain")
        browser.reset(
            CandidatePresentationState(
                candidates: [Candidate(index: 0, text: "ghost")],
                isComposing: false))
        XCTAssertTrue(
            browser.isEmpty, "standard Rime has no browsable menu that exists apart from a composition segment")
    }

    func testAbsoluteIndexContract() {
        // Cross-page absolute index = page number x page size + in-page index (not a concatenated-array position).
        XCTAssertEqual(BrowserCandidate.absoluteIndex(pageIndex: 0, pageLocalIndex: 2, pageSize: 5), 2)
        XCTAssertEqual(BrowserCandidate.absoluteIndex(pageIndex: 1, pageLocalIndex: 0, pageSize: 5), 5)
        XCTAssertEqual(BrowserCandidate.absoluteIndex(pageIndex: 2, pageLocalIndex: 4, pageSize: 5), 14)
        // No engine paging / invalid page number gives nil; the caller must degrade and never guess.
        XCTAssertNil(BrowserCandidate.absoluteIndex(pageIndex: 1, pageLocalIndex: 0, pageSize: 0))
        XCTAssertNil(BrowserCandidate.absoluteIndex(pageIndex: -1, pageLocalIndex: 0, pageSize: 5))
        XCTAssertNil(BrowserCandidate.absoluteIndex(pageIndex: 1, pageLocalIndex: -1, pageSize: 5))
    }

    func testVerifiedReadingSubsetKeepsAbsoluteSelectionAndNeverFallsBackToUnfilteredCandidates() {
        let state = CandidatePresentationState(
            candidates: [Candidate(index: 0, text: "原始首选")], pageIndex: 0, isComposing: true)
        let filtered = BrowserCandidate(
            pageIndex: 3, pageLocalIndex: 2,
            candidate: Candidate(
                index: 2, text: "已验证候选",
                comment: "kao lv", selectLabel: "③"))
        let sink = CandidateAreaActionSink { _ in }
        let context = CandidateAreaContext(
            state: state, bar: .systemDefault,
            actions: sink, typography: .standard,
            visibleEntries: [filtered], visibleHasMore: true,
            visibleFrontier: 18)
        XCTAssertEqual(context.displayEntries.map(\.text), ["已验证候选"])
        XCTAssertEqual(context.displayEntries.first?.comment, "kao lv")
        XCTAssertEqual(context.selectAction(filtered), .selectOnPage(page: 3, index: 2))
        XCTAssertEqual(context.entryFrontier, 18)
        XCTAssertTrue(context.hasMoreEntries)

        let noMatches = CandidateAreaContext(
            state: state, bar: .systemDefault,
            actions: sink, typography: .standard,
            visibleEntries: [], visibleHasMore: false)
        XCTAssertTrue(
            noMatches.displayEntries.isEmpty,
            "empty verified subset cannot silently expose the original engine page")
    }
}
