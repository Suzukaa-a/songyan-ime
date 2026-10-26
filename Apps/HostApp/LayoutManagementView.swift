import KeyboardCore
import LayoutKit
import SwiftUI
import UniformTypeIdentifiers

/// Layout management (real feature page): lists the enabled order (drag to reorder / swipe to remove / disable),
/// disabled layouts can be re-enabled or removed, built-in layouts can be re-added, JSON import/export.
/// A layout only describes key positions; it is not an input scheme/dictionary.
struct LayoutManagementView: View {
    @StateObject private var manager = LayoutManager.shared
    @State private var showingImporter = false
    @State private var importError: String?
    @State private var importedDraft: LayoutDefinition?
    @State private var editMode: EditMode = .inactive
    @State private var pendingRemoval: [LayoutDefinition] = []

    var body: some View {
        List {
            storageSection
            Section { NavigationLink("页面库") { KeyboardPageManagementView() } }
            enabledSection
            pairedSection
            disabledSection
            builtinSection
        }
        .environment(\.editMode, $editMode)
        .navigationTitle("自定义键盘布局")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(editMode.isEditing ? "完成" : "编辑") {
                    withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                }
            }
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
        .alert("自定义键盘布局", isPresented: errorBinding) {
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
            Text("内置布局可重新添加；自定义布局移除后需重新导入。")
        }
    }

    private var removalTitle: String {
        pendingRemoval.count == 1 ? "移除「\(pendingRemoval[0].name)」？" : "移除 \(pendingRemoval.count) 个布局？"
    }

    private var removalBinding: Binding<Bool> {
        Binding(get: { !pendingRemoval.isEmpty }, set: { if !$0 { pendingRemoval = [] } })
    }

    // MARK: - Storage location

    private var storageSection: some View {
        Section {
            if manager.isImporting {
                ProgressView("正在读取布局…")
            }
            if let location = manager.location {
                Label(
                    location.isShared ? "布局已保存" : "布局仅保存在当前 App",
                    systemImage: location.isShared ? "checkmark.circle" : "exclamationmark.triangle")
            } else {
                // Directory resolution runs in the background; the storage location is not pretended known until it finishes.
                Label("正在检查…", systemImage: "clock")
            }
        } header: {
            Text("保存位置")
        } footer: {
            Text(storageFooter)
        }
    }

    private var storageFooter: String {
        guard let location = manager.location else {
            return ""
        }
        return location.isShared
            ? "键盘可直接使用这些键盘布局。"
            : "键盘暂时无法读取这些键盘布局，布局仍保存在本机。"
    }

    // MARK: - Enabled

    private var pairedLayoutIDs: Set<String> { Set(manager.registry.compositions.values.map(\.mainLayoutID)) }

    private var enabledSection: some View {
        let paired = pairedLayoutIDs
        return Section {
            if manager.registry.enabledLayouts.isEmpty {
                Text("启用列表需至少保留一个布局。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(manager.registry.enabledLayouts) { layout in
                row(for: layout, enabled: true, isPaired: paired.contains(layout.id))
            }
            .onMove { source, destination in
                Task { await manager.moveEnabled(from: source, to: destination) }
            }
            .onDelete { offsets in
                // Confirm before removing: a removed custom layout can only be re-imported. Staged by id so indices cannot drift during confirmation.
                let current = manager.registry.enabledLayouts
                pendingRemoval = offsets.compactMap { current.indices.contains($0) ? current[$0] : nil }
            }
        } header: {
            Text("启用列表")
        }
    }

    // MARK: - Disabled / addable

    @ViewBuilder private var pairedSection: some View {
        let paired = pairedLayoutIDs
        let layouts = manager.registry.layouts.filter {
            paired.contains($0.id) && !manager.registry.enabledIDs.contains($0.id)
        }
        if !layouts.isEmpty {
            Section("页面搭配中的布局") {
                ForEach(layouts) { layout in row(for: layout, enabled: false, isPaired: true) }
            }
        }
    }

    @ViewBuilder private var disabledSection: some View {
        let paired = pairedLayoutIDs
        let disabled = manager.registry.layouts.filter {
            !manager.registry.enabledIDs.contains($0.id) && !paired.contains($0.id)
        }
        if !disabled.isEmpty {
            Section("其它布局") {
                ForEach(disabled) { layout in
                    row(for: layout, enabled: false, isPaired: false)
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

    private func row(for layout: LayoutDefinition, enabled: Bool, isPaired: Bool) -> some View {
        // A layout bound to an input method does not currently take part in keyboard switching: no ineffective "enable" switch is shown (an enabled one can still be disabled).
        let canEnable = enabled || layout.input.schemaID == nil
        return HStack(spacing: 12) {
            NavigationLink {
                LayoutDetailView(layoutID: layout.id)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(layout.name).font(.body)
                        Text(rowSubtitle(layout, isPaired: isPaired))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                }
            }
            .buttonStyle(.plain)
            .accessibilityValue(isPaired ? "用于页面搭配" : "")
            // The switch sits outside the navigation link so tap and VoiceOver can operate it independently.
            if isPaired && !enabled {
                Text("页面搭配").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
            } else {
                Toggle(
                    isOn: Binding(
                        get: { enabled },
                        set: { on in Task { await manager.setEnabled(layout.id, on: on) } }
                    )
                ) { Text(layout.name) }
                .labelsHidden()
                .disabled(!canEnable)
                .accessibilityLabel("「\(layout.name)」在启用列表中")
            }
        }
        .padding(.vertical, 2)
    }

    private func rowSubtitle(_ layout: LayoutDefinition, isPaired: Bool) -> String {
        let source = isBuiltin(layout) ? "内置" : "自定义"
        let keyForm = keyFormDescription(layout)
        let mapping = layout.input.schemaID == nil || isPaired ? "" : " · 需搭配使用"
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

    @State private var confirmingRemoval = false
    @State private var confirmingPresetRestore = false

    @State private var exportDocument: LayoutJSONDocument?
    @State private var exporting = false
    @State private var exportError: String?
    @State private var editingDraft: LayoutDefinition?

    private var layout: LayoutDefinition? {
        manager.registry.layout(id: layoutID)
    }

    private var isEnabled: Bool {
        manager.registry.enabledIDs.contains(layoutID)
    }

    private var isPaired: Bool { manager.registry.compositions.values.contains { $0.mainLayoutID == layoutID } }

    var body: some View {
        List {
            if let layout {
                Section("布局") {
                    LabeledRow(label: "名称", value: layout.name)
                    if developerOptions { LabeledRow(label: "ID", value: layout.id) }
                    LabeledRow(label: "输入", value: inputText(layout))
                    LabeledRow(label: "来源", value: isBuiltin(layout) ? "内置" : "自定义导入")
                    LabeledRow(label: "规模", value: "\(layout.rows.count) 行 · \(keyCount(layout)) 键")
                    Text(LayoutEditorView.compatibility(layout)).font(.footnote).foregroundStyle(.secondary)
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

                Section {
                    if isEnabled {
                        Button("移出启用列表") { Task { await manager.setEnabled(layout.id, on: false) } }
                            .foregroundStyle(.orange)
                    } else if layout.input.schemaID == nil {
                        Button("加入启用列表") { Task { await manager.setEnabled(layout.id, on: true) } }
                    }
                    if isPaired {
                        NavigationLink("查看页面搭配") { UserKeyboardManagementView() }
                    } else if layout.input.schemaID != nil {
                        NavigationLink("选择键盘") { UserKeyboardManagementView() }
                    }
                    Button("移除布局", role: .destructive) { confirmingRemoval = true }
                } header: {
                    Text("状态")
                } footer: {
                    Text("启用列表需至少保留一个布局。")
                }
            } else {
                Text("布局不存在或已被移除。").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(layout?.name ?? "布局")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "移除「\(layout?.name ?? "此布局")」？", isPresented: $confirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("移除布局", role: .destructive) {
                Task {
                    await manager.remove(layoutID)
                    if manager.registry.layout(id: layoutID) == nil { dismiss() }
                }
            }
        } message: {
            Text("内置布局可重新添加；自定义布局移除后需重新导入。")
        }
        .confirmationDialog("恢复预设？", isPresented: $confirmingPresetRestore, titleVisibility: .visible) {
            Button("恢复预设", role: .destructive) {
                if let preset = BuiltinLayouts.all.first(where: { $0.id == layoutID }) {
                    Task { _ = await manager.saveDraft(preset) }
                }
            }
        } message: {
            Text("会替换这套布局的编辑内容。")
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
                exportError = "导出失败：\(error.localizedDescription)"
            }
        }
        .alert("布局", isPresented: exportErrorBinding) {
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
        if let schema = layout.input.schemaID { return developerOptions ? "输入方式（\(schema)）" : "指定输入方式" }
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
