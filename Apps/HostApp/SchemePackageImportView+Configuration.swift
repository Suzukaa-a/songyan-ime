import Foundation
import KeyboardCore
import PackageManager
import SwiftUI
import UniformTypeIdentifiers

extension SchemePackageImportView {
    // MARK: - Companion configuration (steps/parameters/required resources; advanced parameters collapsed)

    var configurationSection: some View {
        Section {
            Picker("选项", selection: $selectedRecipePath) {
                Text("不使用").tag(String?.none)
                ForEach(center.recipes) { recipe in
                    Text(recipe.displayName).tag(String?.some(recipe.path))
                }
            }
            if let recipe = selectedRecipe {
                DisclosureGroup("参数") {
                    argumentFields(recipe)
                    extraArgumentFields()
                }
                stageList(below: recipe.path)
                Button {
                    // Editing (root/parameters/stages/resources) invalidates the old plan; install passes the current drafts again for comparison.
                    // Plan and install share the same collection rules (including extra parameter rows).
                    if isInstalledMode {
                        center.planInstalledRecipe(
                            recipe.path,
                            arguments: rootArguments(),
                            stages: stageArguments())
                    } else {
                        center.planRecipe(
                            recipe.path,
                            arguments: rootArguments(),
                            stages: stageArguments())
                    }
                } label: {
                    Label("检查", systemImage: "doc.badge.gearshape")
                }
                .disabled(center.busy)
            }
            if !center.plannedDiagnostics.isEmpty {
                DisclosureGroup("查看详情") {
                    ForEach(center.plannedDiagnostics, id: \.self) { line in
                        Text(line).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    }
                }
            }
        } header: {
            Text(isInstalledMode ? "方案选项" : "方案选项（可选）")
        } footer: {
            Text(
                isInstalledMode
                    ? "修改选项后需要更新。"
                    : "若无需调整，可直接轻点「安装」。")
        }
    }

    /// Follow-up stage list shared by installed mode and new import: one picker plus its own parameters per stage;
    /// order is the execution order of `plan.appending` (official resources, config, optional follow-ups).
    /// The same recipe may appear several times (stages with different parameters); each slot is identified by a stable UUID,
    /// and drafts travel with the slot so delete/reorder never misaligns them. The picker keeps the slot's current value as an option.
    private func stageList(below rootPath: String) -> some View {
        Group {
            ForEach(stageSlots) { slot in
                VStack(alignment: .leading, spacing: 4) {
                    Picker("第 \(stageIndex(slot) + 2) 步", selection: stageBinding(for: slot)) {
                        Text("移除此步").tag(String?.none)
                        ForEach(center.recipes.filter { $0.path != rootPath }) { recipe in
                            Text(recipe.displayName).tag(String?.some(recipe.path))
                        }
                    }
                    if let recipe = center.recipes.first(where: { $0.path == slot.path }) {
                        DisclosureGroup("参数（第 \(stageIndex(slot) + 2) 步）") {
                            argumentFields(recipe, into: slot.id)
                            extraArgumentFields(into: slot.id)
                        }
                    }
                }
            }
            Menu {
                ForEach(availableStageCandidates(below: rootPath)) { recipe in
                    Button(recipe.displayName) {
                        let id = UUID()
                        stageSlots.append(StageSlot(id: id, path: recipe.path))
                        if isInstalledMode {
                            restoreArguments(path: recipe.path, into: id)
                        }
                    }
                }
            } label: {
                Label("添加步骤", systemImage: "plus.circle")
            }
            .disabled(center.busy || availableStageCandidates(below: rootPath).isEmpty)
        }
    }

    /// Slot position in the current list (display index only; identity is always the UUID).
    private func stageIndex(_ slot: StageSlot) -> Int {
        stageSlots.firstIndex(where: { $0.id == slot.id }) ?? 0
    }

    /// Selection binding for one slot: nil removes the step together with its draft.
    private func stageBinding(for slot: StageSlot) -> Binding<String?> {
        Binding(
            get: { stageSlots.first(where: { $0.id == slot.id })?.path },
            set: { newValue in
                guard let index = stageSlots.firstIndex(where: { $0.id == slot.id }) else { return }
                if let newValue {
                    stageSlots[index].path = newValue
                    if isInstalledMode { restoreArguments(path: newValue, into: slot.id) }
                } else {
                    stageSlots.remove(at: index)
                    stageDrafts[slot.id] = nil
                    extraStageArguments[slot.id] = nil
                }
            })
    }

    private func availableStageCandidates(below rootPath: String) -> [SchemeImportCenter.DiscoveredRecipe] {
        center.recipes.filter { $0.path != rootPath }
    }

    /// Parameters of each selected follow-up stage, in list order. Drafts are looked up by stage UUID, independent of slot order.
    func stageArguments() -> [SchemeImportCenter.RecipeStage] {
        stageSlots.compactMap { slot in
            guard let recipe = center.recipes.first(where: { $0.path == slot.path }) else { return nil }
            var arguments = collectArguments(recipe, drafts: stageDrafts[slot.id] ?? [:])
            arguments.append(contentsOf: collectExtraArguments(extraStageArguments[slot.id] ?? [:]))
            return SchemeImportCenter.RecipeStage(path: slot.path, arguments: arguments)
        }
    }

    /// Current root recipe draft parameters (for install fingerprint comparison; same collection rules as when the plan was built).
    func rootArguments() -> [RecipeArgument] {
        guard let recipe = selectedRecipe else { return [] }
        return collectArguments(recipe, drafts: argumentDrafts) + collectExtraArguments(extraRootArguments)
    }

    // MARK: - Extra parameter rows (ordered name=value)

    /// Ordered extra parameters: undeclared names and duplicate names enter the plan in row order (the core supports ordered duplicates).
    /// One row reads "name = value"; a switch controls whether it is passed, and a delete button removes the row.
    @ViewBuilder
    private func extraArgumentFields(into key: UUID? = nil) -> some View {
        let rows = key == nil ? extraRootArguments : (extraStageArguments[key!] ?? [:])
        ForEach(rows.keys.sorted(), id: \.self) { index in
            extraArgumentRow(index: index, into: key)
        }
        Button {
            let index = (rows.keys.max() ?? -1) + 1
            storeExtra(ExtraArgumentDraft(), index: index, into: key)
        } label: {
            Label("添加参数行", systemImage: "plus")
                .font(.caption)
        }
        .buttonStyle(.borderless)
    }

    @ViewBuilder
    private func extraArgumentRow(index: Int, into key: UUID?) -> some View {
        HStack(spacing: 8) {
            TextField("参数名", text: extraNameBinding(index: index, into: key))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .frame(maxWidth: 120)
            TextField("值（空＝显式空值）", text: extraValueBinding(index: index, into: key))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Toggle("传入", isOn: extraEnabledBinding(index: index, into: key))
                .toggleStyle(.button)
                .font(.caption)
            Button(role: .destructive) {
                removeExtra(index: index, into: key)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
        }
    }

    private func extraDraft(index: Int, into key: UUID?) -> ExtraArgumentDraft {
        if let key { return extraStageArguments[key]?[index] ?? ExtraArgumentDraft() }
        return extraRootArguments[index] ?? ExtraArgumentDraft()
    }

    private func extraNameBinding(index: Int, into key: UUID?) -> Binding<String> {
        Binding(
            get: { extraDraft(index: index, into: key).name },
            set: { value in
                var current = extraDraft(index: index, into: key)
                current.name = value
                storeExtra(current, index: index, into: key)
            })
    }

    private func extraValueBinding(index: Int, into key: UUID?) -> Binding<String> {
        Binding(
            get: { extraDraft(index: index, into: key).value },
            set: { value in
                var current = extraDraft(index: index, into: key)
                current.value = value
                storeExtra(current, index: index, into: key)
            })
    }

    private func extraEnabledBinding(index: Int, into key: UUID?) -> Binding<Bool> {
        Binding(
            get: { extraDraft(index: index, into: key).enabled },
            set: { enabled in
                var current = extraDraft(index: index, into: key)
                current.enabled = enabled
                storeExtra(current, index: index, into: key)
            })
    }

    private func storeExtra(_ draft: ExtraArgumentDraft, index: Int, into key: UUID?) {
        if let key { extraStageArguments[key, default: [:]][index] = draft } else { extraRootArguments[index] = draft }
    }

    private func removeExtra(index: Int, into key: UUID?) {
        if let key { extraStageArguments[key]?[index] = nil } else { extraRootArguments[index] = nil }
    }

    /// Extra row collection: passed only when enabled and the name is valid (name and value are both subject to the core's name=value constraints).
    private func collectExtraArguments(_ drafts: [Int: ExtraArgumentDraft]) -> [RecipeArgument] {
        drafts.keys.sorted().compactMap { index in
            guard let draft = drafts[index], draft.enabled else { return nil }
            let name = draft.name.trimmingCharacters(in: .whitespaces)
            guard name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else { return nil }
            return RecipeArgument(name, draft.value)
        }
    }

    // MARK: - Explicitly provided external resources (models, etc.)

    /// Follows the recipe-declared requirement.path: a local file or explicit download first goes to private staging
    /// (file reference for models, bounded bytes for plain resources) and is matched by declared path when the plan is built;
    /// providing is not loading; loading is proven by real verification at install time.
    var externalResourceSection: some View {
        Section {
            ForEach(Array(declaredResources.enumerated()), id: \.element.path) { index, resource in
                externalResourceRow(resource, ordinal: index + 1)
            }
        } header: {
            Text("附加文件")
        } footer: {
            Text("输入方案还需要以下文件，可从文件导入或下载。")
        }
    }

    @ViewBuilder
    private func externalResourceRow(_ resource: RecipeExternalResource, ordinal: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(developerOptions ? resource.path : "附加文件 \(ordinal)")
                    .font(developerOptions ? .subheadline.monospaced() : .subheadline)
                Spacer()
                if isResourceProvided(resource.path) {
                    Label("已提供", systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel("附加文件 \(ordinal) 已提供")
                }
            }
            if let provided = center.providedDownloadFiles[resource.path] {
                Text(
                    developerOptions
                        ? "\(HostStorePaths.fileSizeText(provided.size)) · SHA256 \(String(provided.sha256.prefix(12)))…"
                        : HostStorePaths.fileSizeText(provided.size)
                )
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            } else if let ordinary = center.providedOrdinaryResources[resource.path] {
                Text(
                    developerOptions
                        ? "\(HostStorePaths.fileSizeText(ordinary.size)) · SHA256 \(String(ordinary.sha256.prefix(12)))…"
                        : HostStorePaths.fileSizeText(ordinary.size)
                )
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            } else {
                Text(
                    developerOptions
                        ? resource.url.absoluteString
                        : "下载地址：\(resource.url.host ?? "未知")"
                )
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                .lineLimit(2)
            }
            HStack {
                Button {
                    importerPurpose = .externalResource(requirementPath: resource.path)
                    showingImporter = true
                } label: {
                    Label("从文件导入…", systemImage: "doc.badge.arrow.up")
                }
                .disabled(center.busy)
                Button {
                    center.downloadExternalResource(resource)
                } label: {
                    Label("下载", systemImage: "arrow.down.circle")
                }
                .disabled(center.busy)
                if isResourceProvided(resource.path) {
                    Button("移除", role: .destructive) {
                        center.removeProvidedExternalResource(requirementPath: resource.path)
                    }
                    .disabled(center.busy)
                }
            }
            .font(.subheadline)
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }

    /// A model (file reference) or a plain resource (bytes) counts as provided.
    private func isResourceProvided(_ path: String) -> Bool {
        center.providedDownloadFiles[path] != nil || center.providedOrdinaryResources[path] != nil
    }

    // MARK: - Parameter input

    /// Omitted / explicit empty / explicit value are separate states. recipe.args is only an input hint and does not expand
    /// defaults: a disabled parameter is not passed to the plan at all, and only the `:-` in `${name:-literal}` supplies a default;
    /// enabled with an empty field is an explicit empty `name=` (enters Rx and patch expansion, unlike omission).
    /// Fields follow recipe declaration order; duplicate declarations of the same name stay independent and ordered.
    @ViewBuilder
    private func argumentFields(
        _ recipe: SchemeImportCenter.DiscoveredRecipe,
        label: String = "参数", into keyPath: UUID? = nil
    ) -> some View {
        // Read the draft in the parent view evaluation, rather than only inside
        // ForEach's cached row closure. Restored values must update row structure
        // together with the Toggle's live binding on the first presentation.
        let values = keyPath.map { stageDrafts[$0] ?? [:] } ?? argumentDrafts
        if !recipe.declaredArguments.isEmpty {
            ForEach(Array(recipe.declaredArguments.enumerated()), id: \.offset) { index, declared in
                VStack(alignment: .leading, spacing: 2) {
                    Text(declared).font(.caption).foregroundStyle(.secondary)
                    Toggle(isOn: enableBinding(index: index, keyPath: keyPath)) {
                        Text(argumentName(of: declared) ?? declared)
                            .font(.caption.monospaced())
                    }
                    .font(.caption)
                    if values[index]?.enabled == true {
                        TextField("值（留空＝空值）", text: valueBinding(index: index, keyPath: keyPath))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                }
            }
            .id(recipe.path)
        }
    }

    /// Parameter name of a declaration row (the name part of `name=...`); nil when malformed, so the collection rules reject it.
    private func argumentName(of declared: String) -> String? {
        let parts = declared.split(separator: "=", maxSplits: 1)
        guard let name = parts.first.map(String.init),
            name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil
        else { return nil }
        return name
    }

    /// Restore the ordered declared prefix into its normal controls. Any suffix that
    /// cannot be represented there (unknown/reordered/duplicate names) stays in ordered
    /// extra rows, preserving the exact invocation rather than collapsing to a dictionary.
    func restoreArguments(path: String?, into key: UUID?) {
        var drafts: [Int: RecipeArgumentDraft] = [:]
        var extras: [Int: ExtraArgumentDraft] = [:]
        let recipe = center.recipes.first { $0.path == path }
        let names = recipe?.declaredArguments.map { argumentName(of: $0) } ?? []
        let args = center.installedWorkspace?.sources?.receipts.last { $0.recipePath == path }?.arguments ?? []
        var nextIndex = 0
        var suffix = false
        for argument in args {
            if !suffix, let index = names.indices.first(where: { $0 >= nextIndex && names[$0] == argument.name }) {
                drafts[index] = RecipeArgumentDraft(enabled: true, value: argument.value)
                nextIndex = index + 1
            } else {
                suffix = true
                extras[extras.count] = ExtraArgumentDraft(enabled: true, name: argument.name, value: argument.value)
            }
        }
        if let key {
            stageDrafts[key] = drafts
            extraStageArguments[key] = extras
        } else {
            argumentDrafts = drafts
            extraRootArguments = extras
        }
    }

    func draft(index: Int, keyPath: UUID?) -> RecipeArgumentDraft {
        guard let keyPath else { return argumentDrafts[index] ?? RecipeArgumentDraft() }
        return stageDrafts[keyPath]?[index] ?? RecipeArgumentDraft()
    }

    /// Root recipe drafts are stored in `argumentDrafts` by declaration index; follow-up stages in
    /// `stageDrafts` by stage UUID. Index (not name) keeps ordered duplicate declarations; UUID keeps
    /// drafts aligned after slot delete/reorder.
    private func store(_ draft: RecipeArgumentDraft, index: Int, keyPath: UUID?) {
        guard let keyPath else {
            argumentDrafts[index] = draft
            return
        }
        stageDrafts[keyPath, default: [:]][index] = draft
    }

    private func enableBinding(index: Int, keyPath: UUID?) -> Binding<Bool> {
        Binding(
            get: { draft(index: index, keyPath: keyPath).enabled },
            set: { enabled in
                var current = draft(index: index, keyPath: keyPath)
                current.enabled = enabled
                store(current, index: index, keyPath: keyPath)
            })
    }

    private func valueBinding(index: Int, keyPath: UUID?) -> Binding<String> {
        Binding(
            get: { draft(index: index, keyPath: keyPath).value },
            set: { value in
                var current = draft(index: index, keyPath: keyPath)
                current.value = value
                store(current, index: index, keyPath: keyPath)
            })
    }

    /// Three-state collection (same source as plan/install fingerprints): off = omitted; on = explicit parameter (including empty value).
    /// Rx keeps declaration order; duplicate declarations of the same name each become an entry in order.
    private func collectArguments(_ recipe: SchemeImportCenter.DiscoveredRecipe, drafts: [Int: RecipeArgumentDraft])
        -> [RecipeArgument]
    {
        recipe.declaredArguments.enumerated().compactMap { index, declared in
            guard let draft = drafts[index], draft.enabled,
                let name = argumentName(of: declared)
            else { return nil }
            return RecipeArgument(name, draft.value)
        }
    }
}
