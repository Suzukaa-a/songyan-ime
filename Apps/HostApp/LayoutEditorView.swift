import LayoutKit
import SwiftUI
import UIKit

/// Value-only draft: no engine/session, no writes until save succeeds.
struct LayoutEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var manager = LayoutManager.shared
    @State private var draft: LayoutDefinition
    @State private var selected: LayoutKeyPath = .row(0, key: 0)
    @State private var error: String?
    @State private var confirmingDiscard = false
    @State private var saving = false
    @StateObject private var widthValidity = WidthFieldValidity()
    /// Layout at open time: used to detect unsaved changes (confirm before cancel/swipe-down dismissal).
    private let original: LayoutDefinition

    init(layout: LayoutDefinition) {
        original = layout
        _draft = State(initialValue: layout)
    }
    private var hasChanges: Bool { draft != original }

    var body: some View {
        Form {
            Section("布局") {
                TextField("名称", text: Binding(get: { draft.name }, set: { draft = draft.renamed($0) }))
            }
            Section("候选栏") {
                Toggle(
                    "显示候选栏",
                    isOn: Binding(
                        get: { draft.effectiveCandidateArea.candidates },
                        set: { enabled in
                            draft = draft.settingCandidateArea(
                                .init(
                                    candidates: enabled,
                                    reading: enabled && draft.effectiveCandidateArea.reading))
                        })
                )
                .disabled(draft.sendsEngineCode)
                Toggle(
                    "拼音提示行",
                    isOn: Binding(
                        get: { draft.effectiveCandidateArea.reading },
                        set: { enabled in
                            draft = draft.settingCandidateArea(
                                .init(
                                    candidates: draft.effectiveCandidateArea.candidates, reading: enabled))
                        })
                )
                .disabled(!draft.effectiveCandidateArea.candidates || PhoneKeypadStructure.matches(draft))
            }
            Section("点键编辑") {
                KeyboardPreviewView(layout: draft, onSelectKey: { selected = $0 })
            }
            KeyboardSplitEditor(
                rows: draft.rows, split: Binding(get: { draft.split }, set: { draft = replacingSplit($0) }))
            KeyboardRowsEditor(
                rows: Binding(get: { draft.rows }, set: { draft = replacingRows($0) }), selected: $selected)
            Section("选择键位") {
                Picker("键位", selection: $selected) {
                    ForEach(draft.rows.indices, id: \.self) { row in
                        ForEach(draft.rows[row].keys.indices, id: \.self) { index in
                            Text("第 \(row + 1) 行 · \(index + 1) · \(draft.rows[row].keys[index].label)")
                                .tag(LayoutKeyPath.row(row, key: index))
                        }
                    }
                    ForEach((draft.auxiliaryAreas ?? []).indices, id: \.self) { area in
                        if let keys = draft.auxiliaryAreas?[area].keys, !keys.isEmpty {
                            ForEach(keys.indices, id: \.self) { index in
                                Text("辅助区 \(area + 1) · \(index + 1) · \(keys[index].label)")
                                    .tag(LayoutKeyPath.auxiliary(area, key: index))
                            }
                        }
                    }
                }
            }
            if let key = draft.key(at: selected) {
                // The setteable list now contains page-level actions, and the runtime definition keys
                // already honour custom titles, so a main-layout function key can show its own title.
                LayoutKeyFields(key: key, allowsTitleMode: true) { updated in
                    draft = draft.replacingKey(at: selected, with: updated)
                }
                .id(selected)
            }
            if !draft.hasInputModeSwitchKey {
                Section {
                    Button("添加地球键", systemImage: "globe") { addInputModeSwitchKey() }
                        .disabled((draft.rows.last?.keys.count ?? 0) >= LayoutResourceBudget.keysPerRegion)
                }
            }
            Section {
                Button("另存为副本") { save(asCopy: true) }
            }
            .disabled(saving)
        }
        .disabled(saving)
        .environment(\.widthFieldValidity, widthValidity)
        .navigationBarBackButtonHidden(saving)
        .navigationTitle("编辑键盘布局")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { if hasChanges { confirmingDiscard = true } else { dismiss() } }
                    .disabled(saving)
                    .accessibilityIdentifier("layoutEditor.cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save(asCopy: false) }
                    .disabled(saving)
                    .accessibilityIdentifier("layoutEditor.save")
            }
        }
        .confirmationDialog("放弃未保存的更改？", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("放弃更改", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        }
        .interactiveDismissDisabled(hasChanges || saving)
        .alert("无法保存", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    private func save(asCopy: Bool) {
        guard !saving else { return }
        guard !widthValidity.isInvalid else {
            error = "有宽度还没填对：请把标红处改成大于 0 的数字，或留空自动。"
            return
        }
        saving = true
        // End marked input before taking the value snapshot used for saving.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        Task { @MainActor in
            await Task.yield()
            let snapshot = draft
            defer { saving = false }
            if await manager.saveDraft(snapshot, asCopy: asCopy) {
                dismiss()
            } else {
                error = manager.lastError
                manager.clearError()
            }
        }
    }

    /// Adds the globe key the machine may require. Never automatic: the save gate reports the
    /// missing key and the author decides.
    private func addInputModeSwitchKey() {
        var rows = draft.rows
        guard !rows.isEmpty else { return }
        var keys = rows[rows.count - 1].keys
        guard keys.count < LayoutResourceBudget.keysPerRegion else { return }
        keys.insert(LayoutKey(label: "🌐", action: LayoutAction(.globe)), at: 0)
        rows[rows.count - 1] = LayoutRow(keys: keys)
        draft = replacingRows(rows)
    }

    private func replacingRows(_ rows: [LayoutRow]) -> LayoutDefinition {
        LayoutDefinition(
            id: draft.id, name: draft.name, input: draft.input, rows: rows,
            auxiliaryAreas: draft.auxiliaryAreas, note: draft.note,
            longPressDelay: draft.longPressDelay, candidateArea: draft.candidateArea,
            split: KeyboardSplitEditor.adjusted(draft.split, rows: rows))
    }

    private func replacingSplit(_ split: LayoutSplitConfiguration?) -> LayoutDefinition {
        LayoutDefinition(
            id: draft.id, name: draft.name, input: draft.input, rows: draft.rows,
            auxiliaryAreas: draft.auxiliaryAreas, note: draft.note,
            longPressDelay: draft.longPressDelay, candidateArea: draft.candidateArea, split: split)
    }

    static func compatibility(_ layout: LayoutDefinition) -> String {
        if layout.input.schemaID != nil {
            return "这个键盘布局暂不可用，可继续编辑或导出。"
        }
        return "可编辑按键、行、宽度与长按。"
    }
}

struct LayoutKeyFields: View {
    let key: LayoutKey
    var allowsCode = true
    /// Page function keys can follow the live keyboard state instead of a fixed title.
    var allowsTitleMode = false
    /// Row and footer keys size by relative width; rail keys size by relative height.
    var widthLabel = "相对宽度"
    let update: (LayoutKey) -> Void

    private var isFunctionKey: Bool { key.action.type != .code && key.action.type != .literal }

    /// Literal keys with a live face (a paired branch, or an explicit title mode carried by new
    /// built-in rows) get the same follow-function/custom choice as page function keys. A legacy
    /// fixed literal with no title mode never had one.
    private var supportsLiveTitle: Bool {
        if isFunctionKey { return true }
        guard key.action.type == .literal else { return false }
        return key.action.asciiValue != nil || key.titleMode != nil
    }

    /// A legacy space key without a title mode always shows its stored label; showing
    /// "跟随功能" for it would promise a live title it never had. Other implicit nil cases
    /// (enter, globe, backspace, shift) keep following the live function title.
    private var displayedTitleMode: LayoutKeyTitleMode {
        if key.titleMode == nil, key.action.type == .space || key.action.asciiValue != nil {
            return .custom
        }
        return key.titleMode ?? .automatic
    }

    /// Editing a title switches a page function key from the live title to the author's own.
    /// Character keys and page rows keep their existing title semantics.
    private func updatingLabel(_ text: String) -> LayoutKey {
        let titled = key.title(text)
        return allowsTitleMode && supportsLiveTitle ? titled : titled.settingTitleMode(key.titleMode)
    }

    /// A character key carries no title class; switching back to a function key restores the live
    /// title. Literal edits keep the face the key already had: pairing a legacy fixed key must not
    /// promote its author label into a live title.
    private func updatingAction(_ action: LayoutAction) -> LayoutKey {
        let updated = key.settingAction(action)
        guard allowsTitleMode else { return updated }
        if action.type == .code { return updated.settingTitleMode(nil) }
        if action.type == .literal {
            // A function key switched into literal starts as fixed text; editing an existing
            // literal (including adding or clearing its ASCII value) keeps its stored face.
            if key.action.type != .literal { return updated.settingTitleMode(nil) }
            return updated.settingTitleMode(key.titleMode)
        }
        return updated.settingTitleMode(key.titleMode ?? .automatic)
    }

    var body: some View {
        Section("选中键 · \(key.label)") {
            TextField("主标题", text: Binding(get: { key.label }, set: { update(updatingLabel($0)) }))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier("layoutEditor.key.label")
            if allowsTitleMode && supportsLiveTitle {
                Picker(
                    "标题显示",
                    selection: Binding(
                        get: { displayedTitleMode },
                        set: { update(key.settingTitleMode($0)) })
                ) {
                    Text("跟随功能").tag(LayoutKeyTitleMode.automatic)
                    Text("自定义").tag(LayoutKeyTitleMode.custom)
                }
            }
            TextField(
                "副标题",
                text: Binding(
                    get: { key.secondaryLabel ?? "" },
                    set: { update(key.settingSecondaryLabel($0.isEmpty ? nil : $0)) })
            )
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .accessibilityIdentifier("layoutEditor.key.secondaryLabel")
            OptionalWidthField(
                title: widthLabel,
                value: Binding(get: { key.width }, set: { update(key.settingWidth($0)) }))
            LayoutActionFields(action: key.action, allowsCode: allowsCode) { action in
                update(updatingAction(action))
            }
        }
        Section {
            ForEach((key.longPress ?? []).indices, id: \.self) { index in
                longPressOption(index)
            }
            Button("添加长按项") {
                let options =
                    (key.longPress ?? []) + [
                        LayoutOption(label: "。", action: LayoutAction(.literal, value: "。"))
                    ]
                update(key.settingLongPress(options))
            }
            .disabled((key.longPress?.count ?? 0) >= LayoutResourceBudget.alternatesPerKey)
        } header: {
            Text("长按列表")
        } footer: {
            if let note = longPressNote {
                Text(note)
            }
        }
    }

    /// One short line only where a long press had a native gesture: filling the list replaces it.
    private var longPressNote: String? {
        let hasOptions = !(key.longPress ?? []).isEmpty
        switch key.action.type {
        case .space:
            return hasOptions ? "长按只弹这些选项，不再移动光标。" : "留空时，长按仍是移动光标。"
        case .globe:
            return hasOptions ? "长按只弹这些选项，不再打开系统键盘列表。" : "留空时，长按仍是系统键盘列表。"
        case .languageSwitch:
            return hasOptions ? "长按只弹这些选项，不再选择输入方式。" : "留空时，长按仍是选择输入方式。"
        case .shift, .modeSwitch:
            return hasOptions ? "长按只弹这些选项。" : nil
        default:
            return nil
        }
    }

    @ViewBuilder
    private func longPressOption(_ index: Int) -> some View {
        let options = key.longPress ?? []
        if options.indices.contains(index) {
            let option = options[index]
            VStack(alignment: .leading) {
                TextField(
                    "长按项标题",
                    text: Binding(
                        get: { option.label },
                        set: { text in
                            replaceOption(index, with: LayoutOption(label: text, action: option.action))
                        })
                )
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                LayoutActionFields(action: option.action, allowsCode: allowsCode) { action in
                    replaceOption(index, with: LayoutOption(label: option.label, action: action))
                }
                HStack {
                    Button("上移") { moveOption(index, by: -1) }.disabled(index == 0)
                    Button("下移") { moveOption(index, by: 1) }.disabled(index >= options.count - 1)
                    Spacer()
                    Button("移除", role: .destructive) {
                        var updated = options
                        updated.remove(at: index)
                        update(key.settingLongPress(updated.isEmpty ? nil : updated))
                    }
                }.buttonStyle(.borderless)
            }
        }
    }

    private func replaceOption(_ index: Int, with option: LayoutOption) {
        guard var options = key.longPress, options.indices.contains(index) else { return }
        options[index] = option
        update(key.settingLongPress(options))
    }

    private func moveOption(_ index: Int, by offset: Int) {
        guard var options = key.longPress, options.indices.contains(index + offset) else { return }
        options.swapAt(index, index + offset)
        update(key.settingLongPress(options))
    }
}

private struct LayoutActionFields: View {
    let action: LayoutAction
    var allowsCode = true
    let update: (LayoutAction) -> Void

    private var kinds: [LayoutAction.Kind] {
        [
            .code, .literal, .space, .enter, .backspace, .globe, .modeSwitch, .shift, .pageSwitch,
            .languageSwitch, .symbolLock, .clearInput,
        ]
    }

    private func title(_ kind: LayoutAction.Kind) -> String {
        switch kind {
        case .code: return "输入字母"
        case .literal: return "输入文字"
        case .space: return "空格"
        case .enter: return "回车"
        case .backspace: return "退格"
        case .globe: return "切换键盘"
        case .modeSwitch: return "切换键盘布局"
        case .shift: return "大小写"
        case .pageSwitch: return "切换页面"
        case .languageSwitch: return "语言与返回"
        case .symbolLock: return "符号锁定"
        case .clearInput: return "重输"
        }
    }

    private func defaultAction(_ kind: LayoutAction.Kind) -> LayoutAction {
        switch kind {
        case .code: return LayoutAction(.code, value: "a")
        case .literal: return LayoutAction(.literal, value: "。")
        case .pageSwitch: return .pageSwitch(.numeric)
        case .languageSwitch: return .languageSwitch()
        default: return LayoutAction(kind)
        }
    }

    var body: some View {
        Picker(
            "动作",
            selection: Binding(get: { action.type }, set: { update(defaultAction($0)) })
        ) {
            ForEach(kinds.filter { allowsCode || $0 != .code }, id: \.self) { kind in
                Text(title(kind)).tag(kind)
            }
        }
        if action.type == .languageSwitch {
            Picker(
                "按键行为",
                selection: Binding(
                    get: { action.languageSwitchBehavior },
                    set: { update(.languageSwitch($0)) })
            ) {
                Text("跟随页面").tag(Optional<LayoutAction.LanguageSwitchBehavior>.none)
                Text("切换中英符号").tag(Optional(LayoutAction.LanguageSwitchBehavior.symbols))
                Text("返回主键盘").tag(Optional(LayoutAction.LanguageSwitchBehavior.letters))
            }
        }
        if action.type == .pageSwitch {
            Picker(
                "目标页面",
                selection: Binding(
                    get: { action.pageSwitchTarget ?? .numeric },
                    set: { update(.pageSwitch($0)) })
            ) {
                Text("文字").tag(LayoutAction.PageTarget.letters)
                Text("123").tag(LayoutAction.PageTarget.numeric)
                Text("符号").tag(LayoutAction.PageTarget.symbols)
            }
        }
        if action.type == .code {
            TextField(
                "一个英文字符",
                text: Binding(
                    get: { action.value ?? "" }, set: { update(LayoutAction(.code, value: $0)) }),
                axis: .vertical
            )
            .keyboardType(.asciiCapable)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .accessibilityIdentifier("layoutEditor.key.actionValue")
        }
        if action.type == .literal {
            TextField(
                action.asciiValue == nil ? "要输入的文字" : "中文符号时输入",
                text: Binding(
                    get: { action.value ?? "" },
                    set: { update(LayoutAction(.literal, value: $0, asciiValue: action.asciiValue)) }),
                axis: .vertical
            )
            .keyboardType(.default)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .accessibilityIdentifier("layoutEditor.key.actionValue")
            // One optional field is both the pair switch and the ASCII-side value: typing fills it,
            // clearing writes nil back to a fixed literal. A pair only ever stores non-empty text.
            TextField(
                "英文符号时输入（可选）",
                text: Binding(
                    get: { action.asciiValue ?? "" },
                    set: { update(action.settingAsciiValue($0.isEmpty ? nil : $0)) }),
                axis: .vertical
            )
            .keyboardType(.default)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .accessibilityIdentifier("layoutEditor.key.actionASCIIValue")
        }
    }
}
