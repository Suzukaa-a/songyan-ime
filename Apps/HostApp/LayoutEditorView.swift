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
                Text(Self.compatibility(draft)).font(.footnote).foregroundStyle(.secondary)
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
                LayoutKeyFields(key: key) { updated in
                    draft = draft.replacingKey(at: selected, with: updated)
                }
                .id(selected)
            }
            Section {
                Button("另存为副本") { save(asCopy: true) }
            } footer: {
                Text("新键盘布局保存后需在列表中启用。")
            }
            .disabled(saving)
        }
        .disabled(saving)
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

    static func compatibility(_ layout: LayoutDefinition) -> String {
        if layout.input.schemaID != nil {
            return "此键盘布局暂不可用，仍可编辑和导出。"
        }
        return "只改变按键上显示的文字。"
    }
}

private struct LayoutKeyFields: View {
    let key: LayoutKey
    let update: (LayoutKey) -> Void

    private func change(
        label: String? = nil, width: Double? = nil,
        action: LayoutAction? = nil, options: [LayoutOption]? = nil
    ) {
        update(
            LayoutKey(
                label: label ?? key.label,
                secondaryLabel: key.secondaryLabel,
                width: width ?? key.width, action: action ?? key.action,
                longPress: options ?? key.longPress))
    }

    var body: some View {
        Section("选中键 · \(key.label)") {
            TextField("主标题", text: Binding(get: { key.label }, set: { change(label: $0) }))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier("layoutEditor.key.label")
            TextField(
                "副标题",
                text: Binding(
                    get: { key.secondaryLabel ?? "" },
                    set: {
                        update(
                            LayoutKey(
                                label: key.label, secondaryLabel: $0.isEmpty ? nil : $0,
                                width: key.width, action: key.action, longPress: key.longPress))
                    })
            )
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .accessibilityIdentifier("layoutEditor.key.secondaryLabel")
            HStack {
                Text("相对宽度")
                TextField("1", value: Binding(get: { key.widthWeight }, set: { change(width: $0) }), format: .number)
                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
            }
            LayoutActionFields(action: key.action) { change(action: $0) }
        }
        Section {
            ForEach((key.longPress ?? []).indices, id: \.self) { index in
                let option = (key.longPress ?? [])[index]
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
                    LayoutActionFields(action: option.action) { action in
                        replaceOption(index, with: LayoutOption(label: option.label, action: action))
                    }
                    HStack {
                        Button("上移") { moveOption(index, by: -1) }.disabled(index == 0)
                        Button("下移") { moveOption(index, by: 1) }.disabled(index == (key.longPress?.count ?? 0) - 1)
                        Spacer()
                        Button("移除", role: .destructive) {
                            var options = key.longPress ?? []
                            options.remove(at: index)
                            change(options: options)
                        }
                    }.buttonStyle(.borderless)
                }
            }
            Button("添加长按项") {
                change(
                    options: (key.longPress ?? []) + [
                        LayoutOption(label: "。", action: LayoutAction(.literal, value: "。"))
                    ])
            }
        } header: {
            Text("长按列表")
        }
    }

    private func replaceOption(_ index: Int, with option: LayoutOption) {
        var options = key.longPress ?? []
        options[index] = option
        change(options: options)
    }
    private func moveOption(_ index: Int, by offset: Int) {
        var options = key.longPress ?? []
        options.swapAt(index, index + offset)
        change(options: options)
    }
}

private struct LayoutActionFields: View {
    let action: LayoutAction
    let update: (LayoutAction) -> Void
    private let kinds: [LayoutAction.Kind] = [.code, .literal, .space, .backspace, .enter, .globe, .modeSwitch]
    private func title(_ kind: LayoutAction.Kind) -> String {
        switch kind {
        case .code: return "输入字母"
        case .literal: return "输入文字"
        case .space: return "空格"
        case .backspace: return "退格"
        case .enter: return "回车"
        case .globe: return "切换键盘"
        case .modeSwitch: return "切换键盘布局"
        }
    }
    var body: some View {
        Picker(
            "动作",
            selection: Binding(
                get: { action.type },
                set: { kind in
                    update(LayoutAction(kind, value: kind == .code ? "a" : kind == .literal ? "。" : nil))
                })
        ) {
            ForEach(kinds, id: \.self) { kind in Text(title(kind)).tag(kind) }
        }
        if action.type == .code || action.type == .literal {
            TextField(
                action.type == .code ? "一个英文字符" : "要输入的文字",
                text: Binding(
                    get: { action.value ?? "" }, set: { update(LayoutAction(action.type, value: $0)) }), axis: .vertical
            )
            .keyboardType(action.type == .code ? .asciiCapable : .default)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .accessibilityIdentifier("layoutEditor.key.actionValue")
        }
    }
}
