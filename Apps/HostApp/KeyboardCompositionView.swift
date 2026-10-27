import KeyboardCore
import LayoutKit
import SwiftUI

extension KeyboardLayoutKind {
    /// Every keyboard shape has a bundled main layout of the same shape.
    var builtinLayout: LayoutInput.Builtin {
        switch self {
        case .qwerty26: return .qwerty26
        case .merged14: return .merged14
        case .merged18: return .merged18
        case .phone9: return .phone9
        }
    }

    init(_ builtin: LayoutInput.Builtin) {
        switch builtin {
        case .qwerty26: self = .qwerty26
        case .merged14: self = .merged14
        case .merged18: self = .merged18
        case .phone9: self = .phone9
        }
    }
}

extension UserKeyboard {
    var compositionKey: KeyboardCompositionKey {
        KeyboardCompositionKey(inputMethodID: inputMethodID, layout: layout.builtinLayout)
    }
}

/// Names the keyboards a layout or page is paired with. 我的键盘 knows the names of its keyboards;
/// any other keyboard is named from its input method and shape.
struct KeyboardNames {
    var known: [String: String] = [:]
    /// The keyboards in 我的键盘 (saved or selected); a layout they open on counts as used even
    /// when they have no saved pairing.
    var active: [KeyboardCompositionKey] = []

    func title(_ key: KeyboardCompositionKey) -> String {
        if let name = known[key.rawValue] { return name }
        let layout = UserTerminology.layoutName(KeyboardLayoutKind(key.layout))
        guard let method = UserTerminology.inputMethodName(schemaID: key.inputMethodID, schemas: nil) else {
            return layout
        }
        return "\(method) · \(layout)"
    }

    /// "正在被「…」使用", or nil when no keyboard uses it.
    func usage(_ keys: [KeyboardCompositionKey]) -> String? {
        UserTerminology.usedByKeyboards(keys.map(title))
    }
}

struct KeyboardCompositionView: View {
    let keyboard: UserKeyboard
    let keyboardNames: KeyboardNames
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var manager = LayoutManager.shared
    @State private var draft: KeyboardComposition
    @State private var baseline: KeyboardComposition
    @State private var editingPage: KeyboardPageDefinition?
    @State private var editingMain: LayoutDefinition?
    @State private var saving = false
    @State private var preparingPage = false
    @State private var initialized = false
    @State private var alert: CompositionAlert?
    @State private var confirmingDiscard = false

    private struct CompositionAlert {
        let title: String
        let message: String
    }

    init(keyboard: UserKeyboard, keyboardNames: KeyboardNames = KeyboardNames()) {
        self.keyboard = keyboard
        self.keyboardNames = keyboardNames
        let composition = LayoutManager.shared.registry.composition(for: keyboard.compositionKey)
        _draft = State(initialValue: composition)
        _baseline = State(initialValue: composition)
    }

    private var layouts: [LayoutDefinition] { manager.registry.mainLayoutCandidates(for: keyboard.compositionKey) }

    private var mainLayout: LayoutDefinition? { manager.registry.resolvedLayout(id: draft.mainLayoutID) }

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
            Section(UserTerminology.mainLayout) {
                Picker(UserTerminology.keyboardLayout, selection: $draft.mainLayoutID) {
                    ForEach(layouts) { layout in Text(layout.name).tag(layout.id) }
                }
                if let layout = mainLayout {
                    KeyboardPreviewView(layout: layout, skin: AppearanceManager.shared.applied.skin)
                    Button("编辑\(UserTerminology.mainLayout)") { editingMain = layout }
                    Button("复制并编辑\(UserTerminology.mainLayout)") { editingMain = layout.copy() }
                } else {
                    Text("没有适合这个键盘的布局，请在下方「\(UserTerminology.keyboardLayout)」中添加。")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(KeyboardPageKind.allCases, id: \.self) { kind in
                pageSection(kind)
            }
            Section {
                NavigationLink(UserTerminology.pageLibrary) { KeyboardPageManagementView(keyboardNames: keyboardNames) }
                NavigationLink(UserTerminology.keyboardLayout) { LayoutManagementView(keyboardNames: keyboardNames) }
            }
        }
        .disabled(saving || preparingPage || !initialized)
        .onReceive(manager.$registry) { registry in
            guard !initialized, manager.location != nil else { return }
            let composition = registry.composition(for: keyboard.compositionKey)
            draft = composition
            baseline = composition
            initialized = true
        }
        .navigationTitle(UserTerminology.pageComposition)
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
                    page: page, inheritedSplit: mainLayout?.split, isPhoneLayout: mainLayoutIsPhoneKeypad,
                    mainLayout: keyboard.layout
                ) { saved in draft.setPageID(saved.id, for: saved.kind) }
            }
        }
        .sheet(item: $editingMain) { layout in
            NavigationStack {
                // A saved copy (from either copy button) becomes this keyboard's main layout.
                LayoutEditorView(layout: layout) { saved in draft.mainLayoutID = saved.id }
            }
        }
        .confirmationDialog("放弃未保存的更改？", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("放弃更改", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        }
        .alert(
            alert?.title ?? "", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })
        ) {
            Button("好", role: .cancel) { alert = nil }
        } message: {
            Text(alert?.message ?? "")
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
                    page: page, inheritedSplit: mainLayout?.split, isPhoneLayout: mainLayoutIsPhoneKeypad,
                    mainLayout: keyboard.layout, skin: AppearanceManager.shared.applied.skin)
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
                            Button("复制\(UserTerminology.phoneDigitPad)") {
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
                if preparingPage { ProgressView("正在准备页面…") }
            }
        }
    }

    /// One line about what a page follows or how it pairs; nil when the page draws its own content.
    private func pageNote(_ page: KeyboardPageDefinition) -> String? {
        let resolution = KeyboardPageResolver.resolve(
            page: page, kind: page.kind,
            input: .init(
                usesASCIIPunctuation: false, mainLayoutIsPhoneKeypad: mainLayoutIsPhoneKeypad))
        switch resolution {
        case .automaticNumeric(.phoneDigitPad, _):
            return "123 页是\(UserTerminology.phoneDigitPad)。"
        case .automaticNumeric(.rows, _):
            return "标点跟着中英文切换。"
        case .automaticSymbolPage:
            // A phone keypad always opens the category browser, so only other layouts need the
            // reminder that the preference decides between the two symbol presentations.
            return mainLayoutIsPhoneKeypad ? nil : "样式在「输入选项」中设置。"
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
                alert = CompositionAlert(title: "页面没有复制成功", message: LayoutManager.friendly(failure))
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
                alert = CompositionAlert(title: "页面没有打开", message: "分类没有读取成功，请重试。")
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
                alert = CompositionAlert(
                    title: "\(UserTerminology.pageComposition)没有保存", message: manager.lastError ?? "")
                manager.clearError()
            }
        }
    }
}
