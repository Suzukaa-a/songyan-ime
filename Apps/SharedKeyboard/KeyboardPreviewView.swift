import CandidateKit
import KeyboardCore
import LayoutKit
import SkinKit
import SwiftUI

/// Presentation-only adapter: shares native key faces with the live panel, without a session or engine.
/// `candidateBar` and `skin` come from the same appearance item: the preview must also show the candidate-area layout,
/// otherwise "keyboard appearance" would read as colors only.
public struct KeyboardPreviewView: View {
    public let layout: LayoutDefinition
    public var skin: SkinDefinition
    public var candidateBar: CandidateBarDefinition
    public var previewDark: Bool?
    private let onSelectKey: ((LayoutKeyPath) -> Void)?
    private let pageDefinition: KeyboardPageDefinition?
    private let pageUsesPhoneLayout: Bool
    private let onSelectCategoryKey: ((String, Int) -> Void)?
    private let selectedCategoryKey: (String, Int)?
    @State private var categoryPreference = false
    /// The preview's real width: a split preview follows the same whole-surface decision as the keyboard.
    @State private var previewWidth: CGFloat = 0
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var keyHeight: CGFloat { verticalSizeClass == .compact ? 44 : 54 }
    /// Width of the merged pad's separator/Delete pair; mirrors `KeyboardPanelView.sharedDeleteWidth`
    /// so a floating preview keeps exactly the live pad's geometry.
    private func mergedSideWidth(for width: CGFloat) -> CGFloat { max(56, (width - 32) / 10 * 1.8) }
    @State private var mode = "中文"
    @State private var sample = "空闲"
    @State private var inspected: LayoutKey?
    public init(
        layout: LayoutDefinition, pageDefinition: KeyboardPageDefinition? = nil, pageUsesPhoneLayout: Bool = false,
        skin: SkinDefinition = .systemDefault,
        candidateBar: CandidateBarDefinition = .systemDefault,
        previewDark: Bool? = nil, onSelectKey: ((LayoutKeyPath) -> Void)? = nil,
        onSelectCategoryKey: ((String, Int) -> Void)? = nil, selectedCategoryKey: (String, Int)? = nil
    ) {
        self.layout = layout
        self.skin = skin
        self.candidateBar = candidateBar
        self.previewDark = previewDark
        self.onSelectKey = onSelectKey
        self.pageDefinition = pageDefinition
        self.pageUsesPhoneLayout = pageUsesPhoneLayout
        self.onSelectCategoryKey = onSelectCategoryKey
        self.selectedCategoryKey = selectedCategoryKey
    }
    private var appearance: KeyboardAppearance { .init(skin: skin, dark: previewDark ?? (colorScheme == .dark)) }
    private var editing: Bool { onSelectKey != nil }
    private var definition: LayoutDefinition {
        !editing && mode == "英文" ? BuiltinLayouts.qwerty26.settingSplit(layout.split) : layout
    }
    private var activeSplit: ActiveLayoutSplit? {
        definition.split?.resolved(forWidth: Double(previewWidth))
    }
    /// The bundled preset whose shape this definition has. Shape, not full equality: a copy that only
    /// renames or re-ids keeps its preset chrome, while an edited row changes `rows` and falls back
    /// to the definition's own weights.
    private var preset: LayoutDefinition? {
        // Full input identity, including the schema binding: a schema-bound or imported layout
        // whose rows happen to equal a preset must not make the preview draw a native shell that
        // the runtime's strict predicates would reject.
        BuiltinLayouts.all.first {
            $0.input == definition.input
                && $0.rows == definition.rows && $0.auxiliaryAreas == definition.auxiliaryAreas
        }
    }
    /// Same structural identity as the runtime: main-row faces/metadata may differ, while the
    /// native merged columns and synthesized separator/Delete stay.
    private var merged: Bool {
        preset?.id == BuiltinLayouts.merged14.id || preset?.id == BuiltinLayouts.merged18.id
            || BuiltinLayouts.matchesMainShell(definition, as: .merged14)
            || BuiltinLayouts.matchesMainShell(definition, as: .merged18)
    }
    /// Same structural identity as the runtime: Chinese keeps the standard 26-key shell after
    /// metadata edits; English always uses the built-in English shell.
    private var qwerty: Bool {
        preset?.id == BuiltinLayouts.qwerty26.id || BuiltinLayouts.matchesMainShell(definition, as: .qwerty26)
    }
    /// Structural phone shell selection mirrors the runtime's `PhoneKeypadStructure` decision.
    private var phoneShape: Bool {
        preset?.id == BuiltinLayouts.phone9.id || PhoneKeypadStructure.matches(definition)
    }
    /// Only the narrow visual identity draws the shell's own fixed rails/control row; an edited
    /// footer/rail or main-row face keeps the T9 shell but renders the authored regions.
    private var phoneVisual: Bool {
        preset?.id == BuiltinLayouts.phone9.id || BuiltinLayouts.matchesPhone9VisualShell(definition)
    }
    private var phone: Bool { phoneShape }
    private var bundledControlRowPolicy: Bool {
        [.qwerty26, .merged14, .merged18].contains { BuiltinLayouts.matchesControlRowPolicy(definition, as: $0) }
    }
    private var controls: Bool {
        definition.rows.last?.keys.allSatisfy { $0.action.type != .code && $0.action.type != .literal } == true
    }
    private var mainRows: [LayoutRow] { controls ? Array(definition.rows.dropLast()) : definition.rows }
    private var composing: Bool { !editing && mode != "英文" && (sample == "组合" || sample == "展开") }
    private var expanded: Bool { composing && sample == "展开" }
    private var returnTitle: String { composing ? "确认" : "换行" }
    private var previewAlternates: [LayoutOption] {
        inspected?.longPress ?? definition.rows.flatMap(\.keys).first(where: { !($0.longPress ?? []).isEmpty })?
            .longPress ?? []
    }
    private var previewAlternateWidth: CGFloat {
        // Same text-measured 44...72pt cells as CharacterButton.showAlternates.
        let font = appearance.uiFont(min(20, appearance.skin.typography.keySize))
        let textWidth = previewAlternates.reduce(CGFloat.zero) {
            max($0, ($1.label as NSString).size(withAttributes: [.font: font]).width)
        }
        return max(44, min(72, textWidth + 20))
    }
    private var previewControlPolicy: KeyboardControlPolicy {
        // Matches production: on the built-in 9-key layout the confirm key sits in the right trailing column, so the bottom row has no duplicate Return.
        // The number page has no trailing column, so Return goes back to the shared control row.
        let hasPhoneRail = phone && mode != "数字"
        return .init(
            page: mode == "数字" ? .numeric : .letters,
            isEnglishMode: mode == "英文", hasGlobe: false,
            isPhoneLayout: hasPhoneRail, usesASCIIPunctuation: mode == "英文",
            includesBottomEnter: !hasPhoneRail)
    }
    private var previewControlRow: some View { previewControlRow(columns: nil) }
    private func previewControlRow(columns: KeyboardControlPolicy.PhoneColumns?) -> some View {
        ControlRow(
            policy: previewControlPolicy,
            returnTitle: returnTitle, layoutName: nil, layoutHintName: nil, layoutHintToken: nil,
            modeKey: AlternateCharacterKey(
                cap: .init(
                    id: "mode", title: previewControlPolicy.languageTitle,
                    subtitle: mode == "数字" ? "返回" : nil,
                    action: .cycleLayout), alternates: [], layoutPicker: true
            ) { _ in },
            systemKeyboardSwitch: nil, moveCursor: nil, onPage: { _ in },
            onKey: { _ in }, phoneColumns: columns, split: activeSplit, splitRowIndex: mainRows.count)
    }
    public var body: some View {
        VStack(spacing: 6) {
            if !editing && pageDefinition == nil {
                Picker("示例语言", selection: $mode) { ForEach(["中文", "英文", "数字"], id: \.self) { Text($0) } }.pickerStyle(
                    .segmented)
                Picker("示例状态", selection: $sample) { ForEach(["空闲", "组合", "展开", "长按"], id: \.self) { Text($0) } }
                    .pickerStyle(.segmented)
            }
            if let pageDefinition, pageDefinition.numericPresentation == .automatic {
                // The built-in 123 page owns this content (its marks and keypad shape follow the
                // live keyboard), so drawing rows here would preview a page the keyboard never shows.
                KeyboardPagePreviewView(
                    page: pageDefinition, inheritedSplit: layout.split, isPhoneLayout: pageUsesPhoneLayout)
            } else if let pageDefinition {
                authoredPageCanvas(pageDefinition)
            } else {
                canvas
            }
            if editing && pageDefinition == nil {
                Text("选择要修改的按键").font(.caption).foregroundStyle(.secondary).frame(
                    maxWidth: .infinity, alignment: .leading)
            }
        }
        .environment(\.keyboardAppearance, appearance)
        .environment(\.keyboardKeyHeight, keyHeight)
        .modifier(PreviewWidthProbe(width: $previewWidth))
        .onChange(of: layout) { inspected = nil }
        .onAppear { categoryPreference = KeyboardSymbolPagePreferences.usesCategoryPage }
    }
    private var canvas: some View {
        VStack(spacing: 0) {
            Group {
                Group {
                    if composing { candidateArea(expanded: false) } else { Color.clear }
                }.frame(
                    height: CandidateBarDefinition.Collapsed.effectiveHeight(
                        candidateBar.collapsed.height,
                        candidateSize: appearance.skin.typography.candidateSize))
            }
            VStack(spacing: 4) {
                if phone && !editing && mode != "数字" {
                    phonePreview
                } else {
                    if expanded {
                        candidateArea(expanded: true).frame(height: keyHeight * 3 + 8)
                    } else if mode == "数字" && !editing {
                        numericRows
                    } else {
                        mainRowsArea
                    }
                    if !editing
                        && (mode == "数字" || expanded
                            || ((merged || qwerty) && bundledControlRowPolicy))
                    {
                        previewControlRow
                    } else {
                        HStack(spacing: 4) {
                            if controls {
                                controlRowPreview
                            }
                            if !editing {
                                AlternateCharacterKey(
                                    cap: .init(id: "mode", title: "ABC", action: .cycleLayout), alternates: [],
                                    layoutPicker: true
                                ) { _ in }.frame(width: 44, height: keyHeight)
                            }
                        }
                    }
                }
            }
            if sample == "长按", !editing {
                LazyVGrid(
                    columns: [
                        GridItem(.adaptive(minimum: previewAlternateWidth, maximum: previewAlternateWidth), spacing: 4)
                    ], alignment: .leading, spacing: 0
                ) {
                    ForEach(Array(previewAlternates.enumerated()), id: \.offset) { _, option in
                        AlternateCharacterKey(
                            cap: .init(id: option.label, title: option.label, action: action(option.action)),
                            alternates: []
                        ) { _ in }.frame(height: 46)
                    }
                }.padding(.horizontal, 6).padding(.top, 4)
            }
        }.padding(4).background(appearance.background).clipShape(RoundedRectangle(cornerRadius: 8))
    }
    /// The 123 page mirrors the live symbol page: ten equal columns, and a nine-character third row
    /// that gives Delete one column of its own, so no symbol is narrower than a 26-key letter.
    private var numericRows: some View {
        ForEach(Array(SymbolPageTable.numericRows(ascii: false).enumerated()), id: \.offset) { index, row in
            GeometryReader { proxy in
                let metrics = StandardKeyRowGeometry(width: Double(proxy.size.width), split: activeSplit)
                HStack(spacing: 4) {
                    WeightedKeyRow(
                        caps: row.caps, split: activeSplit, rowIndex: index,
                        fixedKeyWidth: CGFloat(metrics.keyWidth), splitGap: CGFloat(metrics.gap)
                    ) { _ in }
                    .frame(
                        width: index == 2 ? max(0, proxy.size.width - CGFloat(metrics.keyWidth) - 4) : proxy.size.width)
                    if index == 2 {
                        RepeatingDeleteKey {}.frame(width: CGFloat(metrics.keyWidth), height: keyHeight)
                    }
                }
            }.frame(height: keyHeight)
        }
    }
    private var phonePreview: some View {
        StablePhoneKeypadShell(
            trailingSpansControlRow: phoneVisual,
            expandsForSplit: activeSplit != nil,
            leading: { metrics in
                if phoneVisual {
                    bundledPhoneLeading(metrics)
                } else {
                    authoredPhoneRail(.leading, metrics: metrics)
                }
            },
            main: { metrics in
                if expanded {
                    candidateArea(expanded: true).frame(height: CGFloat(metrics.mainHeight))
                } else {
                    VStack(spacing: CGFloat(metrics.spacing)) {
                        ForEach(Array(mainRows.enumerated()), id: \.offset) { index, _ in
                            configuredRow(index)
                        }
                    }
                }
            },
            trailing: { metrics in
                if phoneVisual {
                    bundledPhoneTrailing(metrics)
                } else {
                    authoredPhoneRail(.trailing, metrics: metrics)
                }
            },
            bottom: { metrics in
                if phoneVisual {
                    previewControlRow(columns: .init(rail: metrics.railWidth, digit: metrics.digitWidth))
                } else {
                    authoredPhoneFooter(metrics)
                }
            })
    }

    /// The bundled T9 leading column: reading placeholders while composing, otherwise the three
    /// quick-symbol slots with the first slot opening the remaining menu.
    private func bundledPhoneLeading(_ metrics: PhoneKeypadMetrics) -> some View {
        VStack(spacing: CGFloat(metrics.spacing)) {
            if composing {
                Text("拼音选项").font(.caption2).multilineTextAlignment(.center)
            } else {
                let caps = SymbolPageTable.quickRail(symbols: T9QuickSymbolStore.defaultSymbols, ascii: false)
                ForEach(Array(caps.prefix(3).enumerated()), id: \.element.id) { index, cap in
                    AlternateCharacterKey(
                        cap: cap,
                        alternates: index == 0 ? Array(caps.dropFirst(3)) : [],
                        phoneKey: true, phoneSideKey: true
                    ) { _ in }
                    .frame(height: CGFloat(metrics.rowHeight))
                }
            }
        }
    }

    /// The bundled T9 trailing column (Delete / 重输 / Return).
    private func bundledPhoneTrailing(_ metrics: PhoneKeypadMetrics) -> some View {
        let slots = metrics.railSlots(.trailing, spans: PhoneKeypadRailPolicy.bundledTrailingSpans)
        return VStack(spacing: CGFloat(metrics.spacing)) {
            RepeatingDeleteKey {}.frame(height: CGFloat(slots[0].height))
            ControlKeyFace(text: "重输").frame(height: CGFloat(slots[1].height))
                .opacity(composing ? 1 : 0.45)
            ReturnKey(title: returnTitle) { _ in }.frame(height: CGFloat(slots[2].height))
        }
    }

    /// An edited T9 rail is rendered from its declaration, with the same slot spans the runtime uses.
    private func authoredRailEntries(
        _ position: LayoutAuxiliaryArea.Position
    ) -> [(LayoutKeyPath, LayoutKey)] {
        var entries: [(LayoutKeyPath, LayoutKey)] = []
        for (area, value) in (definition.auxiliaryAreas ?? []).enumerated()
        where value.position == position && !value.requiresEngineDisambiguation {
            for (index, key) in value.keys.enumerated() {
                entries.append((LayoutKeyPath.auxiliary(area, key: index), key))
            }
        }
        return entries
    }

    @ViewBuilder
    private func authoredPhoneRail(
        _ position: LayoutAuxiliaryArea.Position, metrics: PhoneKeypadMetrics
    ) -> some View {
        let entries = authoredRailEntries(position)
        if entries.isEmpty {
            if position == .leading, composing {
                Text("拼音选项").font(.caption2).multilineTextAlignment(.center)
                    .frame(width: CGFloat(metrics.railWidth))
            } else {
                Color.clear
            }
        } else {
            let spans = PhoneKeypadMetrics.slotSpans(
                keyCount: entries.count, rowCount: PhoneKeypadMetrics.mainRowCount)
            let slots = metrics.railSlots(position == .leading ? .leading : .trailing, spans: spans)
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: CGFloat(metrics.spacing)) {
                    if position == .leading, composing {
                        Text("拼音选项").font(.caption2).multilineTextAlignment(.center)
                    }
                    ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                        keyFace(entry, side: true)
                            .frame(height: CGFloat(slots[index].height))
                    }
                }
            }
            .sharpCandidateScrollEdges()
        }
    }

    /// An edited T9 footer renders the authored control row; shortcuts are de-duplicated against
    /// entries the author already declared, matching the live author bar.
    private func authoredPhoneFooter(_ metrics: PhoneKeypadMetrics) -> some View {
        let keys = controls ? (definition.rows.last?.keys ?? []) : []
        let hasNumeric = keys.contains { $0.action.pageSwitchTarget == .numeric }
        let hasSymbols = keys.contains { $0.action.pageSwitchTarget == .symbols }
        let hasLayout = keys.contains { $0.action.type == .modeSwitch }
        return HStack(spacing: CGFloat(metrics.spacing)) {
            if !hasNumeric { previewFooterShortcut("123") }
            if !hasSymbols { previewFooterShortcut(KeyboardControlPolicy.symbolPageTitle) }
            if let last = definition.rows.indices.last {
                ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                    keyFace((.row(last, key: index), key))
                        .frame(maxWidth: .infinity)
                }
            }
            if !hasLayout {
                AlternateCharacterKey(
                    cap: .init(id: "preview-mode", title: "ABC", action: .cycleLayout),
                    alternates: [], layoutPicker: true
                ) { _ in }
                .frame(width: 44)
            }
        }
        .frame(height: CGFloat(metrics.rowHeight))
        .padding(.horizontal, 4)
    }

    private func previewFooterShortcut(_ title: String) -> some View {
        AlternateCharacterKey(
            cap: .init(id: "preview-footer-\(title)", title: title, action: .cycleLayout),
            alternates: []
        ) { _ in }
        .frame(width: 44)
    }

    private func mergedPreviewRow(_ index: Int) -> some View {
        let row = mainRows[index].keys.enumerated().map { (LayoutKeyPath.row(index, key: $0.offset), $0.element) }
        let isLast = index == mainRows.count - 1
        return GeometryReader { proxy in
            let side = mergedSideWidth(for: proxy.size.width)
            let gap = CGFloat(
                activeSplit?.gap(
                    width: Double(proxy.size.width), keyCount: (mainRows.map { $0.keys.count }.max() ?? 1) + 2)
                    ?? 0)
            let boundary = activeSplit?.breakIndex(row: index, keyCount: row.count)
            // Same shell and widths as the live merged pad: separator in the Shift slot, weighted caps.
            let metrics = MergedKeypadGeometry.rows(
                weights: mainRows.map { $0.keys.map(\.widthWeight) },
                width: max(0, proxy.size.width - gap), spacing: 4, sideWidth: side)
            HStack(spacing: 4) {
                if isLast { ControlKeyFace(text: "分词").frame(width: side) }
                ForEach(Array(row.enumerated()), id: \.offset) { keyIndex, entry in
                    if keyIndex == boundary, gap > 0 {
                        KeyboardSplitGap().frame(width: gap - 4, height: keyHeight)
                    }
                    keyFace(entry).frame(width: metrics[index].keyWidths[keyIndex], height: keyHeight)
                }
                if isLast { RepeatingDeleteKey {}.frame(width: side) }
            }
            .frame(width: proxy.size.width)
        }.frame(height: keyHeight)
    }

    @ViewBuilder private func auxiliary(_ position: LayoutAuxiliaryArea.Position) -> some View {
        let keys: [(LayoutKeyPath, LayoutKey)] = (definition.auxiliaryAreas ?? []).enumerated().flatMap { area, value in
            value.position == position && !value.requiresEngineDisambiguation
                ? value.keys.enumerated().compactMap { index, key in
                    !editing && (key.action.type == .globe || (phone && key.action.type == .enter))
                        ? nil : (LayoutKeyPath.auxiliary(area, key: index), key)
                } : []
        }
        if !keys.isEmpty {
            VStack(spacing: 4) {
                ForEach(Array(keys.enumerated()), id: \.offset) { _, entry in keyFace(entry, side: true) }
            }
            .frame(width: 44, height: CGFloat(mainRows.count) * (keyHeight + 4) - 4)
        }
    }
    /// Main area of the row-shaped layouts: the 26-key page and a phone page both render one row per
    /// definition row, so a page and a keyboard read the same. A non-preset definition keeps its own weights.
    private var mainRowsArea: some View {
        ScrollView {
            HStack(spacing: 4) {
                auxiliary(.leading)
                VStack(spacing: 4) {
                    ForEach(Array(mainRows.enumerated()), id: \.offset) { index, _ in
                        if qwerty {
                            standardQwertyRow(index)
                        } else if merged {
                            mergedPreviewRow(index)
                        } else {
                            configuredRow(index)
                        }
                    }
                }
                auxiliary(.trailing)
            }
        }.scrollDisabled(mainRows.count <= 3)
            .frame(height: CGFloat(min(3, max(1, mainRows.count))) * (keyHeight + 4) - 4)
    }

    /// The bundled 26-key letter page: its 26 letters share one equal width, Shift opens and Delete
    /// closes the third row, and the split gap and per-row break follow the available width exactly
    /// as the live keypad does. Only a preset-shaped definition reaches this branch.
    private func standardQwertyRow(_ index: Int) -> some View {
        GeometryReader { proxy in
            // One geometry for the whole row: the side keys and the letter run share it, so the
            // third row absorbs exactly the space the ten-column letter grid leaves over.
            let metrics = StandardKeyRowGeometry(width: Double(proxy.size.width), split: activeSplit)
            if index == 2 {
                HStack(spacing: 4) {
                    // The live Shift key face; the preview has no session, so nothing is wired to it.
                    ShiftKey(state: .off, tap: {}, doubleTap: {})
                        .frame(width: CGFloat(metrics.thirdRowSideWidth), height: keyHeight)
                    standardRow(index, metrics: metrics)
                    RepeatingDeleteKey {}.frame(width: CGFloat(metrics.thirdRowSideWidth), height: keyHeight)
                }
            } else {
                standardRow(index, metrics: metrics)
            }
        }.frame(height: keyHeight)
    }

    /// One equal-width letter run: `metrics.keyWidth` for every key, the split gap at the row’s
    /// own break, and a centred inset so the first two rows keep the 26-key stagger shape.
    private func standardRow(_ index: Int, metrics: StandardKeyRowGeometry) -> some View {
        let keys = visibleEntries(index)
        return GeometryReader { proxy in
            let gap = CGFloat(metrics.gap)
            let boundary = activeSplit?.breakIndex(row: index, keyCount: keys.count)
            let available = max(0, proxy.size.width - CGFloat(max(0, keys.count - 1)) * 4 - gap)
            HStack(spacing: 4) {
                ForEach(Array(keys.enumerated()), id: \.offset) { keyIndex, entry in
                    if keyIndex == boundary, gap > 0 {
                        KeyboardSplitGap().frame(width: gap - 4, height: keyHeight)
                    }
                    keyFace(entry).frame(width: CGFloat(metrics.keyWidth), height: keyHeight)
                }
            }
            .padding(.horizontal, max(0, (available - CGFloat(metrics.keyWidth) * CGFloat(keys.count)) / 2))
            .frame(width: proxy.size.width, alignment: .center)
        }
    }

    /// A non-preset row keeps the weights the definition declares. The third row of a 9-key pad
    /// carries what the definition authors, so a DIY width is never silently turned into a column.
    private func configuredRow(_ index: Int) -> some View {
        let keys = visibleEntries(index)
        let projection = LayoutRowWidthProjection(weights: keys.map { $0.1.widthWeight })
        return GeometryReader { proxy in
            let count = max(1, keys.count)
            let gap = CGFloat(activeSplit?.gap(width: Double(proxy.size.width), keyCount: count) ?? 0)
            let boundary = activeSplit?.breakIndex(row: index, keyCount: count)
            let available = max(0, proxy.size.width - CGFloat(max(0, count - 1)) * 4 - gap)
            HStack(spacing: 4) {
                ForEach(Array(keys.enumerated()), id: \.offset) { keyIndex, entry in
                    if keyIndex == boundary, gap > 0 {
                        KeyboardSplitGap().frame(width: gap - 4, height: keyHeight)
                    }
                    keyFace(entry).frame(
                        width: available * CGFloat(projection.keyFractions[keyIndex]), height: keyHeight)
                }
            }
            .padding(.horizontal, available * CGFloat(projection.insetFraction))
            .frame(width: proxy.size.width, alignment: .center)
        }.frame(height: keyHeight)
    }

    /// The definition's own control row, drawn as the live panel draws it: every declared key stays
    /// in place and keeps its action, and the row's keys share the width it declares.
    @ViewBuilder private var controlRowPreview: some View {
        if let last = definition.rows.last, let split = activeSplit {
            let row = definition.rows.count - 1
            let boundary = split.breakIndex(row: row, keyCount: last.keys.count)
            let visible = last.keys.indices.filter {
                last.keys[$0].action.type != .space && (editing || last.keys[$0].action.type != .globe)
            }
            let left = visible.filter { $0 < boundary }
            let right = visible.filter { $0 >= boundary }
            SplitSpaceKeyboardRow(
                leftKeys: left, rightKeys: right,
                leftWidths: left.map { max(44, last.keys[$0].widthWeight * 44) },
                rightWidths: right.map { max(44, last.keys[$0].widthWeight * 44) }, split: split,
                spaceWidthMultiplier: 3 * (last.keys.first { $0.action.type == .space }?.widthWeight ?? 4) / 4,
                key: { keyFace((.row(row, key: $0), last.keys[$0])) },
                space: {
                    if let index = last.keys.firstIndex(where: { $0.action.type == .space }) {
                        keyFace((.row(row, key: index), last.keys[index]))
                    } else {
                        ControlKeyFace(text: "空格")
                    }
                }, fallback: { singleSpaceControlRowPreview })
        } else {
            singleSpaceControlRowPreview
        }
    }

    @ViewBuilder private var singleSpaceControlRowPreview: some View {
        if let last = definition.rows.last {
            let index = definition.rows.count - 1
            let entries = last.keys.enumerated().compactMap { offset, key -> (LayoutKeyPath, LayoutKey)? in
                editing || key.action.type != .globe
                    ? (LayoutKeyPath.row(index, key: offset), key) : nil
            }
            GeometryReader { proxy in
                let projection = LayoutRowWidthProjection(weights: entries.map { $0.1.widthWeight })
                let minimum: CGFloat = editing ? 0 : 44
                let available = max(0, proxy.size.width - CGFloat(max(0, entries.count - 1)) * 4)
                let remainder = max(0, available - CGFloat(entries.count) * minimum)
                HStack(spacing: 4) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { offset, entry in
                        keyFace(entry).frame(
                            width: minimum + remainder * CGFloat(projection.keyFractions[offset]),
                            height: keyHeight)
                    }
                }
                .frame(width: proxy.size.width, alignment: .center)
            }.frame(height: keyHeight)
        }
    }

    @ViewBuilder
    private func authoredPageCanvas(_ page: KeyboardPageDefinition) -> some View {
        let browser =
            page.usesSymbolBrowser
            && (page.symbolPresentation != .automatic || pageUsesPhoneLayout || categoryPreference)
        if browser {
            KeyboardCategoryPagePreview(
                page: page, split: activeSplit,
                key: { key, category, index in
                    keyFace((.row(0, key: index), key), onSelect: { onSelectCategoryKey?(category, index) })
                        .overlay {
                            if selectedCategoryKey?.0 == category && selectedCategoryKey?.1 == index {
                                RoundedRectangle(cornerRadius: appearance.skin.keycap.cornerRadius)
                                    .stroke(Color.accentColor, lineWidth: 2).allowsHitTesting(false)
                            }
                        }
                },
                footer: { metrics, split in
                    authoredPageControlRow(
                        page, browser: true, split: split,
                        columns: .init(rail: metrics.railWidth, digit: metrics.digitWidth))
                }
            )
            .padding(4).background(Color(uiColor: .systemGray5), in: RoundedRectangle(cornerRadius: 8))
        } else {
            let source = page.symbolPresentation == .automatic ? KeyboardPagePresets.symbolsChinese : page
            VStack(spacing: 4) {
                ScrollView {
                    VStack(spacing: 4) {
                        KeyboardPageRows(
                            page: source, split: activeSplit,
                            key: { key, row, index in keyFace((.row(row, key: index), key)) },
                            shift: { ShiftKey(state: .off, isEnglishMode: true, tap: {}, doubleTap: {}) },
                            delete: { RepeatingDeleteKey {} })
                    }
                }.scrollDisabled(source.rows.count <= 3)
                    .frame(height: keyHeight * 3 + 8, alignment: .top)
                authoredPageControlRow(source, browser: false, split: activeSplit, columns: nil)
            }.padding(4).background(Color(uiColor: .systemGray5), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func authoredPageControlRow(
        _ page: KeyboardPageDefinition, browser: Bool, split: ActiveLayoutSplit?,
        columns: KeyboardControlPolicy.PhoneColumns?
    ) -> some View {
        let policy = KeyboardControlPolicy(
            page: page.kind == .english ? .letters : (page.kind == .numeric ? .numeric : .symbols),
            isEnglishMode: page.kind == .english, hasGlobe: true, isPhoneLayout: browser,
            usesASCIIPunctuation: page.defaultSymbolMarks == .ascii, includesBottomEnter: !browser,
            usesCategorySymbolPage: page.symbolPresentation == .categorized)
        return ControlRow(
            policy: policy, returnTitle: "换行", layoutName: nil, layoutHintName: nil, layoutHintToken: nil,
            modeKey: AlternateCharacterKey(
                cap: KeyCap(
                    id: "preview-page-mode", title: policy.languageTitle(for: nil),
                    action: .cycleLayout
                ), alternates: []
            ) { _ in },
            systemKeyboardSwitch: { _, _ in }, moveCursor: nil, onPage: { _ in }, onKey: { _ in },
            phoneColumns: columns, split: split, splitRowIndex: page.rows.count)
    }

    private func rowEntries(_ index: Int) -> [(LayoutKeyPath, LayoutKey)] {
        guard mainRows.indices.contains(index) else { return [] }
        return mainRows[index].keys.enumerated().map { (LayoutKeyPath.row(index, key: $0.offset), $0.element) }
    }

    private func visibleEntries(_ index: Int) -> [(LayoutKeyPath, LayoutKey)] {
        rowEntries(index).filter { editing || $0.1.action.type != .globe }
    }

    /// Only function keys of a custom main layout draw through the shared authored-page key view, so
    /// their titleMode and author secondary label match the running keyboard (native faces included).
    /// The shared face only needs a non-English kind for these keys; code/literal keys keep the
    /// original preview path (merged/alternate/phone styling untouched).
    private var previewLayoutState: KeyboardPageAuthoredState {
        KeyboardPageAuthoredState(
            page: .letters, kind: .symbols, isEnglishMode: mode == "英文", shiftState: .off,
            returnTitle: returnTitle, isReturnEnabled: true, symbolLocked: false,
            isComposing: composing, hasGlobe: true, isPhoneStyled: phone,
            usesASCIIPunctuation: previewUsesASCIIPunctuation,
            usesCategorySymbolPage: pageDefinition?.symbolPresentation == .categorized)
    }

    private func previewLayoutActions(select: @escaping () -> Void) -> KeyboardPageAuthoredActions {
        KeyboardPageAuthoredActions(
            perform: { _, _, _ in select() },
            performShiftDoubleTap: { _ in select() },
            moveCursor: nil, systemKeyboardSwitch: nil, spaceLayoutName: nil,
            spaceHintName: nil, spaceHintToken: nil)
    }

    private func authoredPath(_ path: LayoutKeyPath) -> KeyboardPageKeyPath {
        switch path {
        case .row(let row, let key): return .row(row, key: key)
        case .auxiliary(let area, let key):
            // Preview identity only: an authored face reads the region for its tone, not the action.
            return .chrome(area.isMultiple(of: 2) ? .leading : .trailing, key: key)
        }
    }

    /// The authored face owns function controls only: engine code/literal keys keep the original
    /// preview path so merged hints/alternates and phone styling are not re-routed.
    private func usesAuthoredPreviewFace(_ key: LayoutKey) -> Bool {
        pageDefinition == nil && preset == nil
            && key.action.type != .code && key.action.type != .literal
    }

    @ViewBuilder private func authoredLayoutKeyFace(
        _ entry: (LayoutKeyPath, LayoutKey), select: @escaping () -> Void
    ) -> some View {
        let key = entry.1
        let path = authoredPath(entry.0)
        let state = previewLayoutState
        // Keep the disabled look while staying tappable: the editor selects a key instead of running it.
        let dimmed = key.action.type != .shift && !state.isEnabled(key)
        KeyboardAuthoredPageKey(
            key: key, path: path, state: state, actions: previewLayoutActions(select: select),
            actionTable: KeyboardPageAuthoredActionTable(singleKey: key, path: path),
            editorSelection: true
        )
        .opacity(dimmed ? 0.4 : 1)
    }

    @ViewBuilder private func keyFace(
        _ entry: (LayoutKeyPath, LayoutKey), side: Bool = false, onSelect: (() -> Void)? = nil
    ) -> some View {
        let key = entry.1
        let select = {
            if let onSelect {
                onSelect()
            } else {
                inspected = key
                onSelectKey?(entry.0)
            }
        }
        if usesAuthoredPreviewFace(key) {
            authoredLayoutKeyFace(entry, select: select)
        } else if key.action.type == .backspace && (key.longPress ?? []).isEmpty {
            RepeatingDeleteKey(action: select)
        } else if key.action.type == .enter {
            ReturnKey(
                title: returnTitle,
                alternates: (key.longPress ?? []).enumerated().map { index, option in
                    KeyCap(id: "preview-return-\(index)", title: option.label, action: action(option.action))
                }
            ) { _ in select() }
        } else if key.action.type == .space {
            CursorSpaceKey(
                title: key.label, layoutName: nil, layoutHintName: nil, layoutHintToken: nil, onTap: select,
                moveCursor: nil)
        } else if key.action.type == .globe {
            Button(action: select) { ControlKeyFace(symbol: "globe") }.buttonStyle(KeyboardPressStyle())
        } else {
            AlternateCharacterKey(
                cap: .init(
                    id: key.label,
                    title: key.literalFaceTitle(usesASCIIPunctuation: previewUsesASCIIPunctuation),
                    subtitle: merged && key.secondaryLabel == "合并键" ? nil : key.secondaryLabel,
                    action: action(key.action)),
                alternates: merged && !editing
                    ? []
                    : (key.longPress ?? []).map { .init(id: $0.label, title: $0.label, action: action($0.action)) },
                phoneKey: phone, phoneSideKey: phone && side
            ) { _ in select() }
            .opacity(phone && key.action == LayoutAction(.code, value: "'") && !composing ? 0.45 : 1)
        }
    }
    private func candidateArea(expanded: Bool) -> some View {
        let state = CandidatePresentationState(
            preedit: "ni hao", rawInput: "nihao",
            candidates: [
                Candidate(index: 0, text: "你好"), Candidate(index: 1, text: "您好"), Candidate(index: 2, text: "你"),
                Candidate(index: 3, text: "你好啊"), Candidate(index: 4, text: "你好呀"),
            ],
            highlightedIndex: 0, pageIndex: 0, canPageBackward: false, canPageForward: true, isComposing: true)
        let context = CandidateAreaContext(
            state: state, bar: candidateBar, actions: .init { _ in },
            typography: .init(
                candidateSize: skin.typography.candidateSize, secondarySize: skin.typography.secondarySize))
        let renderer = CandidateRendererRegistry.renderer(id: DefaultCandidateAreaRenderer.rendererID)
        return Group {
            if expanded { renderer.makeExpanded(context) } else { renderer.makeCollapsed(context) }
        }.environment(
            \.candidateSkinToken,
            CandidateSkinToken(
                candidateColor: Color(uiColor: appearance.text(on: "panel")),
                secondaryColor: Color(uiColor: appearance.text(on: "panel", secondary: true)),
                accentColor: appearance.accentForeground, panelColor: appearance.color("panel"),
                fontFamily: skin.typography.family, fontWeight: skin.typography.weight))
    }
    /// One preview source for faces, actions and the language caption: an explicit page default
    /// wins, otherwise an English page previews the real English branch.
    private var previewSymbolMarks: KeyboardNumericMarks {
        if let marks = pageDefinition?.defaultSymbolMarks { return marks }
        return mode == "英文" ? .ascii : .chinese
    }

    private var previewUsesASCIIPunctuation: Bool { previewSymbolMarks == .ascii }

    private func action(_ value: LayoutAction) -> KeyAction {
        switch value.type {
        case .code: return .code(value.value ?? "")
        case .literal:
            return .literal(value.literalValue(usesASCIIPunctuation: previewUsesASCIIPunctuation) ?? "")
        case .space: return .space
        case .enter: return .enter
        case .backspace: return .backspace
        case .modeSwitch: return .cycleLayout
        case .globe: return .switchKeyboard
        // Page-level UI actions have no engine face; the preview only styles the cap.
        case .shift, .pageSwitch, .languageSwitch, .symbolLock, .clearInput: return .cycleLayout
        }
    }
}
