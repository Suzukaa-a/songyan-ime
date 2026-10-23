import Darwin
import KeyboardCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Backup file document

/// FileDocument wrapper for the backup JSON: standard JSON is written only when the user exports.
struct LearningBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - UI

/// Learning backup: a one-shot entry point that hands manual backup / merge of learning data to the system keyboard extension.
///
/// Boundaries (consistent with ARCHITECTURE):
///  * The host never reads or writes engine learning data directly; it negotiates with the
///    extension only through `LearningTransferStore` (`KeyboardLearning` under the App Group
///    container), and all disk I/O runs on the Shared-layer background queue.
///  * A request must be "claimed" by the keyboard visible on screen on the extension side, so
///    while waiting a temporary "activate system keyboard" input field is focused (nothing saved or recorded).
///  * A merge cannot be undone midway: it is submitted only after the user confirms, and the
///    description says the current learning data is saved automatically first.
struct LearningBackupView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = LearningBackupModel()
    /// Only used to bring up the system keyboard: a temporary field; its content is not persisted, recorded or shown.
    @State private var activationField = ""
    @FocusState private var activationFocused: Bool

    var body: some View {
        List {
            sourceSection
            statusSection
            actionSection
            if model.showsKeyboardActivation { keyboardActivationSection }
            exportSection
            if let notice = model.notice {
                Section {
                    Text(notice).font(.footnote).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("学习备份")
        .navigationBarTitleDisplayMode(.inline)
        .task { model.refreshSource() }
        .onAppear { model.activate() }
        .onDisappear {
            clearActivationField()
            model.deactivate()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // Re-read the source on returning to the foreground (not by parsing all resources every second).
                model.refreshSource()
                model.activate()
            case .background:
                // On backgrounding, clear the input field and stop polling.
                clearActivationField()
                model.deactivate()
            default:
                break
            }
        }
        .onChange(of: model.showsKeyboardActivation) { _, needed in
            if !needed { clearActivationField() }
        }
        .fileImporter(isPresented: $model.importing, allowedContentTypes: [.json]) { result in
            model.handleImportResult(result)
        }
        .fileExporter(
            isPresented: $model.exporting, document: model.exportDocument,
            contentType: .json, defaultFilename: model.exportFilename
        ) { result in
            if case .failure(let error) = result { model.reportExportFailure(error) }
        }
        .confirmationDialog(
            "导入并合并学习备份？", isPresented: $model.confirmingRestore,
            titleVisibility: .visible
        ) {
            Button("导入并合并") { model.confirmRestore() }
            Button("取消", role: .cancel) { model.discardPendingRestore() }
        } message: {
            Text(model.restoreConfirmationMessage ?? "")
        }
    }

    // MARK: Sections

    private var sourceSection: some View {
        Section {
            switch model.sourceState {
            case .loading:
                HStack {
                    Text("正在读取当前输入方案…")
                    Spacer()
                    ProgressView()
                }
            case .ready(let source):
                Text("当前来源：\(source.sourceName)")
                Text("只包含正在使用的输入方案。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .missing:
                Text("未选择输入方案")
                Text("请先在「我的键盘」中使用一个键盘，再备份学习数据。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .failed:
                Text("暂时无法读取当前输入方案")
                Text("无法读取当前输入方案，请稍后重试。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("重试") { model.refreshSource() }
            }
        } header: {
            Text("当前来源")
        }
    }

    private var statusSection: some View {
        Section {
            Text(LearningBackupModel.statusText(for: model.transfer))
                .accessibilityIdentifier("learning.transfer.status")
            if model.hasActiveRequest {
                HStack {
                    Text("处理中")
                    Spacer()
                    ProgressView()
                }
            }
            if let failure = model.stateReadFailure {
                Text(failure).font(.footnote).foregroundStyle(.red)
            }
            // Cancel is available only for a waiting request; once processing has started, say so and never claim it was cancelled.
            if model.canCancelWaiting {
                Button("取消等待") { model.cancelWaiting() }
                    .accessibilityLabel("取消等待")
            } else if model.transfer?.status == .running {
                Text("键盘正在处理，无法取消。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("状态")
        }
    }

    private var actionSection: some View {
        Section {
            Button {
                model.requestBackup()
            } label: {
                Label("请求学习备份", systemImage: "square.and.arrow.down.on.square")
            }
            .disabled(!model.canStartTransfer)
            .accessibilityLabel("请求学习备份")

            Button {
                model.importing = true
            } label: {
                Label("导入并合并学习备份", systemImage: "square.and.arrow.up.on.square")
            }
            .disabled(!model.canStartTransfer)
            .accessibilityLabel("导入并合并学习备份")
        } header: {
            Text("学习数据")
        } footer: {
            Text("需要开启「允许完全访问」。合并后无法撤销。")
        }
    }

    private var keyboardActivationSection: some View {
        Section {
            TextField("激活系统键盘", text: $activationField)
                .focused($activationFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel("激活系统键盘")
                .onAppear {
                    // Request submitted: have the keyboard appear on screen once so the extension can read this request.
                    activationField = ""
                    Task { @MainActor in activationFocused = true }
                }
        } header: {
            Text("激活系统键盘")
        } footer: {
            Text("请调出「松烟」键盘一次。如果你正在使用其他键盘，请先切换至「松烟」。")
        }
    }

    private var exportSection: some View {
        Section {
            Button {
                model.prepareBackupExport()
            } label: {
                Label("导出学习备份", systemImage: "square.and.arrow.up")
            }
            .disabled(!model.canExportBackup)
            .accessibilityLabel("导出学习备份")

            // Offer export whenever a pre-restore backup actually exists in the container (independent of
            // the current request: the slot is kept across requests and a new backup/merge doesn't remove it).
            if model.canExportSafetyBackup || model.safetyBackup != nil {
                Button {
                    model.prepareSafetyBackupExport()
                } label: {
                    Label("导出恢复前备份", systemImage: "clock.arrow.circlepath")
                }
                .disabled(!model.canExportSafetyBackup)
                .accessibilityLabel("导出恢复前备份")
                if let detail = model.safetyBackupDetail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text("「恢复前备份」是合并前自动保存的数据。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let failure = model.safetyBackupReadFailure {
                Text(failure).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("导出")
        } footer: {
            Text("备份包含个人词库，请妥善保存。")
        }
    }

    // MARK: Temporary input field

    /// Clears without recording: called on leaving the page, backgrounding, or when the request ends.
    private func clearActivationField() {
        activationField = ""
        activationFocused = false
    }
}
