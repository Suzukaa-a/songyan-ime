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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var keyHeight: CGFloat { verticalSizeClass == .compact ? 44 : 54 }
    private func previewDeleteWidth(for width: CGFloat) -> CGFloat { max(44, (width - 32) / 10 * 1.5) }
    @State private var mode = "中文"
    @State private var sample = "空闲"
    @State private var inspected: LayoutKey?
    public init(
        layout: LayoutDefinition, skin: SkinDefinition = .systemDefault,
        candidateBar: CandidateBarDefinition = .systemDefault,
        previewDark: Bool? = nil, onSelectKey: ((LayoutKeyPath) -> Void)? = nil
    ) {
        self.layout = layout
        self.skin = skin
        self.candidateBar = candidateBar
        self.previewDark = previewDark
        self.onSelectKey = onSelectKey
    }
    private var appearance: KeyboardAppearance { .init(skin: skin, dark: previewDark ?? (colorScheme == .dark)) }
    private var editing: Bool { onSelectKey != nil }
    private var definition: LayoutDefinition { !editing && mode == "英文" ? BuiltinLayouts.qwerty26 : layout }
    private var bundled: Bool { BuiltinLayouts.all.contains(definition) }
    private var merged: Bool {
        bundled && (definition == BuiltinLayouts.merged14 || definition == BuiltinLayouts.merged18)
    }
    private var phone: Bool { bundled && definition == BuiltinLayouts.phone9 }
    private var qwerty: Bool { bundled && definition == BuiltinLayouts.qwerty26 }
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
            onKey: { _ in }, phoneColumns: columns)
    }
    public var body: some View {
        VStack(spacing: 6) {
            if !editing {
                Picker("示例语言", selection: $mode) { ForEach(["中文", "英文", "数字"], id: \.self) { Text($0) } }.pickerStyle(
                    .segmented)
                Picker("示例状态", selection: $sample) { ForEach(["空闲", "组合", "展开", "长按"], id: \.self) { Text($0) } }
                    .pickerStyle(.segmented)
            }
            canvas
            if editing {
                Text("轻点按键即可编辑").font(.caption).foregroundStyle(.secondary).frame(
                    maxWidth: .infinity, alignment: .leading)
            }
        }
        .environment(\.keyboardAppearance, appearance)
        .environment(\.keyboardKeyHeight, keyHeight)
        .onChange(of: layout) { inspected = nil }
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
                        ScrollView {
                            HStack(spacing: 4) {
                                auxiliary(.leading)
                                VStack(spacing: 4) {
                                    ForEach(Array(mainRows.enumerated()), id: \.offset) { index, row in
                                        if merged {
                                            mergedPreviewRow(index)
                                        } else if qwerty && index == 2 {
                                            GeometryReader { proxy in
                                                let side = previewDeleteWidth(for: proxy.size.width)
                                                HStack(spacing: 4) {
                                                    ControlKeyFace(symbol: "shift").frame(width: side)
                                                    previewRow(
                                                        row.keys.enumerated().map {
                                                            (.row(index, key: $0.offset), $0.element)
                                                        })
                                                    RepeatingDeleteKey {}.frame(width: side)
                                                }
                                            }.frame(height: keyHeight)
                                        } else {
                                            previewRow(
                                                row.keys.enumerated().map { (.row(index, key: $0.offset), $0.element) },
                                                inset: qwerty && index == 1 ? 0.5 : 0)
                                        }
                                    }
                                }
                                auxiliary(.trailing)
                            }
                        }.scrollDisabled(mainRows.count <= 3)
                            .frame(height: CGFloat(min(3, max(1, mainRows.count))) * (keyHeight + 4) - 4)
                    }
                    if !editing && (merged || qwerty || mode == "数字" || expanded) {
                        previewControlRow
                    } else {
                        HStack(spacing: 4) {
                            if controls, let row = definition.rows.last {
                                previewRow(
                                    row.keys.enumerated().map {
                                        (.row(definition.rows.count - 1, key: $0.offset), $0.element)
                                    }, control: true)
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
    private var numericRows: some View {
        ForEach(Array(SymbolPageTable.numericRows(ascii: false).enumerated()), id: \.offset) { index, row in
            if index == 2 {
                GeometryReader { geometry in
                    let deleteWidth = previewDeleteWidth(for: geometry.size.width)
                    HStack(spacing: 4) {
                        WeightedKeyRow(caps: row.caps) { _ in }
                            .frame(width: max(0, geometry.size.width - deleteWidth - 4))
                        RepeatingDeleteKey {}.frame(width: deleteWidth, height: keyHeight)
                    }
                }.frame(height: keyHeight)
            } else {
                WeightedKeyRow(caps: row.caps) { _ in }.frame(height: keyHeight)
            }
        }
    }
    private var phonePreview: some View {
        StablePhoneKeypadShell(
            trailingSpansControlRow: true,
            leading: { metrics in
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
            },
            main: { metrics in
                if expanded {
                    candidateArea(expanded: true).frame(height: CGFloat(metrics.mainHeight))
                } else {
                    VStack(spacing: CGFloat(metrics.spacing)) {
                        ForEach(Array(mainRows.enumerated()), id: \.offset) { index, row in
                            previewRow(row.keys.enumerated().map { (.row(index, key: $0.offset), $0.element) })
                        }
                    }
                }
            },
            trailing: { metrics in
                // Single source: uses the same `PhoneKeypadRailPolicy` constant as production `t9FixedEditingRail`
                // (`[1, 1, 2]` = Delete + re-input + bottom-right Return/confirm);
                // the literal is not duplicated here, and no pinyin-cycle key is drawn on the right.
                let slots = metrics.railSlots(.trailing, spans: PhoneKeypadRailPolicy.bundledTrailingSpans)
                VStack(spacing: CGFloat(metrics.spacing)) {
                    RepeatingDeleteKey {}.frame(height: CGFloat(slots[0].height))
                    ControlKeyFace(text: "重输").frame(height: CGFloat(slots[1].height))
                        .opacity(composing ? 1 : 0.45)
                    ReturnKey(title: returnTitle) { _ in }.frame(height: CGFloat(slots[2].height))
                }
            },
            bottom: { metrics in
                previewControlRow(columns: .init(rail: metrics.railWidth, digit: metrics.digitWidth))
            })
    }
    private func mergedPreviewRow(_ index: Int) -> some View {
        let row = mainRows[index].keys.enumerated().map { (LayoutKeyPath.row(index, key: $0.offset), $0.element) }
        let isLast = index == mainRows.count - 1
        return GeometryReader { proxy in
            let side = previewDeleteWidth(for: proxy.size.width)
            // Same shell and widths as the live merged pad: separator in the Shift slot, weighted caps.
            let metrics = MergedKeypadGeometry.rows(
                weights: mainRows.map { $0.keys.map(\.widthWeight) },
                width: proxy.size.width, spacing: 4, sideWidth: side)
            HStack(spacing: 4) {
                if isLast { ControlKeyFace(text: "分词").frame(width: side) }
                ForEach(Array(row.enumerated()), id: \.offset) { keyIndex, entry in
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
    private func previewRow(_ entries: [(LayoutKeyPath, LayoutKey)], inset: CGFloat = 0, control: Bool = false)
        -> some View
    {
        let keys = entries.filter { editing || $0.1.action.type != .globe }
        return GeometryReader { proxy in
            let available = max(0, proxy.size.width - CGFloat(max(0, keys.count - 1)) * 4)
            let total = max(1, keys.reduce(0) { $0 + weight($1.1) } + Double(inset * 2))
            let minimum: CGFloat = control && !editing ? 44 : 0
            HStack(spacing: 4) {
                ForEach(Array(keys.enumerated()), id: \.offset) { _, entry in
                    keyFace(entry).frame(
                        width: minimum + max(0, available - CGFloat(keys.count) * minimum) * weight(entry.1) / total,
                        height: keyHeight)
                }
            }.frame(width: proxy.size.width, alignment: .center)
        }.frame(height: keyHeight)
    }
    @ViewBuilder private func keyFace(_ entry: (LayoutKeyPath, LayoutKey), side: Bool = false) -> some View {
        let key = entry.1
        let select = {
            inspected = key
            onSelectKey?(entry.0)
        }
        if key.action.type == .backspace && (key.longPress ?? []).isEmpty {
            RepeatingDeleteKey(action: select)
        } else if key.action.type == .enter {
            ReturnKey(title: returnTitle) { _ in select() }
        } else {
            AlternateCharacterKey(
                cap: .init(
                    id: key.label, title: key.label,
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
    private func weight(_ key: LayoutKey) -> Double {
        key.widthWeight.isFinite && key.widthWeight > 0 ? min(key.widthWeight, 1_000_000) : 1
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
    private func action(_ value: LayoutAction) -> KeyAction {
        switch value.type {
        case .code: return .code(value.value ?? "")
        case .literal: return .literal(value.value ?? "")
        case .space: return .space
        case .enter: return .enter
        case .backspace: return .backspace
        case .modeSwitch: return .cycleLayout
        case .globe: return .switchKeyboard
        }
    }
}
