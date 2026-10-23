import CandidateKit
import Combine
import KeyboardCore
import LayoutKit
import SwiftUI

extension KeyboardPanelView {
    // MARK: Resident candidate area (stable height in Chinese mode; composition feedback via the presentation state machine)

    /// Fallback composition badge: a compact floating display of the whole composition text (commitTextPreview preferred).
    /// It has its own explicit width budget (`compositionBadgeWidthBudget`) and sits beside the candidates in the
    /// reserved right edge of the candidate row (HStack), never covering candidate text;
    /// nil (inline has taken over) shows nothing.
    private var compositionFallbackBadge: some View {
        Group {
            if let marked = controller.keyboardCompositionFallback, !marked.text.isEmpty {
                Text(marked.text)
                    .font(appearance.font(appearance.skin.typography.secondarySize))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(appearance.color("key")).opacity(0.92))
                    .overlay(
                        Capsule().strokeBorder(
                            appearance.color("border"), lineWidth: appearance.skin.keycap.borderWidth)
                    )
                    .foregroundStyle(Color(uiColor: appearance.text(on: "key", secondary: true)))
                    .accessibilityLabel("当前组合：\(marked.text)")
            }
        }
    }

    /// Width budget cap for the composition badge within the candidate row (40% of row width, absolute cap 200pt):
    /// a long composition is middle-truncated and never exceeds the budget to cover candidates; beyond the budget only candidates remain.
    private func compositionBadgeWidthBudget(rowWidth: CGFloat) -> CGFloat {
        min(rowWidth * 0.4, 200)
    }

    /// In-row compact status entry while candidates exist (errors/hints do not replace the whole row of candidates,
    /// which stay tappable; the entry stays 44pt wide and uses the candidate bar's height budget).
    private var statusEntryKey: some View {
        Button {
            onStatusDetails?()
        } label: {
            Image(systemName: "exclamationmark.circle")
                .font(appearance.font(appearance.controlIconSize))
                .foregroundStyle(appearance.accentForeground)
                .padding(.bottom, CGFloat(candidateContentLift) * 2)
                .frame(width: 44, height: candidateRowHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(KeyboardPressStyle())
        .accessibilityLabel(statusMessage ?? "状态详情")
        .accessibilityHint("打开详情与恢复操作")
    }

    /// Header layout family (9/14/26 facts merged): decides only the content kind and
    /// does not implement its own geometry/background/clipping. The disambiguation entry is **not** decided by it (see below).
    private var headerLayout: CandidateHeaderLayout {
        CandidateHeaderLayout(layout: controller.layout)
    }

    /// The content kind the fixed header must present for the current layout x state.
    /// Shares its source with `CandidateHeaderSurfacePolicy.content` -- production and tests use the same check;
    /// `isComposing` is not the only gate: `candidates.isEmpty` is the gate for candidate content.
    private var headerContent: CandidateHeaderContent {
        CandidateHeaderSurfacePolicy.content(
            layout: headerLayout,
            isEnglish: controller.isEnglishMode,
            isComposing: controller.snapshot.isComposing,
            hasCandidates: !controller.snapshot.candidates.isEmpty,
            hasStatus: statusMessage != nil || t9QuickSymbolsError != nil,
            isExpanded: showsAllCandidates)
    }

    /// Candidate/status surface shared by 9/14/26 (sole geometry owner):
    /// fixed height = configured budget; each content lays itself out within the budget, and the whole text block is never clipped.
    /// Candidate text and the key area each stay in place thanks to fixed frames; scrolling is managed by the candidates' own ScrollView.
    /// **Appears only with real content** (candidates / composition fallback / disambiguation / status); idle draws nothing.
    /// The background belongs to `KeyboardAppearance.headerBacking`: transparent under the system default (follows the iOS keyboard host),
    /// and only a custom skin covers the content area the product actually owns. The status-detail overlay appears only when explicitly opened.
    var compositionArea: some View {
        CandidateHeaderSurface(
            height: candidateRowHeight,
            backing: appearance.headerBacking
        ) {
            if controller.isEnglishMode && !controller.englishSuggestions.isEmpty && statusMessage == nil {
                englishSuggestionStrip
            } else if headerShowsRealContent {
                compositionAreaContent
                    .foregroundStyle(Color(uiColor: appearance.text(on: "panel")))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // Idle: draw no content (no fake caption bar). The fixed budget is kept; under the system default
                // the backing is transparent, showing the iOS keyboard host surface.
                Color.clear
            }
        }
        // Candidate cells hit-test their whole frame, not only the glyphs (see readingRow).
        .background(Color.black.opacity(0.001))
        .task(id: controller.readingFilter.revision) {
            if controller.snapshot.isComposing && controller.readingFilter.entries.isEmpty {
                controller.loadMoreReadings()
            }
        }
        .task(id: controller.readingFilter.nextIndex) {
            // A filter can have no matches in the first page. Advance the real
            // candidate frontier without requiring a second menu or a retry key.
            if controller.readingFilter.isFiltering && controller.readingFilter.matches.isEmpty
                && controller.readingFilter.hasMore && !controller.readingFilter.readFailed
            {
                await Task.yield()
                if !Task.isCancelled { controller.loadMoreReadings() }
            }
        }
    }

    /// ABC-page word suggestions: three equal-width slots (the system English keyboard's rhythm), the whole row replaced at once by engine results.
    /// Tapping replaces the word being typed and appends a space.
    private var englishSuggestionStrip: some View {
        HStack(spacing: 0) {
            ForEach(Array(controller.englishSuggestions.enumerated()), id: \.offset) { index, word in
                if index > 0 {
                    Rectangle()
                        .fill(Color(uiColor: appearance.text(on: "panel", secondary: true)).opacity(0.3))
                        .frame(width: 0.5, height: englishSuggestionRowHeight * 0.5)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, englishSuggestionRowHeight * 0.25)
                        .accessibilityHidden(true)
                }
                Button {
                    selectionFeedbackAfterEffect { controller.selectEnglishSuggestion(word) }
                } label: {
                    Text(word)
                        .font(appearance.font(appearance.skin.typography.candidateSize - 2))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, 6)
                        .frame(maxWidth: .infinity)
                        .frame(height: englishSuggestionRowHeight)
                        // The whole band stays tappable above the seated row.
                        .frame(maxHeight: candidateRowHeight, alignment: .bottom)
                        .contentShape(Rectangle())
                        .transaction { $0.animation = nil }
                }
                .buttonStyle(CandidateTapStyle(tint: Color(uiColor: appearance.text(on: "panel"))))
                .foregroundStyle(Color(uiColor: appearance.text(on: "panel")))
                .accessibilityLabel(word)
                .accessibilityHint("替换正在输入的单词")
            }
        }
        .frame(height: candidateRowHeight)
    }

    /// Content of the fixed surface, split by `headerContent` (shared policy). Branches decide only **content**;
    /// geometry/background belong to the surface, and no branch **changes the height**.
    /// Pure idle never gets here (idle draws `Color.clear` via `compositionArea`).
    @ViewBuilder
    private var compositionAreaContent: some View {
        activeHeaderContent
    }

    /// Real input content (candidates/status/disambiguation/composition fallback/reading filter).
    @ViewBuilder
    private var activeHeaderContent: some View {
        switch headerContent {
        case .compositionWithoutCandidates:
            Text("暂无候选字词，请按退格修改")
                .font(appearance.font(14))
                .foregroundStyle(Color(uiColor: appearance.text(on: "panel", secondary: true)))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: candidateRowHeight, alignment: .leading)
        case .idle:
            // The separate reading row may carry the picker while the word row stays empty.
            HStack(spacing: 8) {
                if controller.ambiguityPicker.showsPicker {
                    Spacer(minLength: 0)
                } else if controller.keyboardCompositionFallback != nil {
                    compositionFallbackBadge
                    Spacer(minLength: 0)
                } else {
                    // Only a real no-candidate state such as the reading filter remains: no layout/input-method entry is offered here
                    // (the extension only switches published user keyboards), so it stays read-only.
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
        case .status:
            if let error = t9QuickSymbolsError, statusMessage == nil {
                Button {
                    quickSymbols.reload()
                } label: {
                    Label("快捷符号未保存，轻点重试", systemImage: "exclamationmark.circle")
                        .font(appearance.font(14))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: candidateRowHeight, alignment: .leading)
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(error)
            } else if controller.isEnglishMode {
                statusRow(minHeight: candidateRowHeight)
            } else {
                // Errors/hints use the same fixed budget and do not compete for width with the standalone reading row or candidates.
                statusRow(minHeight: candidateRowHeight)
            }
        case .candidates, .candidatesExpanded:
            // With candidates: the candidate row stays resident and tappable; an error state never replaces usable candidates.
            // The fallback badge and the status entry sit side by side in the reserved right edge, each with an explicit width budget,
            // without overlapping candidate text; with neither shown the layout is unchanged.
            // Expand and collapse share the same fixed budget (the expanded area is in the key area and adds no header height).
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    candidateBar
                    Spacer(minLength: 0)
                    if statusMessage != nil, onStatusDetails != nil { statusEntryKey }
                    compositionFallbackBadge
                        .padding(.bottom, CGFloat(candidateContentLift) * 2)
                        .frame(
                            maxWidth: compositionBadgeWidthBudget(rowWidth: geometry.size.width),
                            alignment: .trailing)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .offset(
                    y: CGFloat(
                        layoutPlan.readingRowHeight > 0
                            ? CandidateReadingRowPolicy.candidateDrop : CandidateReadingRowPolicy.plainCandidateDrop))
            }
            // A GeometryReader pins its content to its top; bound it to the row so
            // the surface can seat the row on the band's bottom edge.
            .frame(height: candidateRowHeight)
        }
    }

    private func statusRow(minHeight: CGFloat) -> some View {
        Button(action: { onStatusDetails?() }) {
            Label(statusMessage ?? "", systemImage: "exclamationmark.circle")
                .font(.caption).lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .accessibilityLabel(statusMessage ?? "")
        .accessibilityHint("打开详情与恢复操作")
    }

    /// Standalone trusted reading row: a 32pt band granted by the host, above the fixed-height word candidate row, one font size smaller than candidates.
    /// Content is decided by `CandidateReadingRowContent.resolve`: a single-syllable segment first uses the lockable spelling reported by the engine;
    /// a multi-character composition (not covered by the disambiguation report) uses the engine readings of loaded real candidates for a read-only filter. With no content it is a transparent
    /// empty band (no "candidate reading" title or "none" placeholder). The background shares its source with the candidate bar
    /// (`headerBacking`: transparent by system default, a custom skin draws its own surface), with no blur layer on top.
    func readingRow(height: Double) -> some View {
        let displayed = displayedReadingRowContent
        let content = displayed.content
        return ZStack(alignment: .leading) {
            appearance.headerBacking
            // The scroller stays mounted across keys; only its cells change.
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 2) {
                    readingRowItems(content, height: height, interactive: displayed.interactive)
                }
                // A lazy stack kept cells from the previous content on screen (four
                // spelling options → two readings left `ni nu` ghosts that were no
                // longer buttons). New content rebuilds the stack.
                .id(content)
                .padding(.horizontal, 4)
            }
            .sharpCandidateScrollEdges()
            .scrollDisabled(content.isEmpty)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("读音")
            .accessibilityHidden(content.isEmpty)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        // Like the key area: iOS drops touches on fully transparent pixels, which left
        // only the reading glyphs tappable. An invisible surface gives each cell its
        // whole frame as the hit area.
        .background(Color.black.opacity(0.001))
    }

    private var liveReadingRowContent: CandidateReadingRowContent {
        CandidateReadingRowContent.resolve(
            reserved: readingRowReserved, eligible: readingRowEligibleNow,
            usesPickerUI: controller.usesAmbiguityPickerUI, picker: controller.ambiguityPicker,
            readings: controller.readingFilter)
    }

    /// Same hold as the phone rail: while a new key's spelling report or first
    /// reading page is outstanding, the previous readings stay visible but inert
    /// instead of the row blanking and refilling (and shifting) on every key.
    private var displayedReadingRowContent: (content: CandidateReadingRowContent, interactive: Bool) {
        if t9RailChoicesSettled || !controller.snapshot.isComposing { return (liveReadingRowContent, true) }
        return (heldReadingRowContent ?? .empty, false)
    }

    var settledReadingRowContent: CandidateReadingRowContent? {
        guard readingRowReserved, controller.snapshot.isComposing, t9RailChoicesSettled else { return nil }
        return liveReadingRowContent
    }

    /// One reading cell: the whole cell (minimum width x row height) is the hit area, and the pressed fill does not obscure the text.
    private func readingRowCell<Label: View>(
        height: Double, interactive: Bool, action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button {
            selectionFeedbackAfterEffect(action)
        } label: {
            label()
                // Cells are positional: new text replaces old in one frame instead of
                // an implicit cross-fade ghosting two readings over each other.
                .transaction { $0.animation = nil }
                .padding(.horizontal, CGFloat(CandidateReadingRowPolicy.cellPaddingX))
                // Sits `textDrop` below centre, towards the word row it filters.
                .padding(.top, CGFloat(CandidateReadingRowPolicy.textTopPadding(rowHeight: height)))
                .frame(
                    minWidth: CGFloat(CandidateReadingRowPolicy.minimumCellWidth),
                    minHeight: height, maxHeight: height
                )
                .contentShape(Rectangle())
        }
        // Press backing only: a reading tap reorders the row, so a flash left at the
        // finger would sit on a different reading. The accent selection is the result.
        .buttonStyle(
            CandidatePressStyle(
                tint: Color(uiColor: appearance.text(on: "panel")),
                extraTopInset: CGFloat(CandidateReadingRowPolicy.textTopPadding(rowHeight: height)))
        )
        // Readings are choices, not captions: primary text colour, like candidates.
        .foregroundStyle(Color(uiColor: appearance.text(on: "panel")))
        .disabled(!interactive)
    }

    @ViewBuilder
    private func readingRowItems(
        _ content: CandidateReadingRowContent, height: Double,
        interactive: Bool
    ) -> some View {
        let font = appearance.font(
            verticalSizeClass == .compact
                ? CandidateReadingRowPolicy.compactFontSize : CandidateReadingRowPolicy.fontSize)
        switch content {
        case .empty:
            EmptyView()
        case .options(let options):
            // Positional identity: a reordered list rebuilds cells in place instead of
            // moving live buttons, whose hit areas were observed to stay behind.
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                readingRowCell(
                    height: height, interactive: interactive, action: { controller.selectAmbiguityOption(option) }
                ) {
                    Text(option).font(font).lineLimit(1)
                }
                .accessibilityLabel("锁定组合 \(option)")
                .accessibilityInputLabels([Text(verbatim: option), Text("锁定组合 \(option)")])
            }
        case .locked(let chosen):
            // Backspace undoes the lock (`KeyboardController.handleBackspaceTap`).
            readingRowSelection(chosen, font: font, height: height)
                .accessibilityLabel("已锁定组合 \(chosen)")
                .accessibilityHint("按删除键撤销组合")
        case .readings(let selected, let options):
            if !selected.isEmpty {
                // Backspace cancels the last syllable (`KeyboardController.handleBackspaceTap`).
                readingRowSelection(selected.joined(separator: " "), font: font, height: height)
                    .accessibilityLabel("已选读音 \(selected.joined(separator: " "))")
                    .accessibilityHint("按删除键取消上一音节")
            }
            ForEach(Array(options.enumerated()), id: \.offset) { _, reading in
                readingRowCell(height: height, interactive: interactive, action: { controller.selectReading(reading) })
                {
                    Text(reading).font(font).lineLimit(1)
                }
                .accessibilityLabel("选择读音 \(reading)")
                .accessibilityInputLabels([Text(verbatim: reading), Text("选择读音 \(reading)")])
            }
            // Only reached when scrolled to the end: reads the next real candidate
            // page instead of decoding the whole list up front.
            if interactive && controller.readingFilter.hasMore && !controller.readingFilter.readFailed
                && !controller.readingPrefetchSatisfied
            {
                Color.clear.frame(width: 1, height: height)
                    .task(id: controller.readingFilter.nextIndex) {
                        if !Task.isCancelled { controller.loadMoreReadings() }
                    }
            }
        }
    }

    /// An applied choice (locked spelling or selected reading prefix): accent color, not tappable.
    private func readingRowSelection(_ text: String, font: Font, height: Double) -> some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .padding(.horizontal, CGFloat(CandidateReadingRowPolicy.cellPaddingX))
            .padding(.top, CGFloat(CandidateReadingRowPolicy.textTopPadding(rowHeight: height)))
            .frame(
                minWidth: CGFloat(CandidateReadingRowPolicy.minimumCellWidth),
                minHeight: height, maxHeight: height
            )
            .foregroundStyle(appearance.accentForeground)
    }

    /// English-state top-row text is only for status display in English mode with no candidates (outside the resident budget, at natural English height).
    private var preeditText: String {
        if controller.isEnglishMode {
            switch controller.shiftState {
            case .off: return "英文 · 小写"
            case .once: return "英文 · 下一字母大写"
            case .locked: return "英文 · 大写锁定"
            }
        }
        if controller.snapshot.preedit.isEmpty {
            return controller.showsDemoBanner ? "演示模式" : "中文"
        }
        return controller.snapshot.preedit
    }

    /// Spoken Chinese composition: prefers the whole marked preview, falling back to the engine preedit.
    private var preeditAccessibilityLabel: String {
        if !controller.snapshot.isComposing, let statusMessage { return statusMessage }
        if controller.isEnglishMode { return preeditText }
        if let fallback = controller.keyboardCompositionFallback, !fallback.text.isEmpty {
            return "正在组合：\(fallback.text)"
        }
        return controller.snapshot.preedit.isEmpty ? "尚未输入" : "正在组合：\(controller.snapshot.preedit)"
    }

    /// Shown only when the shared content policy confirms real candidates; the effective paging and expand controls share the current page state.
    /// Rendering goes through the CandidateKit default renderer (parameters from the user's candidate-area config), and actions go via
    /// CandidateAreaActionSink -> the real session; expand/collapse are local UI state.
    /// In the expanded state the renderer shows a light title and a collapse control, and candidates appear only once, in the browse area below.
    @ViewBuilder
    var candidateBar: some View {
        // Only mounted by activeHeaderContent's .candidates branches. The
        // resolved policy has already checked the real engine snapshot, so no
        // second English/ASCII predicate may hide its candidates here.
        candidateRendererView(expanded: false)
    }
}
