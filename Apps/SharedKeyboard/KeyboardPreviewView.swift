import CandidateKit
import KeyboardCore
import LayoutKit
import SkinKit
import SwiftUI

/// Presentation-only adapter: draws a main layout through the live panel's key-area views and
/// rules, without a session or engine. `candidateBar` and `skin` come from the same appearance
/// item: the preview must also show the candidate-area layout, otherwise "keyboard appearance"
/// would read as colors only.
public struct KeyboardPreviewView: View {
    public let layout: LayoutDefinition
    public var skin: SkinDefinition
    public var candidateBar: CandidateBarDefinition
    public var previewDark: Bool?
    private let onSelectKey: ((LayoutKeyPath) -> Void)?
    @State private var language = PreviewLanguage.chinese
    @State private var sample = PreviewSample.idle
    @State private var inspected: LayoutKey?
    @State private var preferences = KeyboardPreviewPreferences.cached
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.verticalSizeClass) private var verticalSizeClass

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

    private var editing: Bool { onSelectKey != nil }
    private var layoutKind: KeyboardLayoutKind? {
        layout.input.builtinLayout.flatMap { KeyboardLayoutKind(rawValue: $0.rawValue) }
    }

    public var body: some View {
        // Resolved once per body: every region reads these facts instead of comparing the
        // definition against each bundled preset again.
        let facts = DefinitionResolutionMemo.Facts(usable: [], active: layout)
        VStack(spacing: 6) {
            if !editing {
                Picker("示例语言", selection: $language) {
                    ForEach(PreviewLanguage.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("示例状态", selection: $sample) {
                    ForEach(PreviewSample.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            KeyboardPreviewFrame(layout: layoutKind, mainSplit: layout.split, dock: preferences.dock(for: layoutKind)) {
                widths in
                KeyboardMainLayoutPreview(
                    definition: layout, facts: facts,
                    language: editing ? .chinese : language, sample: editing ? .idle : sample,
                    editing: editing, showsGlobe: preferences.showsGlobe(editing: editing), widths: widths,
                    candidateBar: candidateBar, inspected: inspected,
                    onSelect: { path, key in
                        inspected = key
                        onSelectKey?(path)
                    })
            }
            if editing {
                Text("轻点要修改的按键").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .environment(\.keyboardAppearance, KeyboardAppearance(skin: skin, dark: previewDark ?? (colorScheme == .dark)))
        .environment(\.keyboardKeyHeight, preferences.keyHeight(compact: verticalSizeClass == .compact))
        .onChange(of: layout) { inspected = nil }
        .task { preferences = await KeyboardPreviewPreferences.load() }
    }
}

private enum PreviewLanguage: CaseIterable {
    case chinese, english, numeric

    var title: String {
        switch self {
        case .chinese: return "中文"
        case .english: return "英文"
        case .numeric: return "数字"
        }
    }
}

private enum PreviewSample: CaseIterable {
    case idle, composing, expanded, longPress

    var title: String {
        switch self {
        case .idle: return "空闲"
        case .composing: return "组合"
        case .expanded: return "展开"
        case .longPress: return "长按"
        }
    }
}

/// The key area the panel draws for a main layout, in one sample state. Shell and footer choices,
/// splits and geometry come from the panel's own facts, rules and views; only the per-key face is
/// local, because the panel's key builder reads the live session.
private struct KeyboardMainLayoutPreview: View {
    @Environment(\.keyboardAppearance) private var appearance
    @Environment(\.keyboardKeyHeight) private var keyHeight
    let definition: LayoutDefinition
    let facts: DefinitionResolutionMemo.Facts
    let language: PreviewLanguage
    let sample: PreviewSample
    let editing: Bool
    let showsGlobe: Bool
    let widths: KeyboardPreviewWidths
    let candidateBar: CandidateBarDefinition
    let inspected: LayoutKey?
    let onSelect: (LayoutKeyPath, LayoutKey) -> Void

    private var page: KeyboardPage { language == .numeric ? .numeric : .letters }
    private var isEnglishMode: Bool { language == .english }
    private var usesASCIIPunctuation: Bool { isEnglishMode }
    private var composing: Bool { !isEnglishMode && (sample == .composing || sample == .expanded) }
    private var expanded: Bool { composing && sample == .expanded }
    private var returnTitle: String { composing ? "确认" : "换行" }
    /// A main-layout preview never carries an authored page or the categorised #+= grid.
    private var renderer: KeyAreaRenderer {
        KeyboardPanelRules.keyAreaRenderer(
            page: page, isEnglishMode: isEnglishMode, authoredPage: nil, facts: facts,
            showsCategorySymbolPage: false)
    }
    private var usesConfiguredLayout: Bool { page == .letters && !isEnglishMode }
    private var usesStandardT9: Bool { renderer == .phonePad }
    private var usesStandardQwerty: Bool { isEnglishMode || facts.isBundledQwertyMainShell }
    private var usesBundledMergedPad: Bool { usesConfiguredLayout && facts.isBundledMergedPad }
    /// An editor shows the declared rails and footer, so every stored key can be selected.
    private var showsBundledPhoneShell: Bool { facts.isBuiltinPhonePad && !editing }

    private var geometry: KeyboardPanelGeometry {
        KeyboardPanelGeometry(
            candidateHeight: candidateBar.collapsed.height, keyHeight: Double(keyHeight),
            selectedMainRows: max(1, facts.mainRows.count),
            candidateSize: appearance.skin.typography.candidateSize)
    }

    private var controlPolicy: KeyboardControlPolicy {
        KeyboardPanelRules.controlPolicy(
            page: page, isEnglishMode: isEnglishMode, hasGlobe: showsGlobe,
            usesASCIIPunctuation: usesASCIIPunctuation,
            phoneShellVisible: KeyboardPanelRules.phoneShellVisible(
                usesStandardT9: usesStandardT9, page: page, hasAuthoredPage: false,
                mainIsPhoneKeypad: facts.isPhone, showsCategorySymbolPage: false),
            usesFixedEditingRail: showsBundledPhoneShell,
            declaredTrailingReturn: railEntries(.trailing).contains { $0.key.action.type == .enter },
            showsCategorySymbolPage: false, numericPageReachesSymbols: !facts.isPhone)
    }

    var body: some View {
        let split = KeyboardPanelRules.activeSplit(
            main: definition.split, mainWidth: widths.mainSplit, showsMainLetters: usesConfiguredLayout,
            pageSplit: nil, contentWidth: widths.content)
        let geometry = geometry
        VStack(spacing: 0) {
            Group {
                if composing { candidateArea(expanded: false) } else { Color.clear }
            }
            .frame(height: CGFloat(geometry.headerHeight))
            VStack(spacing: 4) {
                switch renderer {
                case .phonePad:
                    phonePad(split: split)
                case .phoneDigitPad:
                    phoneDigitPad(split: split)
                default:
                    let mainRowCount = usesConfiguredLayout && !usesStandardQwerty ? max(1, facts.mainRows.count) : 3
                    let mainAreaHeight = CGFloat(geometry.mainAreaHeight)
                    VStack(spacing: 4) {
                        if expanded {
                            candidateArea(expanded: true)
                        } else if CGFloat(mainRowCount) * (keyHeight + 4) - 4 > mainAreaHeight + 1 {
                            ScrollView { VStack(spacing: 4) { keyRows(split: split) } }
                                .sharpCandidateScrollEdges()
                        } else {
                            VStack(spacing: 4) { keyRows(split: split) }
                        }
                    }
                    .frame(height: mainAreaHeight, alignment: .top)
                    if editing || (usesConfiguredLayout && !facts.isBundledControlRowPolicy) {
                        layoutUtilityBar(split: split)
                    } else {
                        controlRow(split: split, columns: nil)
                    }
                }
            }
            if sample == .longPress {
                longPressSample
            }
        }
        .padding(4)
        .background(appearance.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Key area

    @ViewBuilder
    private func keyRows(split: ActiveLayoutSplit?) -> some View {
        switch renderer {
        case .standardQwerty:
            KeyboardStandardQwertyPad(
                split: split,
                row: { index, metrics in standardQwertyRow(index, metrics: metrics, split: split) },
                shift: { ShiftKey(state: .off, isEnglishMode: isEnglishMode, tap: {}, doubleTap: {}) },
                delete: { RepeatingDeleteKey {} })
        case .mergedPad:
            KeyboardMergedPad(
                rows: facts.mainRows, split: split,
                key: { key, row, index in
                    keyFace(
                        key, path: .row(row, key: index),
                        id: "merged-\(key.action.value ?? "\(row)-\(index)")")
                },
                separator: { KeyboardMergedSeparatorKey(isComposing: composing) {} },
                delete: { RepeatingDeleteKey {} })
        case .configuredRows:
            HStack(spacing: 4) {
                auxiliaryColumn(.leading)
                VStack(spacing: 4) {
                    ForEach(facts.mainRows.indices, id: \.self) { index in
                        definitionRow(index, inset: definitionInset(index), split: split)
                    }
                }
                auxiliaryColumn(.trailing)
            }
        case .symbolRows:
            KeyboardSymbolPageRows(
                rows: SymbolPageTable.numericRows(ascii: usesASCIIPunctuation), split: split,
                onTap: { _ in }, pageSwitch: { MarkPageSwitchKey(target: .symbols) {} },
                delete: { RepeatingDeleteKey {} })
        case .authoredChromePage, .phoneDigitPad, .categorySymbolPage, .authoredRows, .phonePad:
            // Drawn by the body, or never shown by a main-layout preview.
            EmptyView()
        }
    }

    @ViewBuilder
    private func standardQwertyRow(
        _ index: Int, metrics: StandardKeyRowGeometry, split: ActiveLayoutSplit?
    ) -> some View {
        if isEnglishMode {
            WeightedKeyRow(
                caps: KeyboardLayoutTable.englishRows()[index].caps, showsKeyPreview: true,
                split: split, rowIndex: index,
                fixedKeyWidth: CGFloat(metrics.keyWidth), splitGap: CGFloat(metrics.gap)
            ) { _ in }
        } else if facts.mainRows.indices.contains(index) {
            definitionRow(
                index, split: split, fixedKeyWidth: CGFloat(metrics.keyWidth), splitGap: CGFloat(metrics.gap))
        }
    }

    /// The familiar stagger belongs to the standard 26-key shell.
    private func definitionInset(_ index: Int) -> CGFloat {
        guard facts.isBundledQwertyMainShell else { return 0 }
        return index == 1 ? 0.5 : (index == 2 ? 1.5 : 0)
    }

    private func visibleSources(_ keys: [LayoutKey]) -> [Int] {
        keys.indices.filter { showsGlobe || keys[$0].action.type != .globe }
    }

    private func definitionRow(
        _ index: Int, inset: CGFloat = 0, spacing: CGFloat = 4, split: ActiveLayoutSplit?,
        fixedKeyWidth: CGFloat? = nil, splitGap: CGFloat? = nil
    ) -> some View {
        let keys = facts.mainRows[index].keys
        let sources = visibleSources(keys)
        return KeyboardDefinitionRow(
            keys: sources.map { keys[$0] }, inset: inset, spacing: spacing, split: split, rowIndex: index,
            fixedKeyWidth: fixedKeyWidth, splitGap: splitGap
        ) { key, visible in
            keyFace(key, path: .row(index, key: sources[visible]), id: "row-\(index)-\(visible)")
        }
    }

    private struct RailEntry {
        let path: LayoutKeyPath
        let key: LayoutKey
    }

    /// The declared side keys in `PhoneKeypadRailPolicy.declaredKeys` order, with their stored
    /// addresses and the same globe visibility as the keyboard.
    private func railEntries(_ position: LayoutAuxiliaryArea.Position) -> [RailEntry] {
        var entries: [RailEntry] = []
        for (area, value) in (definition.auxiliaryAreas ?? []).enumerated()
        where value.position == position && !value.requiresEngineDisambiguation {
            for (index, key) in value.keys.enumerated() where showsGlobe || key.action.type != .globe {
                entries.append(RailEntry(path: .auxiliary(area, key: index), key: key))
            }
        }
        return entries
    }

    private func auxiliaryColumn(_ position: LayoutAuxiliaryArea.Position) -> some View {
        let entries = railEntries(position)
        return KeyboardAuxiliaryColumn(keys: entries.map(\.key), rowCount: facts.mainRows.count) { key, index in
            keyFace(key, path: entries[index].path, id: "\(position.rawValue)-\(index)")
        }
    }

    // MARK: Phone keypad

    private func phonePad(split: ActiveLayoutSplit?) -> some View {
        StablePhoneKeypadShell(
            trailingSpansControlRow: showsBundledPhoneShell,
            expandsForSplit: split != nil,
            leading: { metrics in rail(.leading, metrics: metrics) },
            main: { metrics in
                VStack(spacing: CGFloat(metrics.spacing)) {
                    if expanded {
                        candidateArea(expanded: true)
                    } else {
                        ForEach(facts.mainRows.indices, id: \.self) { index in
                            definitionRow(index, spacing: CGFloat(metrics.spacing), split: split)
                        }
                    }
                }
            },
            trailing: { metrics in rail(.trailing, metrics: metrics) },
            bottom: { metrics in
                if showsBundledPhoneShell {
                    controlRow(split: split, columns: .init(rail: metrics.railWidth, digit: metrics.digitWidth))
                } else {
                    layoutUtilityBar(split: split)
                }
            })
    }

    private func phoneDigitPad(split: ActiveLayoutSplit?) -> some View {
        KeyboardPhoneDigitPad(
            usesASCIIPunctuation: usesASCIIPunctuation, split: split,
            trailingSpansControlRow: showsBundledPhoneShell,
            onKey: { _ in }, expanded: { EmptyView() },
            trailing: { metrics in rail(.trailing, metrics: metrics) },
            bottom: { metrics in
                controlRow(
                    split: split,
                    columns: showsBundledPhoneShell ? .init(rail: metrics.railWidth, digit: metrics.digitWidth) : nil)
            })
    }

    /// The same rail policy as the keyboard: the bundled 9-key draws its own rails, an imported
    /// keypad its declared keys. Reading choices need the engine, so composing shows a caption.
    @ViewBuilder
    private func rail(_ position: LayoutAuxiliaryArea.Position, metrics: PhoneKeypadMetrics) -> some View {
        let entries = railEntries(position)
        let content = PhoneKeypadRailPolicy.content(
            isBuiltinPhonePad: showsBundledPhoneShell, declaredKeyCount: entries.count)
        switch content {
        case .bundledAuthored:
            if position == .trailing {
                KeyboardFixedEditingRail(previewMetrics: metrics, returnTitle: returnTitle, isComposing: composing)
            } else if composing {
                readingCaption
            } else {
                KeyboardPhoneSymbolRail(
                    caps: SymbolPageTable.quickRail(
                        symbols: T9QuickSymbolStore.defaultSymbols, ascii: usesASCIIPunctuation),
                    metrics: metrics, onSelect: { _ in })
            }
        case .declared:
            KeyboardPhoneDeclaredRail(
                keys: entries.map(\.key), position: position, metrics: metrics,
                readings: { if composing { readingCaption } },
                key: { key, index in keyFace(key, path: entries[index].path, id: "\(position.rawValue)-\(index)") })
        case .empty:
            if position == .leading && composing { readingCaption } else { Color.clear }
        }
    }

    private var readingCaption: some View {
        Text("拼音选项").font(.caption2).multilineTextAlignment(.center)
    }

    // MARK: Footer

    private func controlRow(split: ActiveLayoutSplit?, columns: KeyboardControlPolicy.PhoneColumns?) -> some View {
        KeyboardPreviewControlRow(
            policy: controlPolicy, returnTitle: returnTitle, showsGlobe: showsGlobe, columns: columns,
            split: split, splitRowIndex: facts.mainRows.count)
    }

    /// An editor shows the declared control row as stored; the keyboard's bundled shells hide the
    /// keys their own controls replace.
    private func layoutUtilityBar(split: ActiveLayoutSplit?) -> some View {
        let row = editing ? (facts.controlRow == nil ? nil : definition.rows.last) : facts.controlRow
        let rowIndex = definition.rows.count - 1
        return KeyboardLayoutUtilityBar(
            controlRow: row, rowIndex: facts.mainRows.count, split: split,
            showsGlobe: showsGlobe, definitionHasGlobe: facts.hasGlobe, onPage: { _ in },
            key: { key, id, index in keyFace(key, path: index < 0 ? nil : .row(rowIndex, key: index), id: id) },
            globe: { NativeInputModeKey(handleEvent: { _, _ in }, accessibilitySwitch: {}) },
            modeSwitch: { KeyboardPreviewModeKey(policy: controlPolicy) })
    }

    // MARK: Key faces

    /// Code and literal keys use the panel's key face with its native-shell policies; function
    /// keys draw through the authored key face, which renders the same native controls.
    @ViewBuilder
    private func keyFace(_ key: LayoutKey, path: LayoutKeyPath?, id: String) -> some View {
        let select = {
            if let path { onSelect(path, key) }
        }
        if key.action.type == .code || key.action.type == .literal {
            engineKeyFace(key, id: id, select: select)
        } else {
            functionKeyFace(key, path: path, select: select)
        }
    }

    @ViewBuilder
    private func engineKeyFace(_ key: LayoutKey, id: String, select: @escaping () -> Void) -> some View {
        let isT9FirstKey = facts.isKnownPhone9Primary && id == "row-0-0"
        let presetKey = KeyboardPanelRules.knownMainShellPreset(facts).flatMap {
            KeyboardPanelRules.mainShellPresetKey(in: $0, id: id, key: key)
        }
        let bundledMergedFace =
            usesBundledMergedPad && presetKey.map { KeyboardPanelRules.keyFaceUnchanged(key, preset: $0) } == true
        let letterGroup = LetterGroupLayout.group(of: key) ?? []
        // The live first key shows its cycle while idle and the separator while composing.
        let title: String =
            if isT9FirstKey {
                key.titleMode != .custom && facts.isBuiltinPhonePad
                    ? (composing
                        ? "分词"
                        : SymbolPageTable.quickCycle(
                            symbols: T9QuickSymbolStore.defaultSymbols, ascii: usesASCIIPunctuation
                        ).prefix(3).joined())
                    : key.label
            } else if bundledMergedFace {
                key.label.lowercased()
            } else {
                key.literalFaceTitle(usesASCIIPunctuation: usesASCIIPunctuation)
            }
        // The merged pad keeps its preset menus suppressed; edited and other keys show what the
        // author declared.
        let options: [KeyCap] =
            usesBundledMergedPad && presetKey?.longPress == key.longPress
            ? []
            : (key.longPress ?? []).enumerated().compactMap { index, option in
                guard option.action.type == .code || option.action.type == .literal else { return nil }
                return KeyCap(
                    id: "\(id)-option-\(index)", title: option.label,
                    action: option.action.keyAction(usesASCIIPunctuation: usesASCIIPunctuation))
            }
        let separatorIdle = usesStandardT9 && key.action == LayoutAction(.code, value: "'") && !composing
        AlternateCharacterKey(
            cap: KeyCap(
                id: id, title: title, subtitle: bundledMergedFace ? nil : key.secondaryLabel,
                action: key.action.keyAction(usesASCIIPunctuation: usesASCIIPunctuation)),
            alternates: options,
            phoneKey: usesStandardT9,
            phoneSideKey: usesStandardT9 && !id.hasPrefix("row-"),
            letterGroup: letterGroup.count > 1
                ? letterGroup.map { bundledMergedFace ? String($0).lowercased() : String($0) } : []
        ) { _ in select() }
        .opacity(separatorIdle ? 0.45 : 1)
    }

    /// The authored face reads only the control state here; `.symbols` keeps literal letter
    /// semantics out of these keys.
    @ViewBuilder
    private func functionKeyFace(_ key: LayoutKey, path: LayoutKeyPath?, select: @escaping () -> Void) -> some View {
        if key.action.type != .globe || showsGlobe {
            let pagePath = authoredPath(path)
            KeyboardAuthoredPageKey(
                key: key, path: pagePath,
                state: KeyboardPageAuthoredState(
                    page: page, kind: .symbols, isEnglishMode: isEnglishMode, shiftState: .off,
                    returnTitle: returnTitle, isReturnEnabled: true, symbolLocked: false,
                    isComposing: composing, hasGlobe: showsGlobe, isPhoneStyled: false,
                    usesASCIIPunctuation: usesASCIIPunctuation),
                actions: KeyboardPageAuthoredActions(
                    perform: { _, _, _ in select() },
                    performShiftDoubleTap: { _ in select() },
                    moveCursor: nil, systemKeyboardSwitch: editing ? nil : { _, _ in },
                    spaceLayoutName: nil, spaceHintName: nil, spaceHintToken: nil),
                actionTable: KeyboardPageAuthoredActionTable(singleKey: key, path: pagePath),
                editorSelection: editing)
        }
    }

    /// Face identity only: an authored face reads the region for its tone, not the action.
    private func authoredPath(_ path: LayoutKeyPath?) -> KeyboardPageKeyPath {
        switch path {
        case .row(let row, let key): return .row(row, key: key)
        case .auxiliary(let area, let key):
            let position = definition.auxiliaryAreas?[area].position
            return .chrome(position == .leading ? .leading : .trailing, key: key)
        case nil: return .chrome(.bottom, key: 0)
        }
    }

    // MARK: Samples

    private var previewAlternates: [LayoutOption] {
        inspected?.longPress
            ?? definition.rows.flatMap(\.keys).first(where: { !($0.longPress ?? []).isEmpty })?.longPress ?? []
    }

    private var longPressSample: some View {
        // Same text-measured 44...72pt cells as CharacterButton.showAlternates.
        let font = appearance.uiFont(min(20, appearance.skin.typography.keySize))
        let textWidth = previewAlternates.reduce(CGFloat.zero) {
            max($0, ($1.label as NSString).size(withAttributes: [.font: font]).width)
        }
        let width = max(44, min(72, textWidth + 20))
        return LazyVGrid(
            columns: [GridItem(.adaptive(minimum: width, maximum: width), spacing: 4)],
            alignment: .leading, spacing: 0
        ) {
            ForEach(Array(previewAlternates.enumerated()), id: \.offset) { _, option in
                AlternateCharacterKey(
                    cap: .init(
                        id: option.label, title: option.label,
                        action: option.action.keyAction(usesASCIIPunctuation: usesASCIIPunctuation)),
                    alternates: []
                ) { _ in }
                .frame(height: 46)
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
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
                candidateSize: appearance.skin.typography.candidateSize,
                secondarySize: appearance.skin.typography.secondarySize))
        let renderer = CandidateRendererRegistry.renderer(id: DefaultCandidateAreaRenderer.rendererID)
        return Group {
            if expanded { renderer.makeExpanded(context) } else { renderer.makeCollapsed(context) }
        }
        .environment(
            \.candidateSkinToken,
            CandidateSkinToken(
                candidateColor: Color(uiColor: appearance.text(on: "panel")),
                secondaryColor: Color(uiColor: appearance.text(on: "panel", secondary: true)),
                accentColor: appearance.accentForeground, panelColor: appearance.color("panel"),
                fontFamily: appearance.skin.typography.family, fontWeight: appearance.skin.typography.weight))
    }
}
