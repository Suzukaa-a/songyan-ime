import LayoutKit
import SwiftUI

struct T9QuickSymbolManagementView: View {
    @StateObject private var model = T9QuickSymbolModel()
    @State private var draftSymbols = ""
    @State private var hasLoaded = false
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var saveMessage: String?
    @State private var saveFailure: String?

    var body: some View {
        Form {
            Section("符号顺序") {
                TextField(
                    "符号",
                    text: Binding(
                        get: { draftSymbols },
                        set: {
                            draftSymbols = $0
                            saveMessage = nil
                            saveFailure = nil
                        }), axis: .vertical
                )
                .lineLimit(1...3)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(isLoading || isSaving)
                .accessibilityIdentifier("t9QuickSymbols.editor")
                LabeledContent("字符", value: "\(draftSymbols.count) / 12")
                if hasLoaded, let validationError {
                    Label(validationError, systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.red)
                }
            }
            Section("键盘") {
                LabeledContent("侧键", value: previewSymbols.prefix(3).joined(separator: " "))
                LabeledContent("首键连续点按", value: previewSymbols.dropFirst(3).joined(separator: " "))
                Text("首键可在未输入状态下连续点按轮换符号，每次间隔不超过 0.8 秒；长按可输入「1」。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button {
                    save(T9QuickSymbolStore.defaultSymbols)
                } label: {
                    Label("恢复默认", systemImage: "arrow.counterclockwise")
                }
                .disabled(isLoading || isSaving || !model.isShared)
                .accessibilityIdentifier("t9QuickSymbols.restore")
                if isLoading {
                    ProgressView("正在读取…")
                } else if isSaving {
                    ProgressView("正在保存…")
                } else if let failure = saveFailure ?? model.error {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.red)
                    Button("重新读取") { Task { await reload() } }
                } else if let saveMessage {
                    Text(saveMessage).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("九键快捷符号")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    save(draftSymbols)
                } label: {
                    Image(systemName: "checkmark")
                }
                .accessibilityLabel("保存")
                .accessibilityIdentifier("t9QuickSymbols.save")
                .help("保存")
                .disabled(isLoading || isSaving || !model.isShared || validationError != nil)
            }
        }
        .task { await reload() }
    }

    private var validationError: String? {
        guard T9QuickSymbolStore.isValid(draftSymbols) else {
            return "请输入 1 至 12 个字符，不能包含空格或控制字符"
        }
        guard Set(draftSymbols).count == draftSymbols.count else { return "输入的符号不能重复" }
        return nil
    }

    private var previewSymbols: [String] {
        BuiltinLayouts.t9QuickSymbolValues(saved: draftSymbols, ascii: false)
    }

    @MainActor
    private func reload() async {
        let preserveDraft = hasLoaded && draftSymbols != model.symbols
        isLoading = true
        saveMessage = nil
        saveFailure = nil
        await model.reload().value
        guard !Task.isCancelled else { return }
        if !preserveDraft { draftSymbols = model.symbols }
        hasLoaded = true
        isLoading = false
    }

    @MainActor
    private func save(_ requestedSymbols: String) {
        guard !isLoading, !isSaving else { return }
        isSaving = true
        saveMessage = nil
        saveFailure = nil
        // Enqueue synchronously, preserving the user's explicit action order.
        let operation = model.beginReplaceSymbols(requestedSymbols)
        Task { @MainActor in
            let didWrite = await operation.value
            isSaving = false
            if let error = model.error {
                saveFailure = error
            } else if model.symbols != requestedSymbols {
                saveFailure = "未能确认保存结果，请重新读取后重试"
            } else {
                draftSymbols = model.symbols
                saveMessage = didWrite ? "已保存" : "已是当前设置"
            }
        }
    }
}
