import Foundation
import KeyboardCore
import PackageManager
import SwiftUI
import UniformTypeIdentifiers

/// Settings > 语法模型: pick the source whose input methods are being configured.
struct GrammarModelSettingsView: View {
    @ObservedObject private var center = SchemeImportCenter.shared
    @State private var loaded = false

    /// Decided once when the sources are first read, so a later refresh cannot swap the
    /// page out from under the user.
    @State private var onlySource: String?

    var body: some View {
        // One source leaves nothing to pick, so its settings open right away.
        if let onlySource {
            GrammarModelManagementView(packageID: onlySource)
        } else {
            sourceList
        }
    }

    private var sourceList: some View {
        List {
            Section {
                ForEach(center.installedPackages) { package in
                    NavigationLink(package.name) {
                        GrammarModelManagementView(packageID: package.id)
                    }.accessibilityIdentifier("sentence-model.source.\(package.id)")
                }
                if center.installedPackages.isEmpty {
                    if loaded {
                        Text("先添加输入方案，再为它设置语法模型。")
                            .font(.footnote).foregroundStyle(.secondary)
                        NavigationLink("添加输入方案") { SchemePackageImportView() }
                    } else {
                        ProgressView("正在读取输入方案…")
                    }
                }
            } footer: {
                Text("开启后，候选会按整句意思排序。")
            }
        }
        .navigationTitle("语法模型")
        .accessibilityIdentifier("sentence-model.settings")
        .task {
            await center.refresh()
            if !loaded, center.installedPackages.count == 1 {
                onlySource = center.installedPackages.first?.id
            }
            loaded = true
        }
    }
}

/// One source: which input method uses which model. One tap picks the model and applies it, so the
/// page never asks the user to choose an operation, check it, confirm it and apply it separately.
struct GrammarModelManagementView: View {
    @AppStorage(HostAppKeys.developerOptionsEnabled) private var developerOptions = false
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var center = SchemeImportCenter.shared
    let packageID: String

    @State private var deployedSchemas: [KeyboardSchemaDescriptor] = []
    @State private var bindings: [GrammarBinding] = []
    @State private var managedSchemaIDs: Set<String> = []
    @State private var statusText = "正在读取…"
    @State private var publishedCurrentInstallation = false
    @State private var notice: String?
    @State private var applying = false
    @State private var initialized = false
    @State private var isVisible = false
    @State private var statusReadID = UUID()
    /// A file or link the user picked for one model path; `nil` while no picker is open.
    @State private var pendingImport = false
    @State private var pendingRequirementPath: String?
    @State private var bindingAfterImport: String?
    @State private var enteringModelURL = false
    @State private var address = ""
    /// Toggle positions the user just set, shown until the saved state is read back.
    @State private var pendingToggles: [String: Bool] = [:]
    @State private var lastWorkspace: SchemeImportCenter.InstalledRecipeWorkspace?

    private var package: SchemeImportCenter.InstalledPackage? { center.installedPackages.first { $0.id == packageID } }
    /// A saved change replaces the workspace and reads it again; the page keeps showing
    /// the previous one meanwhile so the row just changed does not vanish under the finger.
    private var workspace: SchemeImportCenter.InstalledRecipeWorkspace? {
        liveWorkspace ?? (applying ? lastWorkspace : nil)
    }
    private var liveWorkspace: SchemeImportCenter.InstalledRecipeWorkspace? {
        center.installedWorkspace.flatMap { belongsHere($0) ? $0 : nil }
    }
    private func belongsHere(_ workspace: SchemeImportCenter.InstalledRecipeWorkspace) -> Bool {
        workspace.packageID == packageID
    }
    private var models: [String: RecipeFileResource] {
        workspace?.snapshot.fileResources.filter { $0.key.hasSuffix(".gram") } ?? [:]
    }
    private var availableSchemas: [KeyboardSchemaDescriptor] { package?.schemas ?? deployedSchemas }
    private var selectableBindings: [GrammarBinding] { bindings.filter { $0.support != .unsupported } }
    private var sourceName: String { package?.name ?? UserTerminology.inputScheme }
    private func schemaName(_ id: String) -> String {
        availableSchemas.first { $0.id == id }?.name ?? UserTerminology.inputMethod
    }
    private func modelTitle(_ path: String) -> String {
        let name = GrammarModelRecipe.displayName(for: path, sources: workspace?.sources?.files) ?? path
        return developerOptions ? name : URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
    }
    private func modelPath(_ language: String) -> String? { GrammarModelPath.path(for: language) }
    private func savedSchemaIDs(for path: String) -> Set<String> {
        Set(bindings.filter { $0.binds(modelPath: path) }.map(\.schemaID))
    }
    /// Models this source needs but has not installed yet, with the input methods asking for them.
    private var missingModels: [(path: String, schemaIDs: [String])] {
        var grouped: [String: [String]] = [:]
        for binding in bindings {
            guard let language = binding.language, let path = modelPath(language),
                models[path] == nil
            else { continue }
            grouped[path, default: []].append(binding.schemaID)
        }
        return grouped.keys.sorted().map { ($0, grouped[$0]!.sorted()) }
    }

    var body: some View {
        List {
            Section {
                Text(statusText).font(.footnote).textSelection(.enabled)
                    .accessibilityIdentifier("sentence-model.status")
                if applying || (center.busy && workspace != nil) { ProgressView(center.message ?? "正在保存…") }
                if let notice {
                    Label(notice, systemImage: "checkmark.circle")
                        .font(.footnote).foregroundStyle(.green)
                }
            }
            if workspace == nil {
                Section {
                    if let error = center.error, !center.busy, !applying {
                        Text("没能读取这个方案的模型设置。").foregroundStyle(.red)
                        if developerOptions { Text(error).font(.caption).textSelection(.enabled) }
                        Button("重试") { reloadWorkspace() }
                    } else {
                        ProgressView("正在读取…")
                    }
                }
            } else if models.isEmpty {
                // Without a model there is nothing to choose, so the first step is the only section.
                Section {
                    modelImportButtons
                } header: {
                    Text("模型文件")
                } footer: {
                    Text(
                        selectableBindings.isEmpty
                            ? "这个方案没有可以用语法模型的输入方式。"
                            : "添加后会为还没开启的输入方式开启。")
                }
                missingModelsSection
            } else {
                Section {
                    ForEach(selectableBindings, id: \.schemaID) { binding in
                        if let only = singleModelPath {
                            inputMethodToggle(binding, modelPath: only)
                        } else {
                            inputMethodRow(binding)
                        }
                    }
                    if let only = singleModelPath {
                        let off = selectableBindings.filter { !$0.binds(modelPath: only) }
                        if off.count > 1 {
                            Button("全部开启") { applyAll(modelPath: only, to: off) }
                                .disabled(center.busy || applying)
                        }
                    }
                } header: {
                    Text(UserTerminology.inputMethod)
                } footer: {
                    Text(
                        selectableBindings.count < bindings.count
                            ? "开启后，候选会按整句意思排序。部分输入方式不支持语法模型，没有列在这里。"
                            : "开启后，候选会按整句意思排序。")
                }
                missingModelsSection
                Section {
                    ForEach(models.keys.sorted(), id: \.self) { path in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(modelTitle(path))
                            Text(HostStorePaths.fileSizeText(models[path]!.size))
                                .font(.caption).foregroundStyle(.secondary)
                            if singleModelPath == nil {
                                let bound = bindings.filter { $0.binds(modelPath: path) }.map(\.schemaID).sorted()
                                Text(
                                    bound.isEmpty
                                        ? "还没有用于任何输入方式"
                                        : "用于：" + bound.map(schemaName).joined(separator: "、")
                                )
                                .font(.caption).foregroundStyle(.secondary)
                            }
                            if developerOptions {
                                Text("SHA256 \(models[path]!.sha256)").font(.caption.monospaced()).textSelection(
                                    .enabled)
                                Text(
                                    recordedURL(path).map { "下载地址：" + $0.absoluteString }
                                        ?? "来源：安装包或本地文件"
                                )
                                .font(.caption).textSelection(.enabled)
                            }
                        }
                    }
                    modelImportButtons
                } header: {
                    Text("模型文件")
                }
            }
            if let package {
                Section {
                    NavigationLink("前往方案详情") { SchemePackageDetailView(packageID: package.id) }
                }
            }
            if let error = center.error, workspace != nil {
                Section { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
        }
        .navigationTitle(sourceName)
        .accessibilityIdentifier("sentence-model.management")
        .task {
            guard !initialized else { return }
            initialized = true
            isVisible = true
            await center.refresh()
            reloadWorkspace()
        }
        .onAppear {
            isVisible = true
            readBindings()
            refreshInstalledWorkspaceIfNeeded()
        }
        .onDisappear {
            isVisible = false
            statusReadID = UUID()
        }
        .onChange(of: package?.active.installation.generation) { _, _ in
            readBindings()
            refreshInstalledWorkspaceIfNeeded()
        }
        .onChange(of: scenePhase) { _, value in if value == .active { readBindings() } }
        // A committed change replaces the workspace; reload it so the model list and the rows
        // describe what is now installed instead of what was there when the page opened.
        .onChange(of: center.busy) { _, busy in
            // A failed read waits for 重试 instead of retrying on its own in a loop.
            guard isVisible, !busy, center.error == nil else { return }
            refreshInstalledWorkspaceIfNeeded()
        }
        .onChange(of: center.installedWorkspace?.generation) { _, _ in readBindings() }
        .onReceive(center.$installedWorkspace) { value in
            if let value, belongsHere(value) { lastWorkspace = value }
        }
        .alert("语法模型链接", isPresented: $enteringModelURL) {
            TextField("https://example.com/language.gram", text: $address)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("取消", role: .cancel) { address = "" }
            Button("下载") { downloadModel() }
        } message: {
            Text("请输入 .gram 文件的链接。")
        }
        .fileImporter(
            isPresented: $pendingImport, allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            guard let url = try? result.get().first else { return }
            guard url.pathExtension.lowercased() == "gram" else {
                center.report(RecipeInstallError.invalidResource("请选择 .gram 模型文件。"))
                return
            }
            // The picker URL is only readable while this callback's scope is held.
            let scoped = url.startAccessingSecurityScopedResource()
            let requirement = pendingRequirementPath
            let bindSchema = bindingAfterImport
            Task {
                let firstModel = models.isEmpty
                let added = await center.addGrammarModel(
                    fileURL: url, address: nil,
                    filename: url.lastPathComponent, requirementPath: requirement)
                if scoped { url.stopAccessingSecurityScopedResource() }
                await finishModelImport(
                    added: added, firstModel: firstModel, requirementPath: requirement, bindSchemaID: bindSchema,
                    fallbackFilename: url.lastPathComponent)
            }
        }
    }

    // MARK: - Rows

    /// With one model the choice per input method is just on or off.
    private var singleModelPath: String? { models.count == 1 ? models.keys.first : nil }

    @ViewBuilder
    private var modelImportButtons: some View {
        Button("从文件添加") {
            startImport(requirementPath: nil, bindSchemaID: nil)
        }.accessibilityIdentifier("sentence-model.import-file")
            .disabled(center.busy || applying)
        Button("从链接添加") {
            pendingRequirementPath = nil
            bindingAfterImport = nil
            address = ""
            enteringModelURL = true
        }.disabled(center.busy || applying)
    }

    @ViewBuilder
    private var missingModelsSection: some View {
        if !missingModels.isEmpty {
            Section("缺少模型文件") {
                ForEach(missingModels, id: \.path) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(modelTitle(item.path))
                        Text("用于：" + item.schemaIDs.map(schemaName).joined(separator: "、")).font(.caption)
                        Button("导入模型文件") {
                            startImport(requirementPath: item.path, bindSchemaID: nil)
                        }.disabled(center.busy || applying)
                    }
                }
            }
        }
    }

    private func inputMethodToggle(_ binding: GrammarBinding, modelPath path: String) -> some View {
        let detail = bindingDetail(binding)
        let isOn = Binding(
            get: { pendingToggles[binding.schemaID] ?? binding.binds(modelPath: path) },
            set: { on in
                pendingToggles[binding.schemaID] = on
                if on { apply(modelPath: path, to: binding) } else { applyDisabled(binding) }
            })
        return Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 4) {
                Text(schemaName(binding.schemaID))
                if detail.isProblem {
                    Text(detail.text).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .contextMenu {
            if managedSchemaIDs.contains(binding.schemaID) {
                Button("使用方案默认") { applyDefaults(binding) }
            }
        }
        .disabled(center.busy || applying)
        .accessibilityIdentifier("sentence-model.input-method.\(binding.schemaID)")
    }

    @ViewBuilder
    private func inputMethodRow(_ binding: GrammarBinding) -> some View {
        let detail = bindingDetail(binding)
        Menu {
            if !models.isEmpty {
                Section("选择模型") {
                    ForEach(models.keys.sorted(), id: \.self) { path in
                        Button {
                            apply(modelPath: path, to: binding)
                        } label: {
                            if binding.binds(modelPath: path) {
                                Label(modelTitle(path), systemImage: "checkmark")
                            } else {
                                Text(modelTitle(path))
                            }
                        }
                    }
                }
            }
            Section {
                Button("添加模型文件…") { startImport(requirementPath: nil, bindSchemaID: binding.schemaID) }
                Button("不使用语法模型") { applyDisabled(binding) }
                    .disabled(binding.language?.isEmpty != false)
                if managedSchemaIDs.contains(binding.schemaID) {
                    Button("使用方案默认") { applyDefaults(binding) }
                }
            }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(schemaName(binding.schemaID)).foregroundStyle(.primary)
                    Text(detail.text).font(.caption).foregroundStyle(detail.isProblem ? Color.red : Color.secondary)
                }
                Spacer(minLength: 8)
                if binding.support != .unsupported {
                    Text("更改").font(.footnote).foregroundStyle(.tint)
                }
            }
        }
        .disabled(center.busy || applying || workspace == nil || binding.support == .unsupported)
        .accessibilityIdentifier("sentence-model.input-method.\(binding.schemaID)")
    }

    private func bindingDetail(_ binding: GrammarBinding) -> (text: String, isProblem: Bool) {
        if binding.support == .unsupported { return ("这个输入方式不支持语法模型", false) }
        guard let language = binding.language, !language.isEmpty else { return ("未开启", false) }
        guard let path = modelPath(language) else {
            return ("模型文件路径无法识别，轻点重新选择", true)
        }
        if models[path] == nil { return ("缺少模型文件，轻点导入", true) }
        return ("已开启 · " + modelTitle(path), false)
    }

    private func recordedURL(_ path: String) -> URL? {
        workspace?.sources?.receipts.reversed().flatMap(\.externalResources).first { $0.path == path }?.url
    }

    // MARK: - Actions

    private func apply(modelPath path: String, to binding: GrammarBinding) {
        guard !binding.binds(modelPath: path) else { return }
        let saved = savedSchemaIDs(for: path)
        apply {
            await center.applyGrammarChange(schemaIDs: [binding.schemaID], modelPath: path, savedSchemaIDs: saved)
        }
    }

    private func applyDisabled(_ binding: GrammarBinding) {
        apply { await center.applyGrammarChange(schemaIDs: [binding.schemaID], modelPath: nil) }
    }

    private func applyDefaults(_ binding: GrammarBinding) {
        apply {
            await center.applyGrammarChange(schemaIDs: [binding.schemaID], modelPath: nil, restoreDefaults: true)
        }
    }

    private func applyAll(modelPath path: String, to targets: [GrammarBinding]) {
        let saved = savedSchemaIDs(for: path)
        for binding in targets { pendingToggles[binding.schemaID] = true }
        apply {
            await center.applyGrammarChange(schemaIDs: targets.map(\.schemaID), modelPath: path, savedSchemaIDs: saved)
        }
    }

    private func apply(_ change: @escaping @MainActor () async -> Bool) {
        guard !applying, !center.busy else {
            pendingToggles = [:]
            return
        }
        applying = true
        notice = nil
        Task {
            let succeeded = await change()
            applying = false
            guard succeeded else {
                pendingToggles = [:]
                return
            }
            notice =
                publishedCurrentInstallation
                ? "已保存，下次打开键盘时生效。"
                : "已保存。键盘用上这个方案后生效。"
            readBindings()
        }
    }

    private func reloadWorkspace() {
        center.error = nil
        center.openInstalledWorkspace(packageID: packageID)
        readBindings()
    }

    private func startImport(requirementPath: String?, bindSchemaID: String?) {
        guard !center.busy else { return }
        pendingRequirementPath = requirementPath
        bindingAfterImport = bindSchemaID
        notice = nil
        pendingImport = true
    }

    private func downloadModel() {
        let filename = URL(string: address)?.lastPathComponent ?? ""
        guard let url = URL(string: address), url.scheme == "https", url.host != nil else {
            center.report(RecipeInstallError.invalidResource("请输入有效的 https 链接"))
            return
        }
        guard filename.lowercased().hasSuffix(".gram") else {
            center.report(RecipeInstallError.invalidResource("请输入 .gram 文件的链接。"))
            return
        }
        let requirement = pendingRequirementPath
        let bindSchema = bindingAfterImport
        notice = nil
        Task {
            let firstModel = models.isEmpty
            let added = await center.addGrammarModel(
                fileURL: nil, address: url,
                filename: filename, requirementPath: requirement)
            await finishModelImport(
                added: added, firstModel: firstModel, requirementPath: requirement, bindSchemaID: bindSchema,
                fallbackFilename: filename)
        }
    }

    /// After the file is installed, bind it when the user asked for it from one input method.
    private func finishModelImport(
        added: Bool, firstModel: Bool, requirementPath: String?, bindSchemaID: String?,
        fallbackFilename: String
    ) async {
        guard added else { return }
        guard let bindSchemaID else {
            // A first model is added to be used: turn it on wherever nothing is on yet.
            let path = requirementPath ?? GrammarModelRecipe.installPath(for: fallbackFilename) ?? ""
            let idle = selectableBindings.filter { $0.language?.isEmpty != false }
            guard firstModel, models.count == 1, models[path] != nil, !idle.isEmpty else {
                notice = "模型已添加，可在输入方式里选择。"
                return
            }
            applyAll(modelPath: path, to: idle)
            return
        }
        let path = requirementPath ?? GrammarModelRecipe.installPath(for: fallbackFilename) ?? ""
        guard !path.isEmpty, bindings.contains(where: { $0.schemaID == bindSchemaID }) else { return }
        let saved = savedSchemaIDs(for: path)
        apply {
            await center.applyGrammarChange(schemaIDs: [bindSchemaID], modelPath: path, savedSchemaIDs: saved)
        }
    }

    private func refreshInstalledWorkspaceIfNeeded() {
        guard isVisible, initialized, !center.busy,
            let installedGeneration = package?.active.installation.generation,
            workspace?.generation != installedGeneration
        else { return }
        center.openInstalledWorkspace(packageID: packageID)
    }

    // MARK: - Reading the deployed state

    private func readBindings() {
        let readID = UUID()
        statusReadID = readID
        Task {
            guard readID == statusReadID else { return }
            do {
                guard let active = package?.active else {
                    statusText = "暂时无法读取状态。"
                    if !applying { pendingToggles = [:] }
                    return
                }
                let managedWorkspace = workspace
                let result = try await KeyboardResourceReadQueue.async {
                    () throws -> (
                        bindings: [GrammarBinding], descriptors: [KeyboardSchemaDescriptor], managed: Set<String>
                    ) in
                    let sourceFile = active.resourceURL.deletingLastPathComponent().appendingPathComponent(
                        InstalledPackageLayout.sourceFile)
                    let source = try JSONDecoder().decode(RecipeManifest.self, from: Data(contentsOf: sourceFile))
                    guard source.id == active.installation.id, source.revision == active.installation.revision,
                        source.schemaID == active.installation.schemaID
                    else {
                        throw RecipeInstallError.invalidResource("方案安装记录与源文件信息不一致，请尝试重新导入")
                    }
                    let build = active.userDataURL.appendingPathComponent("build")
                    let descriptors = try KeyboardRecipeStore.deployedSchemas(build: build)
                    let values = try descriptors.map { try GrammarBinding.read(schemaID: $0.id, buildDirectory: build) }
                    let managed =
                        managedWorkspace?.generation == active.installation.generation
                        ? Set(
                            GrammarModelRecipe.overrides(
                                in: managedWorkspace?.sources,
                                files: managedWorkspace?.snapshot.files ?? [:]
                            ).map(\.schemaID)) : []
                    return (values, descriptors, managed)
                }
                guard readID == statusReadID else { return }
                deployedSchemas = result.descriptors
                bindings = result.bindings
                if !applying { pendingToggles = [:] }
                managedSchemaIDs = result.managed
                await readPublication(active, readID: readID)
            } catch {
                guard readID == statusReadID else { return }
                if !applying { pendingToggles = [:] }
                statusText = developerOptions ? "暂时无法读取状态：\(error.localizedDescription)" : "暂时无法读取状态。"
            }
        }
    }

    /// A model-file problem the user can fix, worded for them. Every other read error may
    /// carry paths or internal detail and is shown only in developer options.
    private struct ModelStatusProblem: Error, Sendable {
        let message: String
    }

    private struct PublicationReadResult: Sendable {
        let state: ModelPublicationState
        let enabled: Bool
        let currentInstallation: Bool
        let hasLanguage: Bool
        let modelPath: String?
        let loadConfirmed: Bool
    }

    private func readPublication(_ active: ActiveRecipe, readID: UUID) async {
        let currentPackageID = packageID
        do {
            let result = try await KeyboardResourceReadQueue.async { () throws -> PublicationReadResult in
                let snapshot = try KeyboardRecipeStore.snapshot()
                let activation = snapshot?.activation
                let matches = activation?.kind == .userScheme && activation?.packageID == currentPackageID
                let state = ModelPublicationState.resolve(
                    sourceMatches: matches,
                    installedRevision: active.installation.revision,
                    installedGeneration: active.installation.generation,
                    publishedRevision: activation?.revision, publishedGeneration: activation?.generation,
                    hostGeneration: activation?.hostInstallationGeneration)
                let current = state == .currentInstallation && activation?.recipeEnabled == true
                guard matches, let snapshot, let activation else {
                    return .init(
                        state: state, enabled: activation?.recipeEnabled == true,
                        currentInstallation: current, hasLanguage: false, modelPath: nil, loadConfirmed: false)
                }
                guard let selected = activation.selectedSchemaID else {
                    return .init(
                        state: state, enabled: activation.recipeEnabled,
                        currentInstallation: current, hasLanguage: false, modelPath: nil, loadConfirmed: false)
                }
                let layout = activation.selectedLayout ?? .qwerty26
                let runtimeSchemaID =
                    KeyboardResourceSet.readEncodingAdapters(build: snapshot.build).first {
                        $0.sourceSchemaID == selected && $0.layout == layout
                    }?.schemaID ?? selected
                let binding = try GrammarBinding.read(schemaID: runtimeSchemaID, buildDirectory: snapshot.build)
                guard let language = binding.language, !language.isEmpty else {
                    return .init(
                        state: state, enabled: activation.recipeEnabled,
                        currentInstallation: current, hasLanguage: true, modelPath: nil, loadConfirmed: false)
                }
                let path = language + ".gram"
                guard GrammarModelRecipe.validModelPath(path) else {
                    throw ModelStatusProblem(message: "模型文件路径不受支持，请重新选择 .gram 文件。")
                }
                let file = snapshot.resources.appendingPathComponent(path)
                let info = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard info?.isRegularFile == true, let size = info?.fileSize, size > 0 else {
                    throw ModelStatusProblem(message: "模型文件缺失或内容为空，请重新选择模型文件。")
                }
                let receipt = try GrammarRuntimeReceiptStore.receipt(matching: activation)
                return .init(
                    state: state, enabled: activation.recipeEnabled, currentInstallation: current,
                    hasLanguage: true, modelPath: path,
                    loadConfirmed: receipt?.modelPath == path
                        && receipt?.sourceSchemaID == selected && receipt?.runtimeSchemaID == runtimeSchemaID)
            }
            guard readID == statusReadID else { return }
            publishedCurrentInstallation = result.currentInstallation
            let status = GrammarModelStatus.resolve(
                publication: result.state, enabled: result.enabled,
                hasSelection: result.hasLanguage, modelName: result.modelPath.map(modelTitle),
                loadConfirmed: result.loadConfirmed)
            statusText = status.message
        } catch {
            guard readID == statusReadID else { return }
            publishedCurrentInstallation = false
            if let problem = error as? ModelStatusProblem {
                statusText = problem.message
            } else {
                statusText = developerOptions ? "暂时无法读取状态：\(error.localizedDescription)" : "暂时无法读取状态。"
            }
        }
    }
}
