import KeyboardCore
import LayoutKit
import SwiftUI
import UIKit

/// Value-only page draft: edits stay in memory until save succeeds. Opening the editor materialises
/// the legacy page (function keys become authored chrome, categories come from the symbol library)
/// under the same id and name, and that materialised value is the dirty baseline, so opening and
/// cancelling never writes and never asks to discard changes that were not made.
struct KeyboardPageEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var manager = LayoutManager.shared
    @State private var draft: KeyboardPageDefinition
    @State private var selected: KeyboardPageKeyPath = .row(0, key: 0)
    @State private var saving = false
    @State private var error: String?
    @State private var confirmingDiscard = false
    @StateObject private var widthValidity = WidthFieldValidity()
    private let original: KeyboardPageDefinition
    var onSaved: ((KeyboardPageDefinition) -> Void)?
    let inheritedSplit: LayoutSplitConfiguration?
    let isPhoneLayout: Bool
    /// The shape of the keyboard this page is paired with, so the preview takes its width.
    let mainLayout: KeyboardLayoutKind?

    init(
        page: KeyboardPageDefinition, inheritedSplit: LayoutSplitConfiguration? = nil,
        isPhoneLayout: Bool = false, mainLayout: KeyboardLayoutKind? = nil,
        onSaved: ((KeyboardPageDefinition) -> Void)? = nil
    ) {
        let materialized = page.materialized()
        original = materialized
        _draft = State(initialValue: materialized)
        _selected = State(initialValue: materialized.firstKeyPath ?? .row(0, key: 0))
        self.onSaved = onSaved
        self.inheritedSplit = inheritedSplit
        self.isPhoneLayout = isPhoneLayout
        self.mainLayout = mainLayout
    }

    private var categorized: Bool { draft.symbolPresentation == .categorized }

    /// Only pages that own bilingual rows have an initial symbol branch to author.
    private var showsInitialSymbolChoice: Bool {
        if draft.kind == .numeric { return true }
        return draft.kind == .symbols && draft.symbolPresentation != .categorized
    }

    var body: some View {
        Form {
            Section(draft.kind.title) {
                TextField("名称", text: $draft.name)
                if showsInitialSymbolChoice {
                    // Nil follows the live keyboard; the two explicit choices pin the first face
                    // of a copied bilingual page without adding a hidden parameter.
                    Picker(
                        "初始符号",
                        selection: Binding(
                            get: { draft.defaultSymbolMarks },
                            set: { draft.defaultSymbolMarks = $0 })
                    ) {
                        Text("跟随输入").tag(Optional<KeyboardNumericMarks>.none)
                        Text("中文").tag(Optional(KeyboardNumericMarks.chinese))
                        Text("英文").tag(Optional(KeyboardNumericMarks.ascii))
                    }
                }
            }
            Section("预览") {
                KeyboardPagePreviewView(
                    page: draft, inheritedSplit: inheritedSplit, isPhoneLayout: isPhoneLayout,
                    mainLayout: mainLayout, skin: AppearanceManager.shared.applied.skin,
                    onSelectKey: { selected = $0 },
                    selectedPageKey: selected)
            }
            // The selected key's fields and position sit right under the preview that selects it.
            selectedKeyFields
            if !categorized {
                SelectedRowKeyActions(rows: rowsBinding, selected: selectedRowBinding)
            }
            if draft.key(at: selected) != nil {
                keyPositionSection
            }
            if draft.chrome != nil, !draft.hasInputModeSwitchKey {
                Section {
                    Button("添加\(UserTerminology.globeKey)", systemImage: "globe") { addInputModeSwitchKey() }
                        .disabled(!draft.canAppendKey(to: .chrome(.bottom)))
                }
            }
            if categorized {
                KeyboardCategoryEditorView(
                    categories: Binding(get: { draft.categories ?? [] }, set: { draft.categories = $0 }),
                    inheritedSplit: .resolving(page: draft.split, main: inheritedSplit), mainLayout: mainLayout)
            } else {
                KeyboardRowsEditor(rows: rowsBinding, selected: selectedRowBinding)
            }
            if draft.chrome != nil {
                KeyboardChromeKeysEditor(
                    chrome: Binding(
                        get: { draft.chrome ?? KeyboardPageChrome() },
                        set: { chrome in draft = draft.settingChrome(chrome).settingSplitAdjusted(draft.split) }),
                    selected: $selected, allowsLeading: !categorized)
            }
            // The footer cut lives at index rows.count, so its authored row joins the cut list.
            KeyboardSplitEditor(
                rows: draft.splitRows, rowTitles: splitEditorRowTitles,
                split: Binding(get: { draft.split }, set: { draft = draft.settingSplit($0) }),
                allowsInheritance: true)
        }
        .disabled(saving)
        .environment(\.widthFieldValidity, widthValidity)
        .navigationTitle("编辑页面")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(draft != original || saving)
        .interactiveDismissDisabled(draft != original || saving)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { if draft != original { confirmingDiscard = true } else { dismiss() } }.disabled(saving)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save() }.disabled(saving)
            }
        }
        .confirmationDialog("放弃未保存的更改？", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("放弃更改", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        }
        .alert("页面没有保存", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private var rowsBinding: Binding<[LayoutRow]> {
        Binding(
            get: { draft.rows },
            set: { rows in
                draft.rows = rows
                draft = draft.settingSplitAdjusted(draft.split)
            })
    }

    private var splitEditorRowTitles: [String] {
        var titles = draft.rows.indices.map { "第 \($0 + 1) 行" }
        if let bottom = draft.chrome?.bottom, !bottom.isEmpty { titles.append("底行") }
        return titles
    }

    /// Adds the globe key the machine may require, at the footer's leftmost slot. Never automatic:
    /// the save gate reports the missing key and the author decides.
    private func addInputModeSwitchKey() {
        guard let chrome = draft.chrome, draft.canAppendKey(to: .chrome(.bottom)) else { return }
        let globe = LayoutKey(label: "🌐", action: LayoutAction(.globe), titleMode: .automatic)
        draft = draft.settingChrome(chrome.settingKeys([globe] + chrome.bottom, in: .bottom))
            .settingSplitAdjusted(draft.split)
        selected = .chrome(.bottom, key: 0)
    }

    // MARK: - Selected key

    private var selectedRowBinding: Binding<LayoutKeyPath> {
        Binding(
            get: {
                if case .row(let row, let key) = selected { return .row(row, key: key) }
                return .row(-1, key: -1)
            },
            set: { path in
                if case .row(let row, let key) = path { selected = .row(row, key: key) }
            })
    }

    @ViewBuilder
    private var selectedKeyFields: some View {
        if let key = draft.key(at: selected) {
            LayoutKeyFields(
                key: key, allowsCode: false, allowsTitleMode: true,
                widthLabel: isRailSelection ? "高度比例" : "宽度比例"
            ) { updated in
                draft = draft.replacingKey(at: selected, with: updated)
            }
            .id(selected)
        }
    }

    /// One place for ordering, copying, deleting and moving the selected key between areas.
    @ViewBuilder
    private var keyPositionSection: some View {
        let current = selected.region
        let targets = draft.editableKeyRegions.filter { $0 != current }
        Section("按键位置") {
            if case .chrome(let region, let index) = selected {
                let count = draft.chrome?.keys(in: region).count ?? 0
                HStack {
                    Button(isRail(region) ? "上移" : "前移") { apply(draft.reorderingChromeKey(at: selected, by: -1)) }
                        .disabled(index == 0)
                    Spacer()
                    Button(isRail(region) ? "下移" : "后移") { apply(draft.reorderingChromeKey(at: selected, by: 1)) }
                        .disabled(index >= count - 1)
                }
                Button("复制按键") { apply(draft.duplicatingChromeKey(at: selected)) }
                    .disabled(!draft.canAppendKey(to: current))
                Button("删除按键", role: .destructive) { removeSelectedChromeKey() }
            }
            if !targets.isEmpty {
                Menu("移到其他区域") {
                    ForEach(targets, id: \.self) { target in
                        Button(title(target)) { apply(draft.movingKey(at: selected, to: target)) }
                            .disabled(!draft.canMoveKey(at: selected, to: target))
                    }
                }
                Menu("复制到其他区域") {
                    ForEach(targets, id: \.self) { target in
                        Button(title(target)) { apply(draft.copyingKey(at: selected, to: target)) }
                            .disabled(!draft.canCopyKey(at: selected, to: target))
                    }
                }
            }
        }
        .buttonStyle(.borderless)
    }

    private func title(_ region: KeyboardPageKeyRegion) -> String {
        switch region {
        case .rows: return "按键区"
        case .chrome(.bottom): return "底行"
        case .chrome(.leading): return "左侧栏"
        case .chrome(.trailing): return "右侧栏"
        }
    }

    private var isRailSelection: Bool {
        guard case .chrome(let region, _) = selected else { return false }
        return isRail(region)
    }

    private func isRail(_ region: KeyboardPageChrome.Region) -> Bool {
        region == .leading || region == .trailing
    }

    private func apply(_ edit: (page: KeyboardPageDefinition, path: KeyboardPageKeyPath)?) {
        guard let edit else { return }
        draft = edit.page
        selected = edit.path
    }

    private func removeSelectedChromeKey() {
        guard case .chrome = selected, let updated = draft.removingKey(at: selected) else { return }
        draft = updated
        if let next = updated.selectionAfterRemoving(selected) { selected = next }
    }

    // MARK: - Save

    private func save() {
        guard !widthValidity.isInvalid else {
            error = "有按键宽度没填对，请改成大于 0 的数字，或者留空。"
            return
        }
        saving = true
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        Task { @MainActor in
            await Task.yield()
            let snapshot = draft
            defer { saving = false }
            if await manager.savePage(snapshot) {
                onSaved?(snapshot)
                dismiss()
            } else {
                error = manager.lastError
                manager.clearError()
            }
        }
    }
}
