import QuickContentKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// All path resolution and mutations use the same serial queue as the keyboard's
/// recent-symbol worker. Pure reload/export reads use the resource read queue.
// `directory` is confined to SymbolLibraryWriteQueue.
private final class SymbolCatalogManagementWorker: @unchecked Sendable {
    struct Snapshot {
        var catalog: SymbolCatalog
        var hasCustomFile: Bool
        var itemCount: Int
        var categoryCount: Int
        var sourceText: String
        var readError: String?
    }
    struct Outcome {
        var snapshot: Snapshot?
        var exportData: Data?
    }

    private var directory: URL?
    private let startAccess: (URL) -> Bool
    private let stopAccess: (URL) -> Void

    init(directory: URL?, startAccess: @escaping (URL) -> Bool, stopAccess: @escaping (URL) -> Void) {
        self.directory = directory
        self.startAccess = startAccess
        self.stopAccess = stopAccess
    }

    /// Confined to SymbolLibraryWriteQueue, including the cached default probe.
    private func resolveDirectory() -> URL {
        if let directory { return directory }
        let resolved = SymbolLibraryStorage.defaultStoreDirectory()
        directory = resolved
        return resolved
    }

    private static func snapshot(_ store: SymbolCatalogStore) -> Snapshot {
        var readError: String?
        let catalog = store.loadActive { readError = $0.localizedDescription }
        let hasCustom = store.hasCustomCatalog
        return Snapshot(
            catalog: catalog, hasCustomFile: hasCustom, itemCount: catalog.items.count,
            categoryCount: catalog.orderedCategories.count,
            sourceText: hasCustom && readError == nil ? "自定义" : "默认",
            readError: readError)
    }

    func load() async -> Result<Outcome, Error> {
        let directory = await SymbolLibraryWriteQueue.async { self.resolveDirectory() }
        do {
            return try await KeyboardResourceReadQueue.async {
                .success(Outcome(snapshot: Self.snapshot(SymbolCatalogStore(directory: directory))))
            }
        } catch { return .failure(error) }
    }

    func export() async -> Result<Outcome, Error> {
        let directory = await SymbolLibraryWriteQueue.async { self.resolveDirectory() }
        do {
            return try await KeyboardResourceReadQueue.async {
                .success(Outcome(exportData: try SymbolCatalogStore(directory: directory).exportActive()))
            }
        } catch { return .failure(error) }
    }

    func importCatalog(from url: URL) async -> Result<Outcome, Error> {
        await SymbolLibraryWriteQueue.async {
            Result {
                let scoped = self.startAccess(url)
                defer { if scoped { self.stopAccess(url) } }
                let store = SymbolCatalogStore(directory: self.resolveDirectory())
                // The security scope covers the actual bounded background read,
                // validation, and write; it must not end when the UI Task starts.
                _ = try store.importCatalog(from: url)
                return Outcome(snapshot: Self.snapshot(store))
            }
        }
    }

    func restoreDefault() async -> Result<Outcome, Error> {
        await SymbolLibraryWriteQueue.async {
            Result {
                let store = SymbolCatalogStore(directory: self.resolveDirectory())
                try store.removeCustomCatalog()
                return Outcome(snapshot: Self.snapshot(store))
            }
        }
    }
}

/// MainActor publishes only completed outcomes. The busy flag is registered
/// synchronously at the action entry point, so repeated UI callbacks cannot race
/// imports/removals or let an old reload overwrite a newly imported catalog.
@MainActor
final class SymbolCatalogManagementModel: ObservableObject {
    @Published private(set) var catalog = SymbolCatalog(categories: [], items: [])
    @Published private(set) var hasCustomFile = false
    @Published private(set) var itemCount = 0
    @Published private(set) var categoryCount = 0
    @Published private(set) var sourceText = "读取中…"
    @Published private(set) var isBusy = false
    @Published private(set) var exportData: Data?
    @Published var showingExporter = false
    @Published var error: String?

    private let worker: SymbolCatalogManagementWorker
    private var pendingOperation: Task<Void, Never>?
    private var generation = 0

    init(
        storeDirectory: URL? = nil,
        startAccess: @escaping (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
        stopAccess: @escaping (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
    ) {
        worker = SymbolCatalogManagementWorker(
            directory: storeDirectory,
            startAccess: startAccess, stopAccess: stopAccess)
        reload()
    }

    @discardableResult
    func reload() -> Task<Void, Never>? {
        if isBusy { return pendingOperation }
        return perform(failure: "读取失败") { await $0.load() }
    }

    @discardableResult
    func importCatalog(from url: URL) -> Task<Void, Never>? {
        perform(failure: "无法导入") { await $0.importCatalog(from: url) }
    }

    @discardableResult
    func exportCatalog() -> Task<Void, Never>? {
        perform(failure: "无法导出") { await $0.export() }
    }

    @discardableResult
    func restoreDefault() -> Task<Void, Never>? {
        perform(failure: "恢复失败") { await $0.restoreDefault() }
    }

    private func perform(
        failure: String,
        _ operation:
            @escaping (SymbolCatalogManagementWorker) async -> Result<SymbolCatalogManagementWorker.Outcome, Error>
    ) -> Task<Void, Never>? {
        guard !isBusy else { return nil }
        isBusy = true
        generation += 1
        let generation = self.generation
        let worker = self.worker
        let task = Task { [weak self] in
            let result = await operation(worker)
            guard let self, self.generation == generation else { return }
            self.isBusy = false
            switch result {
            case .success(let outcome):
                self.error = nil
                if let snapshot = outcome.snapshot {
                    self.catalog = snapshot.catalog
                    self.hasCustomFile = snapshot.hasCustomFile
                    self.itemCount = snapshot.itemCount
                    self.categoryCount = snapshot.categoryCount
                    self.sourceText = snapshot.sourceText
                    self.error = snapshot.readError
                }
                if let data = outcome.exportData {
                    self.exportData = data
                    self.showingExporter = true
                }
            case .failure(let error):
                // Keep the last accepted source/counts and never open an exporter
                // or publish a successful import after a failed file operation.
                self.error = "\(failure)：\(error.localizedDescription)"
            }
        }
        pendingOperation = task
        return task
    }
}

/// Host-side JSON catalog management. A corrupt custom file remains removable,
/// while its displayed source truthfully identifies the default fallback.
struct SymbolCatalogManagementView: View {
    @StateObject private var model = SymbolCatalogManagementModel()
    @State private var confirmingRestore = false
    @State private var showingImporter = false
    @State private var query = ""
    @State private var category: String?

    var body: some View {
        List {
            statusSection
            importExportSection
            browseSection
        }
        .searchable(text: $query, prompt: "搜索符号、拼音或颜文字")
        .navigationTitle("符号与颜文字")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.reload() }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                model.importCatalog(from: url)
            case .failure(let error):
                model.error = error.localizedDescription
            }
        }
        .fileExporter(
            isPresented: $model.showingExporter,
            document: model.exportData.map { SymbolCatalogDocument(data: $0) },
            contentType: .json,
            defaultFilename: "symbol-catalog"
        ) { result in
            if case .failure(let error) = result {
                model.error = "导出失败：\(error.localizedDescription)"
            }
        }
        .alert("符号库", isPresented: alertBinding) {
            Button("好", role: .cancel) { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
    }

    private var browseSection: some View {
        Section("浏览") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    Button("全部") { category = nil }
                        .buttonStyle(.bordered).tint(category == nil ? .accentColor : .secondary)
                    ForEach(model.catalog.orderedCategories, id: \.id) { value in
                        Button(value.name) { category = value.id }
                            .buttonStyle(.bordered).tint(category == value.id ? .accentColor : .secondary)
                    }
                }
            }
            ForEach(browseItems) { item in
                HStack(spacing: 16) {
                    Text(item.text).font(.title3).frame(minWidth: 64)
                    VStack(alignment: .leading) {
                        Text(item.name)
                        Text(item.aliases.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("symbols.item.\(item.id)")
            }
            if browseItems.isEmpty { Text("没有找到符号").foregroundStyle(.secondary) }
        }
    }

    private var browseItems: [SymbolItem] {
        let values =
            query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? model.catalog.items : model.catalog.search(query)
        return values.filter { category == nil || $0.category == category }
    }

    private var statusSection: some View {
        Section {
            LabeledRow(label: "当前符号库", value: model.sourceText)
            LabeledRow(label: "符号", value: "\(model.itemCount) 条")
            LabeledRow(label: "分类", value: "\(model.categoryCount) 个")
            if model.isBusy { ProgressView("正在处理符号库…") }
        } header: {
            Text("符号库")
        } footer: {
            Text(model.sourceText == "自定义" ? "正在使用自定义符号库。" : model.sourceText == "默认" ? "正在使用默认符号库。" : "正在读取符号库。")
        }
    }

    private var importExportSection: some View {
        Section {
            Button {
                showingImporter = true
            } label: {
                Label("导入符号库", systemImage: "square.and.arrow.down")
            }
            Button {
                model.exportCatalog()
            } label: {
                Label("导出当前符号库", systemImage: "square.and.arrow.up")
            }
            if model.hasCustomFile {
                Button("恢复默认符号库", role: .destructive) { confirmingRestore = true }
                    .confirmationDialog("恢复默认符号库？", isPresented: $confirmingRestore, titleVisibility: .visible) {
                        Button("恢复默认", role: .destructive) { model.restoreDefault() }
                    } message: {
                        Text("将移除自定义符号库，恢复为系统默认符号。")
                    }
            }
        } header: {
            Text("导入 / 导出")
        } footer: {
            Text("支持松烟符号库文件（.json）。可先导出当前符号库作为模板。")
        }
        .disabled(model.isBusy)
    }

    private var alertBinding: Binding<Bool> {
        Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })
    }
}

/// FileDocument wrapper for the symbol catalog JSON (export to Files).
struct SymbolCatalogDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }

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

struct QuickContentManagementView: View {
    @StateObject private var model = LocalQuickContentModel()
    @State private var query = ""
    @State private var editingPhrase: CommonPhrase?
    @State private var showingImporter = false
    @State private var showingExporter = false
    @State private var confirmingEnable = false
    @State private var confirmingClear = false
    @State private var confirmingImport = false
    @State private var importURL: URL?

    var body: some View {
        List {
            if model.isBusy { ProgressView("正在处理…") }
            if let error = model.error {
                Section {
                    Text(error).foregroundStyle(.secondary)
                    Button("重试") { model.reload() }
                }
            }
            phrasesSection
            clipboardSection
        }
        .navigationTitle("常用语与剪贴板")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "搜索常用语")
        .onAppear { model.reload() }
        .sheet(item: $editingPhrase) { phrase in
            CommonPhraseEditor(phrase: phrase) { await model.savePhrase($0) }
        }
        .confirmationDialog("开启剪贴板历史？", isPresented: $confirmingEnable, titleVisibility: .visible) {
            Button("开启") { model.setClipboardEnabled(true) }
        } message: {
            Text("只保存你在松烟键盘中轻点「粘贴」输入的文字，最多 20 条，每条不超过 4 KB，仅保存在本机，关闭后全部删除。请避免粘贴密码、验证码等内容。")
        }
        .confirmationDialog("清空剪贴板历史？", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("清空历史记录", role: .destructive) { model.clearClipboard() }
        }
        .confirmationDialog("替换所有常用语？", isPresented: $confirmingImport, titleVisibility: .visible) {
            Button("导入并替换", role: .destructive) {
                if let importURL { model.importPhrases(from: importURL) }
                importURL = nil
            }
        } message: {
            Text("导入会替换现有常用语。你可以先导出一份备份。")
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                importURL = url
                confirmingImport = true
            case .failure: model.error = "无法打开文件，请重新选择常用语文件。"
            }
        }
        .onChange(of: model.exportedPhrases) { _, data in showingExporter = data != nil }
        .fileExporter(
            isPresented: $showingExporter,
            document: model.exportedPhrases.map { SymbolCatalogDocument(data: $0) },
            contentType: .json, defaultFilename: "songyan-phrases"
        ) { result in
            model.exportedPhrases = nil
            if case .failure = result { model.error = "无法导出常用语，请检查保存位置后重试。" }
        }
    }

    private var phrasesSection: some View {
        Section {
            Button {
                editingPhrase = CommonPhrase(text: "")
            } label: {
                Label("添加常用语", systemImage: "plus")
            }
            .accessibilityIdentifier("quickContent.addPhrase")
            ForEach(model.content.phrases.filter { $0.matches(query) }) { phrase in
                Button {
                    editingPhrase = phrase
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(phrase.text).foregroundStyle(.primary).lineLimit(3)
                        if !phrase.shortcut.isEmpty { Text(phrase.shortcut).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .accessibilityIdentifier("quickContent.editPhrase.\(phrase.id.uuidString)")
                .swipeActions { Button("删除", role: .destructive) { model.deletePhrase(phrase.id) } }
            }
            if model.content.phrases.isEmpty {
                Text("还没有常用语").foregroundStyle(.secondary)
            } else if model.content.phrases.filter({ $0.matches(query) }).isEmpty {
                Text("没有找到常用语").foregroundStyle(.secondary)
            }
            HStack {
                Button("导入") { showingImporter = true }.accessibilityIdentifier("quickContent.importPhrases")
                Spacer()
                Button("导出") { model.exportPhrases() }.accessibilityIdentifier("quickContent.exportPhrases")
            }
        } header: {
            Text("常用语")
        } footer: {
            Text("最多保存 100 条。在键盘的「快捷内容」中搜索并轻点输入。")
        }
        .disabled(model.isBusy || !model.isAvailable)
    }

    private var clipboardSection: some View {
        Section {
            Toggle(
                "剪贴板历史",
                isOn: Binding(
                    get: { model.content.clipboardEnabled },
                    set: { enabled in
                        if enabled { confirmingEnable = true } else { model.setClipboardEnabled(false) }
                    })
            )
            .accessibilityIdentifier("quickContent.clipboardEnabled")
            .accessibilityValue(model.content.clipboardEnabled ? "已开启" : "已关闭")
            if model.content.clipboardEnabled {
                Button("清空历史记录", role: .destructive) { confirmingClear = true }
                    .disabled(model.content.clipboard.isEmpty)
                    .accessibilityIdentifier("quickContent.clearHistory")
                ForEach(model.content.clipboard, id: \.self) { text in
                    Text(text).lineLimit(4)
                        .swipeActions { Button("删除", role: .destructive) { model.deleteClipboard(text) } }
                }
                if model.content.clipboard.isEmpty { Text("还没有历史记录").foregroundStyle(.secondary) }
            }
        } header: {
            Text("剪贴板")
        } footer: {
            Text("只保存你在松烟键盘中粘贴的文字，仅保存在本机。")
        }
        .disabled(model.isBusy || !model.isAvailable)
    }
}

// MARK: - Common phrase editing

/// Retains the draft until persistence succeeds, including retries after a failed write.
@MainActor
final class CommonPhraseDraft: ObservableObject {
    @Published var phrase: CommonPhrase
    @Published private(set) var saving = false
    @Published private(set) var error: String?
    /// Receives a frozen snapshot of the draft and returns `nil` only when it really reached disk.
    private let persist: (CommonPhrase) async -> String?

    init(phrase: CommonPhrase, persist: @escaping (CommonPhrase) async -> String?) {
        self.phrase = phrase
        self.persist = persist
    }

    /// Why the current draft cannot be saved, said the way the user can act on it; `nil` when it can.
    var validationMessage: String? {
        if phrase.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请先输入内容" }
        if phrase.text.utf8.count > LocalQuickContentStore.maximumTextBytes { return "内容超过 4 KB，请缩短后再保存" }
        if phrase.shortcut.utf8.count > 64 { return "搜索词太长，请缩短后再保存" }
        return nil
    }

    /// Saves the draft once. `dismiss` runs only after the store confirmed the write; otherwise the
    /// draft stays with the reason on screen. A second tap while the write is in flight is ignored, so
    /// one phrase is never written twice.
    func save(dismiss: () -> Void) async {
        guard !saving, validationMessage == nil else { return }
        saving = true
        error = nil
        #if canImport(UIKit)
            // Commit marked text before snapshotting, for the same reason LayoutEditorView does.
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
        await Task.yield()
        let failure = await persist(phrase)
        saving = false
        if let failure { error = failure } else { dismiss() }
    }
}

// MARK: - Common phrase editor view

struct CommonPhraseEditor: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var draft: CommonPhraseDraft
    @FocusState private var focused: Bool

    init(phrase: CommonPhrase, save: @escaping (CommonPhrase) async -> String?) {
        _draft = StateObject(wrappedValue: CommonPhraseDraft(phrase: phrase, persist: save))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("内容") {
                    TextEditor(text: $draft.phrase.text).frame(minHeight: 120).focused($focused)
                        .accessibilityIdentifier("quickContent.phraseText")
                }
                Section {
                    TextField("例如：dz、sh", text: $draft.phrase.shortcut)
                        .keyboardType(.asciiCapable).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("quickContent.phraseShortcut")
                } header: {
                    Text("搜索词（可选）")
                } footer: {
                    Text("在键盘里搜索这个词，即可找到这条常用语。")
                }
                if let error = draft.error, !draft.saving {
                    Section { Text(error).foregroundStyle(.secondary) }
                        .accessibilityIdentifier("quickContent.saveError")
                } else if let validation = draft.validationMessage, !draft.phrase.text.isEmpty {
                    Section { Text(validation).foregroundStyle(.secondary) }
                        .accessibilityIdentifier("quickContent.validationError")
                }
            }
            .disabled(draft.saving)
            .navigationTitle("编辑常用语")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.disabled(draft.saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if draft.saving {
                        ProgressView().accessibilityIdentifier("quickContent.saveProgress")
                    } else {
                        Button("保存") {
                            focused = false
                            startSave()
                        }
                        .disabled(draft.validationMessage != nil)
                        .accessibilityIdentifier("quickContent.savePhrase")
                    }
                }
            }
            // A swipe while the write is in flight must not drop the editor that owns the result.
            .interactiveDismissDisabled(draft.saving)
        }
    }

    private func startSave() {
        Task { await draft.save(dismiss: { dismiss() }) }
    }
}
