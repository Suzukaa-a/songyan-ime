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

    init(
        page: KeyboardPageDefinition, inheritedSplit: LayoutSplitConfiguration? = nil,
        isPhoneLayout: Bool = false, onSaved: ((KeyboardPageDefinition) -> Void)? = nil
    ) {
        let materialized = page.materialized()
        original = materialized
        _draft = State(initialValue: materialized)
        _selected = State(initialValue: Self.initialSelection(materialized))
        self.onSaved = onSaved
        self.inheritedSplit = inheritedSplit
        self.isPhoneLayout = isPhoneLayout
    }

    private var categorized: Bool { draft.symbolPresentation == .categorized }

    /// Only pages that own bilingual rows have an initial symbol branch to author.
    private var showsInitialSymbolChoice: Bool {
        if draft.kind == .numeric { return true }
        return draft.kind == .symbols && draft.symbolPresentation != .categorized
    }

    /// A categorised page has no rows, so start on its first authored function key instead.
    private static func initialSelection(_ page: KeyboardPageDefinition) -> KeyboardPageKeyPath {
        if let first = page.rows.first, !first.keys.isEmpty { return .row(0, key: 0) }
        if let chrome = page.chrome {
            for region in [KeyboardPageChrome.Region.bottom, .trailing, .leading]
            where !chrome.keys(in: region).isEmpty {
                return .chrome(region, key: 0)
            }
        }
        return .row(0, key: 0)
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
                    onSelectKey: { selected = $0 },
                    selectedPageKey: selected)
            }
            if categorized {
                KeyboardCategoryEditorView(
                    categories: Binding(get: { draft.categories ?? [] }, set: { draft.categories = $0 }),
                    inheritedSplit: .resolving(page: draft.split, main: inheritedSplit))
            } else {
                KeyboardRowsEditor(
                    rows: Binding(
                        get: { draft.rows },
                        set: { rows in
                            draft.rows = rows
                            draft = draft.settingSplit(
                                KeyboardSplitEditor.adjusted(draft.split, rows: splitEditorRows))
                        }), selected: selectedRowBinding,
                    rowKeyLimit: LayoutResourceBudget.keysPerRegion + LayoutResourceBudget.pageControlRowKeys)
            }
            // The footer cut lives at index rows.count, so its authored row joins the cut list.
            KeyboardSplitEditor(
                rows: splitEditorRows, rowTitles: splitEditorRowTitles,
                split: Binding(get: { draft.split }, set: { draft = draft.settingSplit($0) }),
                allowsInheritance: true)
            if draft.chrome != nil {
                KeyboardChromeKeysEditor(
                    chrome: Binding(
                        get: { draft.chrome ?? KeyboardPageChrome() },
                        set: { chrome in
                            draft = draft.settingChrome(chrome)
                            draft = draft.settingSplit(
                                KeyboardSplitEditor.adjusted(draft.split, rows: splitEditorRows))
                        }),
                    selected: $selected, allowsLeading: !categorized)
            }
            if draft.chrome != nil, !draft.hasInputModeSwitchKey {
                Section {
                    Button("添加地球键", systemImage: "globe") { addInputModeSwitchKey() }
                        .disabled((draft.chrome?.bottom.count ?? 0) >= LayoutResourceBudget.keysPerRegion)
                }
            }
            selectedKeyFields
            if draft.key(at: selected) != nil {
                keyPositionSection
            }
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

    /// Content rows plus the authored footer row, so a stored footer cut is preserved and editable.
    private var splitEditorRows: [LayoutRow] { Self.splitRows(of: draft) }

    private static func splitRows(of page: KeyboardPageDefinition) -> [LayoutRow] {
        guard let bottom = page.chrome?.bottom, !bottom.isEmpty else { return page.rows }
        return page.rows + [LayoutRow(keys: bottom)]
    }

    private var splitEditorRowTitles: [String] {
        var titles = draft.rows.indices.map { "第 \($0 + 1) 行" }
        if let bottom = draft.chrome?.bottom, !bottom.isEmpty { titles.append("页底") }
        return titles
    }

    /// Adds the globe key the machine may require, at the footer's leftmost slot. Never automatic:
    /// the save gate reports the missing key and the author decides.
    private func addInputModeSwitchKey() {
        guard var chrome = draft.chrome,
            chrome.bottom.count < LayoutResourceBudget.keysPerRegion
        else { return }
        chrome.bottom.insert(
            LayoutKey(label: "🌐", action: LayoutAction(.globe), titleMode: .automatic), at: 0)
        draft = draft.settingChrome(chrome)
        adjustSplitForChrome()
        selected = .chrome(.bottom, key: 0)
    }

    // MARK: - Selected key

    private var selectedRowBinding: Binding<LayoutKeyPath> {
        Binding(
            get: {
                if case .row(let row, let key) = selected { return .row(row, key: key) }
                return .row(0, key: 0)
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
                widthLabel: isRailSelection ? "相对高度" : "相对宽度"
            ) { updated in
                draft = draft.replacingKey(at: selected, with: updated)
            }
            .id(selected)
        }
    }

    @ViewBuilder
    private var keyPositionSection: some View {
        Section("按键位置") {
            if let region = selectedChromeRegion, let index = selectedChromeIndex {
                let keys = draft.chrome?.keys(in: region) ?? []
                HStack {
                    Button(isRail(region) ? "上移" : "前移") { moveChromeKey(region, index: index, by: -1) }
                        .disabled(index == 0)
                    Spacer()
                    Button(isRail(region) ? "下移" : "后移") { moveChromeKey(region, index: index, by: 1) }
                        .disabled(index >= keys.count - 1)
                }
                Button("复制按键") { duplicateChromeKey(region, index: index) }
                Button("删除按键", role: .destructive) { removeChromeKey(region, index: index) }
            }
            if let current = selectedRegion {
                Menu("移到其他区域") {
                    ForEach(transferTargets.filter { $0 != current }, id: \.self) { target in
                        Button(target.title) { transferSelected(to: target) }
                            .disabled(!canTransfer(to: target))
                    }
                }
                Menu("复制到其他区域") {
                    ForEach(transferTargets.filter { $0 != current }, id: \.self) { target in
                        Button(target.title) { copySelected(to: target) }
                            .disabled(!canCopy(to: target))
                    }
                }
            }
        }
        .buttonStyle(.borderless)
    }

    private var isRailSelection: Bool {
        guard let region = selectedChromeRegion else { return false }
        return isRail(region)
    }

    private var selectedChromeRegion: KeyboardPageChrome.Region? {
        if case .chrome(let region, _) = selected { return region }
        return nil
    }

    private var selectedChromeIndex: Int? {
        if case .chrome(_, let index) = selected { return index }
        return nil
    }

    private func isRail(_ region: KeyboardPageChrome.Region) -> Bool {
        region == .leading || region == .trailing
    }

    // MARK: - Cross-region move and copy

    /// Regions a key can be moved between. A categorised page has no row area and its left rail is
    /// category navigation, so only the footer and the right rail are authored there.
    private enum PageKeyRegion: Hashable {
        case rows
        case chrome(KeyboardPageChrome.Region)

        var title: String {
            switch self {
            case .rows: return "主按键区"
            case .chrome(.bottom): return "页底"
            case .chrome(.leading): return "左侧栏"
            case .chrome(.trailing): return "右侧栏"
            }
        }
    }

    private var selectedRegion: PageKeyRegion? {
        switch selected {
        case .row: return .rows
        case .chrome(let region, _): return .chrome(region)
        }
    }

    private var transferTargets: [PageKeyRegion] {
        var targets: [PageKeyRegion] = []
        if !categorized { targets.append(.rows) }
        targets.append(.chrome(.bottom))
        if !categorized { targets.append(.chrome(.leading)) }
        targets.append(.chrome(.trailing))
        return targets
    }

    /// Whether the selected key can leave its current region at all (the last key of the only row
    /// cannot: a page keeps at least one content row).
    private func canRemoveSelectedKey() -> Bool {
        switch selected {
        case .chrome:
            return draft.key(at: selected) != nil
        case .row(let row, let index):
            guard draft.rows.indices.contains(row), draft.rows[row].keys.indices.contains(index) else {
                return false
            }
            return draft.rows[row].keys.count > 1 || draft.rows.count > 1
        }
    }

    /// Whether the key can be appended to the target region; checked before any removal so a move
    /// that cannot finish never loses the key.
    private func canAppend(to target: PageKeyRegion) -> Bool {
        switch target {
        case .rows:
            guard let last = draft.rows.last else { return false }
            return last.keys.count < LayoutResourceBudget.keysPerRegion + LayoutResourceBudget.pageControlRowKeys
        case .chrome(let region):
            return !chromeIsFull(region)
        }
    }

    private func canTransfer(to target: PageKeyRegion) -> Bool {
        target != selectedRegion && canRemoveSelectedKey() && canAppend(to: target)
    }

    private func canCopy(to target: PageKeyRegion) -> Bool {
        target != selectedRegion && canAppend(to: target)
    }

    private func transferSelected(to target: PageKeyRegion) {
        guard canTransfer(to: target), let key = draft.key(at: selected) else { return }
        // Remove and insert on a copy; the draft changes only when both halves succeeded.
        guard let removed = Self.removingKey(at: selected, from: draft) else { return }
        var updated = removed
        guard let movedPath = Self.append(key, to: target, page: &updated) else { return }
        draft = updated
        selected = movedPath
    }

    private func copySelected(to target: PageKeyRegion) {
        guard canCopy(to: target), let key = draft.key(at: selected) else { return }
        var updated = draft
        guard let copiedPath = Self.append(key, to: target, page: &updated) else { return }
        draft = updated
        selected = copiedPath
    }

    private static func removingKey(
        at path: KeyboardPageKeyPath, from page: KeyboardPageDefinition
    ) -> KeyboardPageDefinition? {
        var updated = page
        switch path {
        case .chrome(let region, let index):
            guard var chrome = updated.chrome else { return nil }
            var keys = chrome.keys(in: region)
            guard keys.indices.contains(index) else { return nil }
            keys.remove(at: index)
            set(keys, in: region, chrome: &chrome)
            updated.chrome = chrome
        case .row(let row, let index):
            guard updated.rows.indices.contains(row), updated.rows[row].keys.indices.contains(index) else {
                return nil
            }
            if updated.rows[row].keys.count == 1 {
                // A row with its last key would become an empty row, so the row goes with the key.
                guard updated.rows.count > 1 else { return nil }
                updated.rows.remove(at: row)
            } else {
                var keys = updated.rows[row].keys
                keys.remove(at: index)
                updated.rows[row] = LayoutRow(keys: keys)
            }
        }
        updated.split = KeyboardSplitEditor.adjusted(updated.split, rows: splitRows(of: updated))
        return updated
    }

    @discardableResult
    private static func append(
        _ key: LayoutKey, to target: PageKeyRegion, page: inout KeyboardPageDefinition
    ) -> KeyboardPageKeyPath? {
        switch target {
        case .rows:
            guard !page.rows.isEmpty else { return nil }
            let row = page.rows.count - 1
            var keys = page.rows[row].keys
            guard keys.count < LayoutResourceBudget.keysPerRegion + LayoutResourceBudget.pageControlRowKeys else {
                return nil
            }
            keys.append(key)
            page.rows[row] = LayoutRow(keys: keys)
            page.split = KeyboardSplitEditor.adjusted(page.split, rows: splitRows(of: page))
            return .row(row, key: keys.count - 1)
        case .chrome(let region):
            guard var chrome = page.chrome else { return nil }
            var keys = chrome.keys(in: region)
            guard keys.count < LayoutResourceBudget.keysPerRegion else { return nil }
            keys.append(key)
            set(keys, in: region, chrome: &chrome)
            page.chrome = chrome
            page.split = KeyboardSplitEditor.adjusted(page.split, rows: splitRows(of: page))
            return .chrome(region, key: keys.count - 1)
        }
    }

    private func adjustSplitForChrome() {
        draft = draft.settingSplit(KeyboardSplitEditor.adjusted(draft.split, rows: splitEditorRows))
    }

    private func chromeIsFull(_ region: KeyboardPageChrome.Region) -> Bool {
        (draft.chrome?.keys(in: region).count ?? 0) >= LayoutResourceBudget.keysPerRegion
    }

    private static func set(
        _ keys: [LayoutKey], in region: KeyboardPageChrome.Region, chrome: inout KeyboardPageChrome
    ) {
        switch region {
        case .bottom: chrome.bottom = keys
        case .leading: chrome.leading = keys
        case .trailing: chrome.trailing = keys
        }
    }

    private func normalizeSelection() {
        if draft.key(at: selected) != nil { return }
        if !categorized, let first = draft.rows.first, !first.keys.isEmpty {
            selected = .row(0, key: 0)
            return
        }
        if let chrome = draft.chrome {
            for region in [KeyboardPageChrome.Region.bottom, .trailing, .leading]
            where !chrome.keys(in: region).isEmpty {
                selected = .chrome(region, key: 0)
                return
            }
        }
    }

    // MARK: - Chrome key order

    private func moveChromeKey(_ region: KeyboardPageChrome.Region, index: Int, by offset: Int) {
        guard var chrome = draft.chrome else { return }
        var keys = chrome.keys(in: region)
        let target = index + offset
        guard keys.indices.contains(index), keys.indices.contains(target) else { return }
        keys.swapAt(index, target)
        Self.set(keys, in: region, chrome: &chrome)
        draft = draft.settingChrome(chrome)
        selected = .chrome(region, key: target)
    }

    private func duplicateChromeKey(_ region: KeyboardPageChrome.Region, index: Int) {
        guard !chromeIsFull(region), var chrome = draft.chrome else { return }
        var keys = chrome.keys(in: region)
        guard keys.indices.contains(index) else { return }
        keys.insert(keys[index], at: index + 1)
        Self.set(keys, in: region, chrome: &chrome)
        draft = draft.settingChrome(chrome)
        adjustSplitForChrome()
        selected = .chrome(region, key: index + 1)
    }

    private func removeChromeKey(_ region: KeyboardPageChrome.Region, index: Int) {
        guard var chrome = draft.chrome else { return }
        var keys = chrome.keys(in: region)
        guard keys.indices.contains(index) else { return }
        keys.remove(at: index)
        Self.set(keys, in: region, chrome: &chrome)
        draft = draft.settingChrome(chrome)
        adjustSplitForChrome()
        if keys.isEmpty {
            normalizeSelection()
        } else {
            selected = .chrome(region, key: min(index, keys.count - 1))
        }
    }

    // MARK: - Save

    private func save() {
        guard !widthValidity.isInvalid else {
            error = "有宽度还没填对：请把标红处改成大于 0 的数字，或留空自动。"
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
