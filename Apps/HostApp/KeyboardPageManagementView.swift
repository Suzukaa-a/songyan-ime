import LayoutKit
import SwiftUI

struct KeyboardPageManagementView: View {
    @ObservedObject private var manager = LayoutManager.shared
    @State private var editing: KeyboardPageDefinition?
    @State private var removing: KeyboardPageDefinition?
    @State private var restoring: KeyboardPageDefinition?
    @State private var error: String?
    @State private var preparing = false

    var body: some View {
        List {
            ForEach(KeyboardPageKind.allCases, id: \.self) { kind in
                Section(kind.title) {
                    ForEach(manager.registry.pages.filter { $0.kind == kind }) { page in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(page.name).font(.headline)
                            Text(summary(page))
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                if !isPreset(page) {
                                    Button("编辑") { openEditor(page) }
                                    Spacer()
                                    Button("删除", role: .destructive) { removing = page }
                                }
                                if let preset = KeyboardPagePresets.all.first(where: { $0.id == page.id }),
                                    preset != page
                                {
                                    Button("恢复预设") { restoring = preset }
                                }
                                if page.numericPresentation == .automatic {
                                    Menu("复制并编辑") {
                                        Button("复制中文 123") { copy(page, numericMarks: .chinese) }
                                        Button("复制英文 123") { copy(page, numericMarks: .ascii) }
                                        Button("复制数字九宫格") {
                                            copy(page, numericMarks: .chinese, numericForm: .phoneDigitPad)
                                        }
                                    }
                                } else if page.symbolPresentation == .automatic {
                                    Menu("复制并编辑") {
                                        Button("复制多行符号页") { copy(page, presentation: .rows) }
                                        Button("复制分类符号页") { copy(page, presentation: .categorized) }
                                    }
                                } else {
                                    Button("复制并编辑") { copy(page) }
                                }
                            }.buttonStyle(.borderless)
                        }.padding(.vertical, 4)
                    }
                }
            }
        }
        .disabled(preparing)
        .overlay { if preparing { ProgressView("正在读取分类…") } }
        .navigationTitle("页面库")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { page in NavigationStack { KeyboardPageEditorView(page: page) } }
        .confirmationDialog(
            "删除这个页面？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
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
                preparing = true
                Task {
                    defer { preparing = false }
                    if !(await manager.savePage(preset)) {
                        error = manager.lastError
                        manager.clearError()
                    }
                }
            }
        } message: {
            Text("会替换这个页面的编辑内容。")
        }
        .alert("页面库", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private func summary(_ page: KeyboardPageDefinition) -> String {
        if page.numericPresentation == .automatic {
            return "标点跟着中英文，9 键是数字九宫格"
        }
        if page.numericPresentation == .keypad {
            let content = page.rows.reduce(0) { $0 + $1.keys.count }
            return "数字九宫格 · 共 \(content + page.chromeKeys.count) 个按键"
        }
        if page.usesSymbolBrowser {
            guard let categories = page.categories else {
                return page.symbolPresentation == .automatic ? "按「输入选项」里的符号样式显示" : "分类浏览"
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
        preparing = true
        Task { @MainActor in
            defer { preparing = false }
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
        preparing = true
        Task { @MainActor in
            defer { preparing = false }
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
