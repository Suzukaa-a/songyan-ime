import KeyboardCore
import LayoutKit
import SwiftUI

struct KeyboardPageManagementView: View {
    var keyboardNames = KeyboardNames()
    @ObservedObject private var manager = LayoutManager.shared
    @State private var editing: KeyboardPageDefinition?
    @State private var removing: KeyboardPageDefinition?
    @State private var restoring: KeyboardPageDefinition?
    @State private var error: String?
    @State private var busyMessage: String?

    var body: some View {
        List {
            ForEach(KeyboardPageKind.allCases, id: \.self) { kind in
                Section(kind.title) {
                    ForEach(manager.registry.pages.filter { $0.kind == kind }) { page in
                        row(page, usage: keyboardNames.usage(manager.registry.keyboards(usingPage: page.id)))
                    }
                }
            }
        }
        .disabled(busyMessage != nil)
        .overlay { if let busyMessage { ProgressView(busyMessage) } }
        .navigationTitle(UserTerminology.pageLibrary)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { page in NavigationStack { KeyboardPageEditorView(page: page) } }
        .confirmationDialog(
            "删除「\(removing?.name ?? "")」？",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除页面", role: .destructive) {
                guard let page = removing else { return }
                removing = nil
                Task {
                    if !(await manager.removePage(page.id)) {
                        error = manager.lastError
                        manager.clearError()
                    }
                }
            }
        }
        .confirmationDialog(
            "恢复预设？", isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } }),
            titleVisibility: .visible
        ) {
            Button("恢复预设", role: .destructive) {
                guard let preset = restoring else { return }
                restoring = nil
                busyMessage = "正在恢复预设…"
                Task {
                    defer { busyMessage = nil }
                    if !(await manager.savePage(preset)) {
                        error = manager.lastError
                        manager.clearError()
                    }
                }
            }
        } message: {
            Text("你对这个页面的修改会被清除。")
        }
        .alert(
            UserTerminology.pageLibrary, isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
        ) {
            Button("好", role: .cancel) { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    /// Tapping a row opens its actions; a custom page can also be deleted by swiping. A page a
    /// keyboard uses says which one and offers no delete.
    private func row(_ page: KeyboardPageDefinition, usage: String?) -> some View {
        Menu {
            actions(page, usage: usage)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(page.name).font(.headline).foregroundStyle(.primary)
                Text(summary(page)).font(.caption).foregroundStyle(.secondary)
                if let usage {
                    Text(usage).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        // A Menu tints its label with the accent colour; the plain style keeps the row looking
        // like an ordinary list row while a tap still opens the menu.
        .buttonStyle(.plain)
        .padding(.vertical, 2)
        .swipeActions {
            if !isPreset(page), usage == nil {
                Button("删除", role: .destructive) { removing = page }
            }
        }
    }

    @ViewBuilder
    private func actions(_ page: KeyboardPageDefinition, usage: String?) -> some View {
        if !isPreset(page) {
            Button("编辑", systemImage: "pencil") { openEditor(page) }
        }
        if page.numericPresentation == .automatic {
            Menu("复制并编辑", systemImage: "plus.square.on.square") {
                Button("复制中文 123") { copy(page, numericMarks: .chinese) }
                Button("复制英文 123") { copy(page, numericMarks: .ascii) }
                Button("复制\(UserTerminology.phoneDigitPad)") {
                    copy(page, numericMarks: .chinese, numericForm: .phoneDigitPad)
                }
            }
        } else if page.symbolPresentation == .automatic {
            Menu("复制并编辑", systemImage: "plus.square.on.square") {
                Button("复制多行符号页") { copy(page, presentation: .rows) }
                Button("复制分类符号页") { copy(page, presentation: .categorized) }
            }
        } else {
            Button("复制并编辑", systemImage: "plus.square.on.square") { copy(page) }
        }
        if let preset = KeyboardPagePresets.all.first(where: { $0.id == page.id }), preset != page {
            Button("恢复预设", systemImage: "arrow.counterclockwise") { restoring = preset }
        }
        if !isPreset(page) {
            Button("删除", systemImage: "trash", role: .destructive) { removing = page }
                .disabled(usage != nil)
        }
    }

    private func summary(_ page: KeyboardPageDefinition) -> String {
        if page.numericPresentation == .automatic {
            return "标点跟着中英文，9 键是\(UserTerminology.phoneDigitPad)"
        }
        if page.numericPresentation == .keypad {
            let content = page.rows.reduce(0) { $0 + $1.keys.count }
            return "\(UserTerminology.phoneDigitPad) · 共 \(content + page.chromeKeys.count) 个按键"
        }
        if page.usesSymbolBrowser {
            guard let categories = page.categories else {
                return page.symbolPresentation == .automatic ? "样式在「输入选项」中设置" : "分类浏览"
            }
            return "\(categories.count) 个分类"
        }
        let content = page.rows.reduce(0) { $0 + $1.keys.count }
        if page.chromeKeys.isEmpty {
            return "\(page.rows.count) 行 · \(content) 个按键"
        }
        return "\(page.rows.count) 行 · \(content) 个内容键 · \(page.chromeKeys.count) 个功能键"
    }

    private func copy(
        _ page: KeyboardPageDefinition, presentation: KeyboardSymbolPresentation? = nil,
        numericMarks: KeyboardNumericMarks? = nil, numericForm: KeyboardNumericForm? = nil
    ) {
        busyMessage = "正在准备页面…"
        Task { @MainActor in
            defer { busyMessage = nil }
            do {
                editing = try await KeyboardPageDraftFactory.copy(
                    page, presentation: presentation, numericMarks: numericMarks, numericForm: numericForm)
            } catch let failure {
                error = LayoutManager.friendly(failure, context: .pageCopy)
            }
        }
    }

    /// Opening materialises the stored page once, so the editor edits authored data; a category page
    /// without its snapshot reads the symbol library first on the background queue.
    private func openEditor(_ page: KeyboardPageDefinition) {
        guard page.numericPresentation != .automatic else { return }
        busyMessage = "正在准备页面…"
        Task { @MainActor in
            defer { busyMessage = nil }
            do {
                editing = try await KeyboardPageDraftFactory.editableDraft(page)
            } catch {
                self.error = "分类没有读取成功，请重试。"
            }
        }
    }

    private func isPreset(_ page: KeyboardPageDefinition) -> Bool {
        KeyboardPagePresets.all.contains { $0.id == page.id }
    }
}
