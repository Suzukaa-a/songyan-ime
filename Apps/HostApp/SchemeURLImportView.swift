import SwiftUI

/// Import from URL: takes a direct link to a scheme ZIP, downloads it, then hands it to
/// `SchemeImportCenter.accept`, which runs the same recognition/install flow as file import.
///
/// - Accepts only direct HTTPS ZIP links: empty/HTTP addresses are blocked before submit; ZIP is not judged by URL suffix.
/// - While downloading, shows downloaded bytes (a percentage only with a trusted total); cancellable; cancel is not a failure.
/// - Failures/non-ZIP show the actual reason and a retry action inline; never reads the clipboard or installs implicitly.
/// - On success the page closes and returns to the recognition result on the import page; the source URL travels with the import into the detail page.
struct SchemeURLImportView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var service = SchemeURLDownloadService.shared
    @ObservedObject private var center = SchemeImportCenter.shared
    @State private var address = ""
    @State private var addressError: String?
    @FocusState private var addressFocused: Bool

    init(initialURL: URL? = nil) {
        _address = State(initialValue: initialURL?.absoluteString ?? "")
    }

    var body: some View {
        Form {
            Section {
                TextField("ZIP 链接或 GitHub 仓库地址", text: $address)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($addressFocused)
                    .disabled(service.isDownloading)
                    .onSubmit { submit() }
                if let addressError {
                    Label(addressError, systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                if service.isDownloading {
                    downloadProgress
                } else if let failure = service.lastError {
                    Label(failure, systemImage: "xmark.octagon")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                    Button("重试") { submit() }
                }
                if !service.isDownloading && service.lastError == nil {
                    Button("下载") { submit() }
                        .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || center.busy)
                }
            } header: {
                Text("链接")
            } footer: {
                Text("支持 ZIP 下载链接或 GitHub 仓库地址。")
            }
        }
        .navigationTitle("从链接导入")
        .navigationBarTitleDisplayMode(.inline)
        // Navigating back cancels the download (onDisappear), so there is no separate duplicate cancel button.
        .onAppear { addressFocused = true }
        .onDisappear { service.cancel() }
    }

    @ViewBuilder
    private var downloadProgress: some View {
        if let progress = service.progress, let total = progress.totalBytes, total > 0 {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: Double(min(progress.downloadedBytes, total)), total: Double(total))
                Text("\(byteText(progress.downloadedBytes)) / \(byteText(total))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if service.isDownloading {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView {
                    Text("正在下载…")
                }
                if let progress = service.progress, progress.downloadedBytes > 0 {
                    Text("已下载 \(byteText(progress.downloadedBytes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func submit() {
        guard !service.isDownloading else { return }
        addressError = nil
        if let invalid = SchemeURLDownloadService.preflight(address) {
            addressError = invalid.errorDescription
            return
        }
        Task {
            // A failure message is shown inline from service.lastError; cancellation shows nothing.
            guard let result = try? await service.download(address: address) else { return }
            // The source URL goes into the import record for the detail page and re-download.
            center.accept(
                [result.localFileURL], sourceURL: result.requestedURL,
                onFinished: { withExtendedLifetime(result) {} })
            dismiss()
        }
    }
}
