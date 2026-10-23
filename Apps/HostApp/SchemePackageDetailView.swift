import Foundation
import KeyboardCore
import PackageManager
import SwiftUI
import UniformTypeIdentifiers

/// Scheme detail: detail page for a generic imported scheme.
///
/// - Status: in use / not applied; when an old app and a new install coexist, each is shown separately.
/// - Input methods: a read-only list with the layouts each one supports and which one is in use; adding and
///   switching keyboards happens only in 我的键盘 (the link at the top), so this page offers no second way to choose.
/// - Update: a link or Rime source updates in one action from the same source; a local-file install picks an update file.
/// - Companion configuration: reads the install's workspace to reselect configuration (`installedPackageID`).
///
/// **Layering**: internal identifiers (schema ID, raw errors, implementation terms such as association / resource management / Rime source)
/// show only under developer options. The normal flow shows only "input method / keyboard layout / scheme".
struct SchemePackageDetailView: View {
    @ObservedObject private var center = SchemeImportCenter.shared
    @ObservedObject private var selectionCenter = KeyboardSelectionCenter.shared
    @Environment(\.dismiss) private var dismiss
    /// Schema IDs, resource management and Rime source text appear only when developer options are on.
    @AppStorage(HostAppKeys.developerOptionsEnabled) private var developerOptions = false
    let packageID: String

    @State private var operationError: String?
    @State private var selectedKind: KeyboardRecipeStore.ResourceKind?
    @State private var selectedPackageID: String?
    @State private var selectedRevision: String?
    @State private var confirmsDeletion = false
    /// Addable "input method x keyboard layout" pairs (same source as "My keyboards").
    @State private var addableKeyboards: Set<PublishedKeyboard> = []
    /// Raw delete/operation error: shown only under developer options (the normal flow gets user-facing text only).
    @State private var rawOperationError: String?
    /// The real stage classification of a failure (the failure page describes the status from it; never claims "unchanged" across the board).
    @State private var operationFailureState: OperationFailureState?
    /// Immutable snapshot of the shared publish selection (read on the read queue; `body` derives pure values only and never touches disk).
    @State private var selectionSnapshot = AppliedSelectionSnapshot.none
    @State private var selectionReadable = false
    /// One-action update state; progress comes from the shared download service.
    @ObservedObject private var downloadService = SchemeURLDownloadService.shared
    @State private var updating = false
    @State private var updateNotice: String?
    @State private var updateFailure: String?
    /// Cancelled with the attempt so a late outcome is not reported on this page.
    @State private var updateTask: Task<Void, Never>?

    private var item: SchemeImportCenter.InstalledPackage? {
        center.installedPackages.first { $0.id == packageID }
    }

    var body: some View {
        List {
            if let item {
                statusSection(item)
                Section {
                    NavigationLink(UserTerminology.userKeyboard) {
                        UserKeyboardManagementView(source: .package(packageID), returnsToSource: true)
                    }
                    NavigationLink("试打") {
                        PackageSourceTryView(
                            packageID: packageID, name: item.name,
                            inUse: isCurrentlyInUse)
                    }
                }
                schemaSection(item)
                Section {
                    NavigationLink {
                        GrammarModelManagementView(packageID: packageID)
                    } label: {
                        Label(UserTerminology.grammarModel, systemImage: "brain")
                    }
                }
                // The built-in scheme comes with the app: it is updated with the app and cannot be deleted.
                if !isBuiltin {
                    sourceSection(item)
                    // Companion configuration (rime-install recipe steps/parameters) targets scheme authors: shown only when developer options are on.
                    if developerOptions { configurationSection }
                    managementSection()
                }
            } else if center.damagedPackages.contains(where: { $0.id == packageID }) {
                Section("状态") {
                    Label("已损坏", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text("无法读取该方案，你可以删除后重新导入。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                managementSection()
            } else {
                Text("未找到输入方案。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let operationError {
                Section {
                    failureRow("操作未完成", detail: operationError)
                }
            }
        }
        .navigationTitle(
            item?.name ?? center.damagedPackages.first(where: { $0.id == packageID })?.name
                ?? UserTerminology.inputScheme
        )
        .navigationBarTitleDisplayMode(.inline)
        // Structured: selection reads are driven by refreshTick; the old task is cancelled and rerun. The main thread never reads disk.
        .task(id: refreshTick) {
            // On entering scheme detail (management path), first settle any previously interrupted deletion.
            await center.recoverInterruptedDeletions()
            await center.refresh()
            addableKeyboards = Set((try? await center.addableKeyboards(packageID: packageID)) ?? [])
            await reloadSelection()
        }
        .onChange(of: center.selectionRevision) { _, _ in refreshTick &+= 1 }
        .onChange(of: selectionCenter.applicationPhase) { _, _ in refreshTick &+= 1 }
        .onChange(of: center.error) { _, error in
            // Raw errors go only to developer detail; the normal flow gets user-facing text (the cause is given nearby by the delete failure path).
            if let error {
                rawOperationError = error
                // `center.error` is already user-facing text (`fail` maps it uniformly); show the specific cause as is.
                operationError = error
                operationFailureState = center.failureState ?? .unknown
            }
        }
        .confirmationDialog("删除输入方案？", isPresented: $confirmsDeletion, titleVisibility: .visible) {
            Button("删除", role: .destructive) { deletePackage() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(deletionScopeMessage)
        }
    }

    /// Deletion scope note: states what is and is not deleted, without internal terms.
    private var deletionScopeMessage: String {
        "将删除这个输入方案。已学习的词会保留，重新导入后可继续使用。"
    }

    /// Deletion after second confirmation: on success return to the list (the row is gone); on failure show a clear, retryable notice.
    private func deletePackage() {
        operationError = nil
        rawOperationError = nil
        operationFailureState = nil
        Task {
            do {
                try await center.deleteInstalledPackage(packageID: packageID)
                // Success: state is consistent; clear failure traces before leaving (the row is already removed from the list).
                operationError = nil
                rawOperationError = nil
                operationFailureState = nil
                dismiss()
            } catch {
                rawOperationError = error.localizedDescription
                operationError = deletionFailureMessage(error)
                // The real stage comes from the Host (`SchemePackageDeletion.Failure` carries its own classification; everything else is uncommitted).
                operationFailureState = center.failureState ?? .unknown
            }
        }
    }

    /// Plain-language notice for a failed deletion: uses only user-facing reasons and exposes no raw error or prefix.
    /// Raw errors are visible only under developer options (technical detail of `failureRow`).
    private func deletionFailureMessage(_ error: Error) -> String {
        // "In use" shares one rule between the deletion policy and the detail page; use its user-facing text directly.
        if let recipeError = error as? RecipeInstallError,
            case .invalidResource(let detail) = recipeError
        {
            return detail
        }
        if let packageError = error as? SchemePackageDeletion.Failure {
            return packageError.userFacingDescription
        }
        return "删除失败，请重试。"
    }

    /// The delete entry belongs to a specific install: an install in use gets no vague failure, only an inline note to switch first.
    ///
    /// The normal user surface shows only "in use" and "delete"; implementation terms such as resource management / Rime source
    /// appear only when developer options are on (gated as a whole block, not a text ternary).
    @ViewBuilder
    private func managementSection() -> some View {
        if center.damagedPackages.contains(where: { $0.id == packageID }) {
            Section(UserTerminology.inputScheme) { deletionRow }
        } else if developerOptions {
            Section {
                deletionRow
                NavigationLink("从 Rime 来源更新") { RimeSourceInstallView(updatingPackageID: packageID) }
            } header: {
                Text("资源管理")
            }
        } else {
            Section {
                deletionRow
            } header: {
                Text(UserTerminology.inputScheme)
            }
        }
    }

    @ViewBuilder
    private var deletionRow: some View {
        if !selectionReadable {
            Label(
                operationError == nil ? "正在读取…" : "暂时无法读取状态，请稍后再试。",
                systemImage: operationError == nil ? "hourglass" : "exclamationmark.triangle"
            )
            .font(.footnote).foregroundStyle(.orange)
        } else if isCurrentlyInUse {
            Label("正在使用的方案无法删除", systemImage: "lock")
                .font(.footnote).foregroundStyle(.secondary)
            // Even the only scheme is not a dead end: after stopping use the keyboard returns to the built-in offline base pinyin, and deletion can follow.
            Button("停止使用") { selectionCenter.switchToBuiltin() }
                .disabled(center.busy || selectionCenter.isBusy)
            Text("停止使用后，键盘将改用\(ProductionInputAvailability.fallbackInputMethodName)。")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Button("删除输入方案", role: .destructive) { confirmsDeletion = true }
                .disabled(center.busy)
        }
    }

    private var isBuiltin: Bool { packageID == ProductionInputAvailability.builtinPackageID }

    /// The input method the keyboard uses from this scheme (the built-in one also as the fallback); nil before the selection is read.
    private var currentSchemaID: String? {
        selectionReadable ? center.currentSchemaID(packageID: packageID, snapshot: selectionSnapshot) : nil
    }

    private var isCurrentlyInUse: Bool { currentSchemaID != nil }

    /// The fallback publishes nothing, so it is always the installed version.
    private func revisionIsCurrent(_ item: SchemeImportCenter.InstalledPackage) -> Bool {
        selectedKind == nil || selectedRevision == item.active.installation.revision
    }

    @State private var refreshTick = 0

    /// Structured selection read (latest-wins): activation completes on the read queue; the main thread only applies pure values.
    private func reloadSelection() async {
        let result = await AppliedSelectionLoader.load()
        guard let snapshot = result.snapshot else {
            selectionReadable = false
            selectionSnapshot = .none
            selectedKind = nil
            selectedPackageID = nil
            selectedRevision = nil
            operationError = result.error ?? UserTerminology.readFailureWithRetry
            return
        }
        selectionReadable = true
        if operationError == UserTerminology.readFailureWithRetry
            || operationError == AppliedSelectionLoader.missingGroupMessage
        {
            operationError = nil
        }
        selectionSnapshot = snapshot
        selectedKind =
            snapshot.recipeEnabled
            ? KeyboardRecipeStore.ResourceKind(rawValue: snapshot.resourceKind) : nil
        selectedPackageID = snapshot.packageID
        selectedRevision = snapshot.revision
    }

    // MARK: - Status

    private func statusSection(_ item: SchemeImportCenter.InstalledPackage) -> some View {
        Section("状态") {
            if !selectionReadable && operationError == nil {
                // The first read has not finished: show loading instead of flashing a read failure.
                Label("正在读取…", systemImage: "hourglass")
                    .foregroundStyle(.secondary)
            } else if !selectionReadable {
                Text("暂时无法读取状态")
                    .foregroundStyle(.orange)
            } else if isCurrentlyInUse {
                Text(revisionIsCurrent(item) ? UserTerminology.statusInUse : "\(UserTerminology.statusInUse) · 有新版本")
            } else {
                Text(UserTerminology.statusNotApplied)
            }
            if developerOptions {
                LabeledRow(label: "版本", value: String(item.active.installation.revision.prefix(12)) + "…")
            }
            if !isBuiltin {
                LabeledRow(
                    label: "安装时间",
                    value: item.active.installation.activatedAt.formatted(date: .abbreviated, time: .omitted))
            }
        }
    }

    // MARK: - Input methods (read-only; choices are made in 我的键盘)

    private func schemaSection(_ item: SchemeImportCenter.InstalledPackage) -> some View {
        Section {
            ForEach(item.skippedSchemas, id: \.id) { skipped in
                Label(skipped.notice, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            // The input method in use is listed first; the rest keep source order.
            let current = currentSchemaID
            ForEach(item.schemas.filter { $0.id == current } + item.schemas.filter { $0.id != current }) { schema in
                schemaRow(item, schema)
            }
            if !item.sourceSchemas.isEmpty, developerOptions {
                DisclosureGroup("未启用（\(item.sourceSchemas.count)）") {
                    ForEach(item.sourceSchemas, id: \.self) { id in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(id).font(.body.monospaced())
                            Text("这个输入方式未启用，无法试打或使用。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        } header: {
            Text(UserTerminology.inputMethod)
        }
    }

    private func schemaRow(
        _ item: SchemeImportCenter.InstalledPackage,
        _ schema: KeyboardSchemaDescriptor
    ) -> some View {
        // Same criterion as "My keyboards": a static association is available, or the engine can generate a 14 / 9-key adapter for this input method.
        let layouts = KeyboardLayoutKind.allCases.filter {
            center.incompatibilityReason(packageID: packageID, schemaID: schema.id, layout: $0) == nil
                || addableKeyboards.contains(PublishedKeyboard(schemaID: schema.id, layout: $0))
        }
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                // Normal flow: without a structured human name use the generic "input method"; never pass a raw schema ID off as text.
                // Developer mode: show the real name and internal ID for diagnosis.
                Text(displayName(item, schema))
                    .font(.body)
                if let line = UserTerminology.keyboardLayoutLine(layouts.map { UserTerminology.layoutName($0) }) {
                    Text(line)
                        .font(.caption).foregroundStyle(.secondary)
                }
                if developerOptions {
                    Text(schema.id)
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if schema.id == currentSchemaID {
                Text(UserTerminology.statusInUse)
                    .font(.footnote)
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    /// Human-readable name of an input method.
    /// - Normal flow: structured name only; falls back to the generic "input method" when missing, never the raw ID.
    /// - Developer mode: keeps the real name; shows the raw ID when missing (the ID is visible anyway).
    private func displayName(
        _ item: SchemeImportCenter.InstalledPackage,
        _ schema: KeyboardSchemaDescriptor
    ) -> String {
        if developerOptions {
            return schema.name.isEmpty ? schema.id : schema.name
        }
        return UserTerminology.inputMethodName(schemaID: schema.id, schemas: item.schemas)
            ?? (schema.name.isEmpty ? UserTerminology.inputMethod : schema.name)
    }

    // MARK: - Source and update

    /// Updating is not a separate feature: a scheme remembers where it came from, so one tap
    /// downloads and installs the current version from that same place. A scheme imported from a
    /// local file has no address to fetch from — importing the same scheme again replaces it.
    private func sourceSection(_ item: SchemeImportCenter.InstalledPackage) -> some View {
        Section {
            if let sourceURL = item.sourceURL {
                LabeledRow(label: "来自", value: sourceURL.host ?? "下载链接")
                if developerOptions {
                    Text(sourceURL.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
                Button {
                    startUpdate(address: sourceURL.absoluteString)
                } label: {
                    Label("更新", systemImage: "arrow.down.circle")
                }
                .disabled(center.busy || updating)
            } else if let target = SchemeImportCenter.recordedSourceTarget(packageID: packageID) {
                Button {
                    startSourceUpdate(target)
                } label: {
                    Label("更新", systemImage: "arrow.down.circle")
                }
                .disabled(center.busy || updating)
                if developerOptions {
                    Text(target)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
            } else {
                LabeledRow(label: "来自", value: "本机文件")
            }
            if updating {
                ProgressView {
                    Text(downloadService.isDownloading ? "正在下载…" : (center.message ?? "正在更新…"))
                }
                if let progress = downloadService.progress, progress.downloadedBytes > 0 {
                    Text("已下载 \(ByteCountFormatter.string(fromByteCount: progress.downloadedBytes, countStyle: .file))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("取消") { cancelUpdate() }
            } else if let updateFailure {
                Label(updateFailure, systemImage: "xmark.octagon")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            } else if let updateNotice {
                Label(updateNotice, systemImage: "checkmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.green)
            }
        } header: {
            Text("更新")
        } footer: {
            // No recorded address to fetch from: re-importing the same scheme replaces it.
            if item.sourceURL == nil, SchemeImportCenter.recordedSourceTarget(packageID: packageID) == nil {
                Text("想换新版本，重新导入同一个输入方案即可。")
            }
        }
    }

    // MARK: - One-action update

    /// Download, install, and keep the keyboard on this scheme when it is the one in use.
    private func startUpdate(address: String) {
        guard !center.busy, !updating else { return }
        updateNotice = nil
        updateFailure = nil
        if let invalid = SchemeURLDownloadService.preflight(address) {
            updateFailure = invalid.errorDescription
            return
        }
        updating = true
        updateTask = Task {
            let outcome = await center.updateInstalledPackage(packageID: packageID, address: address)
            updating = false
            guard !Task.isCancelled else { return }
            reportUpdate(outcome)
        }
    }

    private func startSourceUpdate(_ target: String) {
        guard !center.busy, !updating else { return }
        updateNotice = nil
        updateFailure = nil
        updating = true
        updateTask = Task {
            let outcome = await center.updateInstalledRimeSource(packageID: packageID, target: target)
            updating = false
            guard !Task.isCancelled else { return }
            reportUpdate(outcome)
        }
    }

    /// Cancels only this page's update attempt, never another page's download or source step.
    private func cancelUpdate() {
        center.cancelUpdateTarget()
        updateTask?.cancel()
        updateTask = nil
        updateFailure = nil
        updateNotice = nil
    }

    private func reportUpdate(_ outcome: SchemeImportCenter.SchemeUpdateOutcome) {
        switch outcome {
        case .applied:
            updateNotice = "已更新，键盘已使用新版本。"
        case .installedOnly:
            updateNotice = center.userNotice ?? "方案已更新，但键盘仍在使用旧版本。"
        case .busy:
            updateFailure = center.error
        case .unchanged:
            // Failed (show why) or already current.
            updateFailure = center.error
            updateNotice = center.error == nil ? center.userNotice : nil
        }
    }

    // MARK: - Companion configuration

    private var configurationSection: some View {
        Section {
            NavigationLink {
                SchemePackageImportView(installedPackageID: packageID)
            } label: {
                Label("方案选项", systemImage: "doc.badge.gearshape")
            }
        } footer: {
            Text("修改选项后需要更新。")
        }
    }

    private func failureRow(_ title: String, detail message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red).font(.subheadline.bold())
            Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            // Real stage: states what this operation changed and did not change (plain text, no internal terms).
            if let state = operationFailureState {
                Text(state.stateLine).font(.caption).foregroundStyle(.secondary)
                if let nextStep = state.nextStep {
                    Text(nextStep).font(.caption).foregroundStyle(.secondary)
                }
            }
            // Raw errors (which may contain internal paths/terms) expand only under developer options.
            if developerOptions, let rawOperationError, rawOperationError != message {
                Text(rawOperationError)
                    .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Plain trial-typing page for a package source (no specific schema): states whether the keyboard is using this scheme.
private struct PackageSourceTryView: View {
    let packageID: String
    let name: String
    let inUse: Bool

    var body: some View {
        SystemKeyboardTestView(
            title: "试打",
            context: SystemKeyboardTestView.sourceContext(
                name: name, inUse: inUse, howToUse: UserTerminology.tryHowToUseViaUserKeyboard))
    }
}
