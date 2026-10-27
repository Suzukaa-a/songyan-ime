import KeyboardCore
import LayoutKit
import SwiftUI
import UniformTypeIdentifiers

/// Layout management: layouts a keyboard pairs with first, then the rest (custom ones swipe to remove),
/// bundled presets an older catalog left out can be added, JSON import/export.
/// A layout only describes key positions; it is not an input scheme/dictionary.
struct LayoutManagementView: View {
    var keyboardNames = KeyboardNames()
    @ObservedObject private var manager = LayoutManager.shared
    @State private var showingImporter = false
    @State private var importError: String?
    @State private var importedDraft: LayoutDefinition?
    @State private var pendingRemoval: [LayoutDefinition] = []

    var body: some View {
        List {
            storageSection
            pairedSection
            otherSection
            builtinSection
        }
        .navigationTitle(UserTerminology.keyboardLayout)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingImporter = true
                } label: {
                    Label("导入", systemImage: "square.and.arrow.down")
                }
                .disabled(manager.isImporting)
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task {
                    do { importedDraft = try await manager.readImport(url) } catch is CancellationError {} catch {
                        importError = LayoutManager.friendly(error, context: .imported)
                    }
                }
            } else if case .failure(let error) = result {
                importError = error.localizedDescription
            }
        }
        .alert(UserTerminology.keyboardLayout, isPresented: errorBinding) {
            Button("好", role: .cancel) {
                manager.clearError()
                importError = nil
            }
        } message: {
            Text(importError ?? manager.lastError ?? "")
        }
        .onAppear { manager.reload() }
        .sheet(item: $importedDraft) { draft in
            NavigationStack { LayoutEditorView(layout: draft) }
        }
        .confirmationDialog(removalTitle, isPresented: removalBinding, titleVisibility: .visible) {
            Button("移除布局", role: .destructive) {
                let ids = pendingRemoval.map(\.id)
                pendingRemoval = []
                Task { for id in ids { await manager.remove(id) } }
            }
        } message: {
            Text("移除后要重新导入才能再用。")
        }
    }

    private var removalTitle: String {
        pendingRemoval.count == 1 ? "移除「\(pendingRemoval[0].name)」？" : "移除 \(pendingRemoval.count) 个布局？"
    }

    private var removalBinding: Binding<Bool> {
        Binding(get: { !pendingRemoval.isEmpty }, set: { if !$0 { pendingRemoval = [] } })
    }

    // MARK: - Storage location

    /// Shown only when something needs attention: an import in progress, or layouts the keyboard
    /// cannot read. While the location is still being resolved nothing is claimed.
    @ViewBuilder private var storageSection: some View {
        let sharedFailed = manager.location.map { !$0.isShared } ?? false
        if manager.isImporting || sharedFailed {
            Section {
                if manager.isImporting {
                    ProgressView("正在读取布局…")
                }
                if sharedFailed {
                    Label("键盘暂时读不到这些布局，它们只保存在当前 App 里。", systemImage: "exclamationmark.triangle")
                }
            }
        }
    }

    // MARK: - Layouts

    /// Keyboards that open on this layout: saved pairings plus every keyboard in 我的键盘, whose
    /// default layout counts even without a saved pairing.
    private func users(of layoutID: String) -> [KeyboardCompositionKey] {
        manager.registry.keyboards(usingLayout: layoutID, among: keyboardNames.active)
    }

    @ViewBuilder private var pairedSection: some View {
        let layouts = manager.registry.layouts.filter { !users(of: $0.id).isEmpty }
        if !layouts.isEmpty {
            Section("正在被键盘使用") {
                ForEach(layouts) { layout in row(for: layout, isPaired: true) }
            }
        }
    }

    @ViewBuilder private var otherSection: some View {
        let others = manager.registry.layouts.filter { users(of: $0.id).isEmpty }
        if !others.isEmpty {
            Section("其他布局") {
                ForEach(others) { layout in row(for: layout, isPaired: false) }
                    .onDelete { offsets in
                        // Confirm first: a removed layout can only be re-imported. Staged by value so
                        // indices cannot drift while the dialog is up.
                        pendingRemoval = offsets.compactMap { others.indices.contains($0) ? others[$0] : nil }
                    }
            }
        }
    }

    @ViewBuilder private var builtinSection: some View {
        let missing = BuiltinLayouts.all.filter { builtin in
            !manager.registry.layouts.contains { $0.id == builtin.id }
        }
        if !missing.isEmpty {
            Section {
                ForEach(missing) { builtin in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(builtin.name).font(.body)
                            Text(
                                KeyboardLayoutKind(rawValue: builtin.input.builtinLayout?.rawValue ?? "").map {
                                    UserTerminology.layoutName($0)
                                } ?? ""
                            )
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("添加") { Task { await manager.addBuiltin(builtin) } }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            } header: {
                Text("内置布局")
            } footer: {
                Text("要换输入方式，请到「我的键盘」。")
            }
        }
    }

    // MARK: - Row

    private func row(for layout: LayoutDefinition, isPaired: Bool) -> some View {
        NavigationLink {
            LayoutDetailView(layoutID: layout.id, keyboardNames: keyboardNames)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(layout.name).font(.body)
                Text(rowSubtitle(layout, isPaired: isPaired))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let usage = usage(layout) {
                    Text(usage).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        // Bundled presets are the default main layouts, and a paired layout says so in its row;
        // neither can be swiped away.
        .deleteDisabled(isBuiltin(layout) || usage(layout) != nil)
    }

    private func rowSubtitle(_ layout: LayoutDefinition, isPaired: Bool) -> String {
        let source = isBuiltin(layout) ? "内置" : "自定义"
        let keyForm = keyFormDescription(layout)
        let mapping = layout.input.schemaID == nil || isPaired ? "" : " · 仅限指定输入方式"
        return "\(source) · \(keyForm)\(mapping)"
    }

    /// Layout descriptions use the unified "keyboard layout" term and do not equate skins with encodings.
    private func keyFormDescription(_ layout: LayoutDefinition) -> String {
        let keyCount = layout.rows.reduce(0) { $0 + $1.keys.count }
        if let kind = KeyboardLayoutKind(rawValue: layout.input.builtinLayout?.rawValue ?? "") {
            return UserTerminology.layoutName(kind)
        }
        return "\(layout.rows.count) 行 \(keyCount) 键"
    }

    private func isBuiltin(_ layout: LayoutDefinition) -> Bool {
        BuiltinLayouts.all.contains { $0.id == layout.id }
    }

    private func usage(_ layout: LayoutDefinition) -> String? {
        keyboardNames.usage(users(of: layout.id))
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { manager.lastError != nil || importError != nil },
            set: {
                if !$0 {
                    manager.clearError()
                    importError = nil
                }
            })
    }
}

/// Layout detail and entry to the visual editor.
struct LayoutDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var manager = LayoutManager.shared
    @AppStorage(HostAppKeys.developerOptionsEnabled) private var developerOptions = false
    let layoutID: String
    var keyboardNames = KeyboardNames()

    @State private var confirmingRemoval = false
    @State private var confirmingPresetRestore = false

    @State private var exportDocument: LayoutJSONDocument?
    @State private var exporting = false
    @State private var exportError: String?
    @State private var editingDraft: LayoutDefinition?

    private var layout: LayoutDefinition? {
        manager.registry.layout(id: layoutID)
    }

    private var usage: String? {
        keyboardNames.usage(manager.registry.keyboards(usingLayout: layoutID, among: keyboardNames.active))
    }

    var body: some View {
        List {
            if let layout {
                Section("布局") {
                    LabeledRow(label: "名称", value: layout.name)
                    if developerOptions { LabeledRow(label: "ID", value: layout.id) }
                    LabeledRow(label: "输入", value: inputText(layout))
                    LabeledRow(label: "来源", value: isBuiltin(layout) ? "内置" : "自定义导入")
                    LabeledRow(label: "按键", value: "\(layout.rows.count) 行 · \(keyCount(layout)) 个")
                    if let note = layout.note, !note.isEmpty {
                        Text(note).font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button("编辑键位与副键") { editingDraft = layout }
                    Button("复制为新布局并编辑") { editingDraft = layout.copy() }
                    if let preset = BuiltinLayouts.all.first(where: { $0.id == layout.id }), preset != layout {
                        Button("恢复预设") { confirmingPresetRestore = true }
                    }
                    Button {
                        guard let data = manager.exportData(for: layout.id) else { return }
                        exportDocument = LayoutJSONDocument(data: data)
                        exporting = true
                    } label: {
                        Label("导出", systemImage: "square.and.arrow.up")
                    }
                } header: {
                    Text("编辑")
                }

                if !isBuiltin(layout) {
                    Section {
                        Button("移除布局", role: .destructive) { confirmingRemoval = true }
                            .disabled(usage != nil)
                    } footer: {
                        if let usage { Text(usage + "，换掉后才能移除。") }
                    }
                }
            } else {
                Text("布局不存在或已被移除。").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(layout?.name ?? "布局")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "移除「\(layout?.name ?? "这个布局")」？", isPresented: $confirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("移除布局", role: .destructive) {
                Task {
                    await manager.remove(layoutID)
                    if manager.registry.layout(id: layoutID) == nil { dismiss() }
                }
            }
        } message: {
            Text("移除后要重新导入才能再用。")
        }
        .confirmationDialog("恢复预设？", isPresented: $confirmingPresetRestore, titleVisibility: .visible) {
            Button("恢复预设", role: .destructive) {
                if let preset = BuiltinLayouts.all.first(where: { $0.id == layoutID }) {
                    Task { _ = await manager.saveDraft(preset) }
                }
            }
        } message: {
            Text("你对这个布局的修改会被清除。")
        }
        .sheet(item: $editingDraft) { draft in
            NavigationStack { LayoutEditorView(layout: draft) }
        }
        .fileExporter(
            isPresented: $exporting,
            document: exportDocument,
            contentType: .json,
            defaultFilename: layout?.id ?? "layout"
        ) { result in
            if case .failure(let error) = result {
                exportError = "键盘布局没有导出：\(error.localizedDescription)"
            }
        }
        .alert(UserTerminology.keyboardLayout, isPresented: exportErrorBinding) {
            Button("好", role: .cancel) {
                manager.clearError()
                exportError = nil
            }
        } message: {
            Text(exportError ?? manager.lastError ?? "")
        }
    }

    private var exportErrorBinding: Binding<Bool> {
        Binding(
            get: { exportError != nil || manager.lastError != nil },
            set: {
                if !$0 {
                    exportError = nil
                    manager.clearError()
                }
            })
    }

    private func inputText(_ layout: LayoutDefinition) -> String {
        if let schema = layout.input.schemaID { return developerOptions ? "仅限输入方式 \(schema)" : "仅限指定输入方式" }
        if let kind = KeyboardLayoutKind(rawValue: layout.input.builtinLayout?.rawValue ?? "") {
            return UserTerminology.layoutName(kind)
        }
        return "—"
    }

    private func keyCount(_ layout: LayoutDefinition) -> Int {
        layout.rows.reduce(0) { $0 + $1.keys.count }
    }

    private func isBuiltin(_ layout: LayoutDefinition) -> Bool {
        BuiltinLayouts.all.contains { $0.id == layout.id }
    }
}

/// FileDocument wrapper: hands the layout JSON to the system export to Files.
struct LayoutJSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        data = contents
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
