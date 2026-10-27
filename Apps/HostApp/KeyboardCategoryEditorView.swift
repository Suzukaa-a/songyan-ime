import KeyboardCore
import LayoutKit
import SwiftUI

struct KeyboardCategoryEditorView: View {
    @Binding var categories: [KeyboardPageCategory]
    var inheritedSplit: LayoutSplitConfiguration?
    var mainLayout: KeyboardLayoutKind?
    @State private var selectedID: String?
    @State private var selectedKey = 0
    @State private var recentKeys: [LayoutKey] = []
    @State private var loadingRecents = false
    @State private var recentError: String?
    @State private var confirmingCategoryRemoval = false

    private var selectedIndex: Int? {
        categories.firstIndex { $0.id == selectedID } ?? categories.indices.first
    }

    var body: some View {
        Section("分类") {
            if let index = selectedIndex {
                Picker(
                    "选择分类",
                    selection: Binding(
                        get: { categories[index].id },
                        set: {
                            selectedID = $0
                            selectedKey = 0
                        }
                    )
                ) {
                    ForEach(categories) { category in Text(category.name).tag(category.id) }
                }
                HStack {
                    Button("上移分类", systemImage: "arrow.up") { moveCategory(index, by: -1) }
                        .disabled(index == 0)
                    Spacer()
                    Button("下移分类", systemImage: "arrow.down") { moveCategory(index, by: 1) }
                        .disabled(index == categories.count - 1)
                }
            }
            Button("添加分类", systemImage: "plus") {
                let category = KeyboardPageCategory(name: "新分类", keys: [newKey])
                categories.append(category)
                selectedID = category.id
                selectedKey = 0
            }
            .disabled(categories.count >= LayoutResourceBudget.pageCategories)
        }
        .buttonStyle(.borderless)
        if let index = selectedIndex {
            categoryFields(index)
        }
    }

    @ViewBuilder
    private func categoryFields(_ index: Int) -> some View {
        Section("编辑分类") {
            TextField("名称", text: $categories[index].name)
            Picker(
                "内容",
                selection: Binding(
                    get: { categories[index].source ?? .fixed },
                    set: { source in
                        categories[index].source = source
                        if source == .fixed && categories[index].keys.isEmpty { categories[index].keys = [newKey] }
                        selectedKey = 0
                        adjustSplit(index)
                    })
            ) {
                Text("自定义按键").tag(KeyboardPageCategory.Source.fixed)
                Text("最近使用").tag(KeyboardPageCategory.Source.recent)
            }
            Stepper(
                "每行 \(categories[index].columns) 列",
                value: Binding(
                    get: { categories[index].columns },
                    set: { columns in
                        categories[index].columns = columns
                        adjustSplit(index)
                    }), in: 1...LayoutResourceBudget.categoryColumns)
            Button("复制分类") {
                var copy = categories[index]
                copy.id = UUID().uuidString.lowercased()
                copy.name += " 副本"
                categories.insert(copy, at: index + 1)
                selectedID = copy.id
                selectedKey = 0
            }.disabled(categories.count >= LayoutResourceBudget.pageCategories)
            Button("删除分类", role: .destructive) { confirmingCategoryRemoval = true }
                .disabled(categories.count == 1)
        }
        .confirmationDialog(
            "删除「\(categories[index].name)」？", isPresented: $confirmingCategoryRemoval, titleVisibility: .visible
        ) {
            Button("删除分类", role: .destructive) {
                guard categories.indices.contains(index), categories.count > 1 else { return }
                categories.remove(at: index)
                selectedID = categories.first?.id
                selectedKey = 0
            }
        } message: {
            if categories.indices.contains(index), categories[index].source != .recent {
                Text("分类里的 \(categories[index].keys.count) 个按键会一起删除。")
            }
        }
        let category = categories[index]
        KeyboardSplitEditor(
            rows: splitRows(category),
            split: Binding(
                get: { categories[index].split }, set: { categories[index].split = $0 }),
            allowsInheritance: true, inheritanceTitle: "和整页一样拆分")
        if category.source == .recent {
            recentPreview(category)
                .task { await loadRecents() }
        } else {
            keyEditor(index)
        }
    }

    @ViewBuilder
    private func keyEditor(_ index: Int) -> some View {
        let category = categories[index]
        Section("点键编辑") {
            categoryPreview(category, selectable: true)
        }
        Section("按键顺序") {
            HStack {
                Button("前移") { moveKey(index, by: -1) }.disabled(selectedKey == 0)
                Spacer()
                Button("后移") { moveKey(index, by: 1) }.disabled(selectedKey >= category.keys.count - 1)
            }
            Button("添加按键") {
                categories[index].keys.append(newKey)
                selectedKey = categories[index].keys.count - 1
                adjustSplit(index)
            }.disabled(category.keys.count >= LayoutResourceBudget.categoryKeys)
            if category.keys.indices.contains(selectedKey) {
                Button("复制按键") {
                    categories[index].keys.insert(category.keys[selectedKey], at: selectedKey + 1)
                    selectedKey += 1
                    adjustSplit(index)
                }.disabled(category.keys.count >= LayoutResourceBudget.categoryKeys)
                Button("删除按键", role: .destructive) {
                    categories[index].keys.remove(at: selectedKey)
                    selectedKey = min(selectedKey, categories[index].keys.count - 1)
                    adjustSplit(index)
                }.disabled(category.keys.count == 1)
            }
        }.buttonStyle(.borderless)
        if category.keys.indices.contains(selectedKey) {
            LayoutKeyFields(
                key: category.keys[selectedKey], allowsCode: false, allowsTitleMode: true,
                allowsFunctionActions: false
            ) { key in
                categories[index].keys[selectedKey] = key
            }.id("\(category.id)-\(selectedKey)")
        }
    }

    private func categoryPreview(_ category: KeyboardPageCategory, selectable: Bool) -> some View {
        let page = KeyboardPageDefinition(
            id: "preview-\(category.id)", name: category.name, kind: .symbols, rows: [],
            split: inheritedSplit, symbolPresentation: .categorized, categories: [category])
        return KeyboardPagePreviewView(
            page: page, mainLayout: mainLayout, skin: AppearanceManager.shared.applied.skin,
            onSelectCategoryKey: selectable ? { _, key in selectedKey = key } : nil,
            selectedCategoryKey: selectable ? (category.id, selectedKey) : nil)
    }

    private var newKey: LayoutKey { .init(label: "。", action: .init(.literal, value: "。")) }

    private func moveCategory(_ index: Int, by offset: Int) {
        selectedID = categories[index].id
        categories.swapAt(index, index + offset)
    }

    private func moveKey(_ index: Int, by offset: Int) {
        categories[index].keys.swapAt(selectedKey, selectedKey + offset)
        selectedKey += offset
    }

    private func splitRows(_ category: KeyboardPageCategory) -> [LayoutRow] {
        var content = category
        if category.source == .recent { content.keys = recentKeys }
        return content.rows.map { _ in .init(keys: Array(repeating: newKey, count: category.columns)) }
    }

    private func recentPreview(_ category: KeyboardPageCategory) -> some View {
        return Section("最近使用") {
            if loadingRecents {
                ProgressView("正在读取最近使用…")
            } else if let recentError {
                Text(recentError).font(.footnote).foregroundStyle(.secondary)
                Button("重新读取") { Task { await loadRecents() } }
            } else if recentKeys.isEmpty {
                Text("还没有最近使用的符号。")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                categoryPreview(category, selectable: false)
            }
        }
    }

    @MainActor
    private func loadRecents() async {
        loadingRecents = true
        defer { loadingRecents = false }
        do {
            let keys = try await KeyboardPageDraftFactory.recentKeys()
            guard !Task.isCancelled else { return }
            recentKeys = keys
            recentError = nil
        } catch {
            guard !Task.isCancelled else { return }
            recentError = "最近使用没有读取成功，请重试。"
        }
    }

    private func adjustSplit(_ index: Int) {
        categories[index].split = KeyboardSplitEditor.adjusted(
            categories[index].split, rows: splitRows(categories[index]))
    }
}
