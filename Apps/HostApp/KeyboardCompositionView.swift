import KeyboardCore
import LayoutKit
import SwiftUI

struct KeyboardCompositionView: View {
    let keyboard: UserKeyboard
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var manager = LayoutManager.shared
    @State private var draft: KeyboardComposition
    @State private var baseline: KeyboardComposition
    @State private var editingPage: KeyboardPageDefinition?
    @State private var editingMain: LayoutDefinition?
    @State private var copiedMainID: String?
    @State private var saving = false
    @State private var preparingPage = false
    @State private var initialized = false
    @State private var error: String?
    @State private var confirmingDiscard = false

    init(keyboard: UserKeyboard) {
        self.keyboard = keyboard
        let registry = LayoutManager.shared.registry
        let defaultID =
            registry.layouts.first {
                $0.supportsComposition(
                    inputMethodID: keyboard.inputMethodID,
                    layout: LayoutInput.Builtin(rawValue: keyboard.layout.rawValue)!)
            }?.id ?? keyboard.layout.rawValue
        let composition = registry.composition(for: keyboard.id, defaultMainLayoutID: defaultID)
        _draft = State(initialValue: composition)
        _baseline = State(initialValue: composition)
    }

    private var layouts: [LayoutDefinition] {
        manager.registry.layouts.filter {
            $0.supportsComposition(
                inputMethodID: keyboard.inputMethodID, layout: LayoutInput.Builtin(rawValue: keyboard.layout.rawValue)!)
        }
    }

    private var mainLayout: LayoutDefinition? { manager.registry.layout(id: draft.mainLayoutID) }

    /// An automatic page previews against the selected main layout, so a phone keypad previews its
    /// digit pad instead of a row page it will never show.
    private var mainLayoutIsPhoneKeypad: Bool { mainLayout.map(PhoneKeypadStructure.matches) ?? false }

    /// A copy of the automatic 123 page takes the shape the selected main layout actually shows.
    private var mainNumericForm: KeyboardNumericForm { mainLayoutIsPhoneKeypad ? .phoneDigitPad : .rows }

    var body: some View {
        Form {
            Section {
                Text(keyboard.title)
                if !initialized { ProgressView("正在读取布局…") }
                if let message = manager.lastError { Text(message).foregroundStyle(.orange) }
            }
            Section("主布局") {
                Picker("键盘布局", selection: $draft.mainLayoutID) {
                    ForEach(layouts) { layout in Text(layout.name).tag(layout.id) }
                }
                if let layout = manager.registry.layout(id: draft.mainLayoutID) {
                    KeyboardPreviewView(layout: layout, onSelectKey: { _ in editingMain = layout })
                    Button("编辑主布局") { editingMain = layout }
                    Button("复制并编辑主布局") {
                        let copy = layout.copy()
                        copiedMainID = copy.id
                        editingMain = copy
                    }
                } else {
                    Text("请先添加主布局。").foregroundStyle(.secondary)
                    NavigationLink("管理键盘布局") { LayoutManagementView() }
                }
            }
            ForEach(KeyboardPageKind.allCases, id: \.self) { kind in
                pageSection(kind)
            }
            Section {
                NavigationLink("页面库") { KeyboardPageManagementView() }
                NavigationLink("管理键盘布局") { LayoutManagementView() }
            }
        }
        .disabled(saving || preparingPage || !initialized)
        .onReceive(manager.$registry) { registry in
            guard !initialized, manager.location != nil else { return }
            let defaultID =
                registry.layouts.first {
                    $0.supportsComposition(
                        inputMethodID: keyboard.inputMethodID,
                        layout: LayoutInput.Builtin(rawValue: keyboard.layout.rawValue)!)
                }?.id ?? keyboard.layout.rawValue
            let composition = registry.composition(for: keyboard.id, defaultMainLayoutID: defaultID)
            draft = composition
            baseline = composition
            initialized = true
        }
        .navigationTitle("页面搭配")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(draft != baseline || saving)
        .interactiveDismissDisabled(draft != baseline || saving)
        .toolbar {
            if draft != baseline || saving {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        confirmingDiscard = true
                    } label: {
                        Image(systemName: "chevron.backward")
                    }
                    .accessibilityLabel("返回")
                    .disabled(saving)
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save() }.disabled(saving || !initialized || layouts.isEmpty)
            }
        }
        .sheet(item: $editingPage) { page in
            NavigationStack {
                KeyboardPageEditorView(
                    page: page, inheritedSplit: manager.registry.layout(id: draft.mainLayoutID)?.split,
                    isPhoneLayout: mainLayoutIsPhoneKeypad
                ) { saved in draft.setPageID(saved.id, for: saved.kind) }
            }
        }
        .sheet(
            item: $editingMain,
            onDismiss: {
                if let id = copiedMainID, manager.registry.layout(id: id) != nil { draft.mainLayoutID = id }
                copiedMainID = nil
            }
        ) { layout in NavigationStack { LayoutEditorView(layout: layout) } }
        .confirmationDialog("放弃未保存的更改？", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("放弃更改", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        }
        .alert("搭配没有保存", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private func pageSection(_ kind: KeyboardPageKind) -> some View {
        Section(kind.title) {
            Picker("页面", selection: Binding(get: { draft.pageID(for: kind) }, set: { draft.setPageID($0, for: kind) }))
            {
                ForEach(manager.registry.pages.filter { $0.kind == kind }) { page in Text(page.name).tag(page.id) }
            }
            if let page = manager.registry.page(id: draft.pageID(for: kind)) {
                KeyboardPagePreviewView(
                    page: page, inheritedSplit: mainLayout?.split, isPhoneLayout: mainLayoutIsPhoneKeypad)
                if let note = pageNote(page) {
                    Text(note).font(.footnote).foregroundStyle(.secondary)
                }
                if !KeyboardPagePresets.all.contains(where: { $0.id == page.id }) {
                    Button("编辑页面") { openPageEditor(page) }
                }
                if page.numericPresentation == .automatic {
                    Menu("复制并编辑页面") {
                        // A phone main layout's automatic page is a digit pad: its keys do not
                        // depend on the punctuation width, so one copy is enough.
                        if mainNumericForm == .phoneDigitPad {
                            Button("复制数字九宫格") {
                                copyPage(page, numericMarks: .chinese, numericForm: .phoneDigitPad)
                            }
                        } else {
                            Button("复制中文 123") {
                                copyPage(page, numericMarks: .chinese, numericForm: .rows)
                            }
                            Button("复制英文 123") {
                                copyPage(page, numericMarks: .ascii, numericForm: .rows)
                            }
                        }
                    }
                } else if page.symbolPresentation == .automatic {
                    Menu("复制并编辑页面") {
                        Button("复制多行符号页") { copyPage(page, presentation: .rows) }
                        Button("复制分类符号页") { copyPage(page, presentation: .categorized) }
                    }
                } else {
                    Button("复制并编辑页面") { copyPage(page) }
                }
                if preparingPage { ProgressView("正在读取分类…") }
            }
        }
    }

    /// One line about what a page follows or how it pairs; nil when the page draws its own content.
    private func pageNote(_ page: KeyboardPageDefinition) -> String? {
        if page.numericPresentation == .keypad {
            return "数字九宫格可以搭配任何主布局。"
        }
        let resolution = KeyboardPageResolver.resolve(
            page: page, kind: page.kind,
            input: .init(
                usesASCIIPunctuation: false, mainLayoutIsPhoneKeypad: mainLayoutIsPhoneKeypad))
        switch resolution {
        case .automaticNumeric(.phoneDigitPad, _):
            return "123 页是数字九宫格。"
        case .automaticNumeric(.rows, _):
            return "标点跟着中英文切换。"
        case .automaticSymbolPage:
            // A phone keypad always opens the category browser, so only other layouts need the
            // reminder that the preference decides between the two symbol presentations.
            return mainLayoutIsPhoneKeypad ? nil : "按「输入选项」里的符号样式。"
        default:
            return nil
        }
    }

    private func copyPage(
        _ page: KeyboardPageDefinition, presentation: KeyboardSymbolPresentation? = nil,
        numericMarks: KeyboardNumericMarks? = nil, numericForm: KeyboardNumericForm? = nil
    ) {
        preparingPage = true
        Task { @MainActor in
            defer { preparingPage = false }
            do {
                editingPage = try await KeyboardPageDraftFactory.copy(
                    page, presentation: presentation, numericMarks: numericMarks, numericForm: numericForm)
            } catch let failure {
                error = "页面没有复制成功：\(KeyboardPageDraftFactory.message(for: failure))"
            }
        }
    }

    /// The editor edits authored data: opening materialises the stored page once, and a categorised
    /// page without its snapshot reads the symbol library on the background queue first.
    private func openPageEditor(_ page: KeyboardPageDefinition) {
        guard page.numericPresentation != .automatic else { return }
        preparingPage = true
        Task { @MainActor in
            defer { preparingPage = false }
            do {
                editingPage = try await KeyboardPageDraftFactory.editableDraft(
                    page, numericForm: mainNumericForm)
            } catch {
                self.error = "分类没有读取成功，请重试。"
            }
        }
    }

    private func save() {
        guard initialized, !saving else { return }
        saving = true
        let snapshot = draft
        Task {
            defer { saving = false }
            if await manager.saveComposition(snapshot, for: keyboard.id) {
                baseline = snapshot
                dismiss()
            } else {
                error = manager.lastError
                manager.clearError()
            }
        }
    }
}
