import Foundation
import PackageManager

/// Import a scheme from URL: generic direct-link HTTPS ZIP download.
///
/// - Only downloads to a temporary file: HTTPS, no embedded credentials, redirects may not downgrade, actual bytes
///   are limited by the file-import ZIP budget (also accumulated when the length is unknown), cancellable, temp files
///   cleaned with their directory. It does not install, read active, or download recipe-declared resources;
///   recognition/install goes through `SchemeImportCenter.accept`, the same flow as file picking.
/// - Progress is a byte count (percentage only with a trusted total); when the address is edited and resubmitted, the old
///   result is discarded by generation comparison and never overwrites the new draft.
///
/// Relation to PackageManager: reuses its public budget constant (`RecipeResourceBudget.archiveFile`) and error types;
/// the transfer itself lives here because the existing `RecipeFileResource.download` has no progress callback and its limit
/// is a single-model budget, so it cannot provide the downloaded-bytes/cancel progress this page needs.
@MainActor
final class SchemeURLDownloadService: ObservableObject {
    static let shared = SchemeURLDownloadService()

    /// Progress (byte counts; when the total is unknown or untrusted, total is nil and only downloaded bytes are reported).
    struct Progress: Equatable {
        var downloadedBytes: Int64
        var totalBytes: Int64?
    }

    enum DownloadError: LocalizedError {
        case emptyAddress
        case notHTTPS
        case notZIP

        var errorDescription: String? {
            switch self {
            case .emptyAddress: return "请输入 ZIP 文件链接。"
            case .notHTTPS: return "请输入以 https 开头的链接。"
            case .notZIP: return "链接未指向 ZIP 文件。请填写 ZIP 下载链接或 GitHub 仓库地址（例如 https://github.com/用户/仓库）。"
            }
        }
    }

    @Published private(set) var isDownloading = false
    @Published private(set) var progress: Progress?
    @Published private(set) var lastError: String?

    /// Successful download result: the local ZIP file plus source info. The view passes it on to SchemeImportCenter.
    struct Result: Sendable {
        let localFileURL: URL
        /// The raw address the user entered.
        let requestedURL: URL
        /// The final address of the response (after redirects; equals the original if none).
        let finalURL: URL
        let byteCount: Int64
        let lease: DownloadLease
    }

    final class DownloadLease: Sendable {
        private let directory: URL
        init(directory: URL) { self.directory = directory }
        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    private var requestGeneration = 0

    /// Temp directory: one subdirectory per download; deleting it cleans up everything from that download.
    private static var stagingRoot: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("scheme-url-downloads", isDirectory: true)
    }

    /// Pre-submit address gate: empty address, non-HTTPS, or embedded credentials are rejected before any request.
    /// ZIP is not judged by URL suffix (valid ZIPs with query parameters or no suffix are allowed).
    nonisolated static func preflight(_ address: String) -> DownloadError? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .emptyAddress }
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https",
            url.host?.isEmpty == false, url.user == nil, url.password == nil
        else {
            return .notHTTPS
        }
        return nil
    }

    func normalizedURL(from address: String) -> URL? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https",
            url.host?.isEmpty == false, url.user == nil, url.password == nil
        else { return nil }
        return Self.githubArchiveURL(for: url) ?? url
    }

    /// Users often paste a GitHub repository page URL (`github.com/<owner>/<repo>[/tree/<ref>]`);
    /// rewrite it to that repository's ZIP download URL; any other address returns nil.
    nonisolated static func githubArchiveURL(for url: URL) -> URL? {
        guard let host = url.host?.lowercased(), host == "github.com" || host == "www.github.com" else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count == 2 || (parts.count >= 4 && parts[2] == "tree") else { return nil }
        let repo = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
        let ref = parts.count >= 4 ? parts[3...].joined(separator: "/") : "HEAD"
        var components = URLComponents()
        components.scheme = "https"
        components.host = "codeload.github.com"
        components.path = "/\(parts[0])/\(repo)/zip/\(ref)"
        return components.url
    }

    /// Failure of a download, carrying the same text `lastError` shows.
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private var downloadTask: Task<Result, Error>?

    /// Download a direct ZIP link. Resubmitting supersedes the previous request, which then throws
    /// `CancellationError` (the address changed, so the old result must not overwrite the new draft);
    /// user cancel is not a failure.
    func download(address: String) async throws -> Result {
        guard Self.preflight(address) == nil, let url = normalizedURL(from: address) else {
            let message = (Self.preflight(address) ?? .notHTTPS).errorDescription ?? "地址无效。"
            lastError = message
            throw Failure(message: message)
        }
        requestGeneration += 1
        let generation = requestGeneration
        lastError = nil
        downloadTask?.cancel()
        isDownloading = true
        progress = Progress(downloadedBytes: 0, totalBytes: nil)
        let staging = Self.stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let task = Task { [weak self] in
            try await Self.perform(url: url, staging: staging) { downloaded, total in
                Task { @MainActor in
                    guard let self, self.requestGeneration == generation else { return }
                    self.progress = Progress(downloadedBytes: downloaded, totalBytes: total)
                }
            }
        }
        downloadTask = task
        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard requestGeneration == generation else {
                try? FileManager.default.removeItem(at: staging)
                throw CancellationError()
            }
            isDownloading = false
            progress = nil
            return result
        } catch {
            try? FileManager.default.removeItem(at: staging)
            guard requestGeneration == generation else { throw CancellationError() }
            isDownloading = false
            progress = nil
            if error is CancellationError { throw error }
            let message = Self.describe(error)
            lastError = message
            throw Failure(message: message)
        }
    }

    /// Cancel the current download; cancel is not a failure.
    func cancel() {
        requestGeneration += 1
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        progress = nil
    }

    /// Map network and protocol errors to natural Chinese messages (shows the actual reason plus retry).
    nonisolated private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorTimedOut: return "连接超时，请检查网络后重试。"
            case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
                NSURLErrorDNSLookupFailed:
                return "无法连接服务器，请检查地址和网络。"
            case NSURLErrorNetworkConnectionLost: return "网络连接中断，请重试。"
            case NSURLErrorNotConnectedToInternet: return "无网络连接，请检查你的网络设置。"
            case NSURLErrorBadServerResponse, NSURLErrorHTTPTooManyRedirects:
                return "服务器响应异常，请确认链接指向可下载的 ZIP 文件。"
            default: break
            }
        }
        if let download = error as? TransportError {
            switch download {
            case .redirectDowngrade: return "链接被重定向至非 HTTPS 地址，已停止下载。"
            case .http(let code): return "服务器返回错误（HTTP \(code)），请确认链接是否有效后重试。"
            case .tooLarge: return "文件超出可导入的大小限制（1.5 GB）。"
            case .notZIP: return DownloadError.notZIP.errorDescription ?? "链接未指向 ZIP 文件。"
            }
        }
        return "下载未完成：\(error.localizedDescription)"
    }

    // MARK: - Transfer (URLSession downloadTask writes to disk + progress/budget/redirect validation)

    private enum TransportError: LocalizedError {
        case redirectDowngrade
        case http(Int)
        case tooLarge
        case notZIP
    }

    nonisolated private static func perform(
        url: URL, staging: URL,
        progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws -> Result {
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let landing = staging.appendingPathComponent("scheme-\(UUID().uuidString).zip")
        let delegate = TransportDelegate(
            maximumBytes: RecipeResourceBudget.archiveFile, landing: landing, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        // Explicit downloadTask + continuation: async `download(from:)` does not guarantee session-level
        // didWriteData callbacks, and the 1.5 GB cap and progress must be enforced reliably by the delegate
        // (same pattern as PackageManager's `ResourceDownloadDelegate`).
        let response = try await withTaskCancellationHandler {
            try await delegate.transfer { session.downloadTask(with: url) }
        } onCancel: {
            delegate.cancel()
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw TransportError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard let final = response.url, Self.isAcceptableTransportURL(final) else {
            throw TransportError.redirectDowngrade
        }
        // ZIP magic-number check (not URL suffix): HTML repo pages etc. get direct-link guidance.
        guard try Self.startsWithZipMagic(landing) else { throw TransportError.notZIP }
        let size = (try? landing.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= RecipeResourceBudget.archiveFile else { throw TransportError.tooLarge }
        return Result(
            localFileURL: landing, requestedURL: url, finalURL: final,
            byteCount: Int64(size), lease: DownloadLease(directory: staging))
    }

    /// Same rules as PackageManager's `HTTPSResourceReader.validate`: HTTPS only, non-empty host, no embedded credentials.
    nonisolated static func isAcceptableTransportURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.isEmpty == false && url.user == nil && url.password == nil
    }

    /// Read the file header to check the ZIP magic (PK); file name and Content-Type are not trusted.
    nonisolated private static func startsWithZipMagic(_ file: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: 2) ?? Data()
        return head.count == 2 && head[0] == 0x50 && head[1] == 0x4B
    }

    /// Transfer delegate: byte-count progress, cumulative and expected-length limits, no redirect downgrade.
    /// Same rules as PackageManager's `ResourceDownloadDelegate`/`HTTPSResourceReader.validate`.
    // Mutable state is guarded by `lock`; URLSession calls the delegate on its own queue.
    private final class TransportDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let maximumBytes: Int
        private let landing: URL
        private let progress: @Sendable (Int64, Int64?) -> Void
        private let lock = NSLock()
        private var problem: Error?
        private var cancelled = false
        private var landed = false
        private var task: URLSessionDownloadTask?
        private var continuation: CheckedContinuation<URLResponse, Error>?

        init(maximumBytes: Int, landing: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) {
            self.maximumBytes = maximumBytes
            self.landing = landing
            self.progress = progress
        }

        private func fail(_ error: Error) {
            lock.lock()
            defer { lock.unlock() }
            if problem == nil { problem = error }
        }

        func transfer(makeTask: () -> URLSessionDownloadTask) async throws -> URLResponse {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                let task = makeTask()
                self.task = task
                lock.unlock()
                task.resume()
            }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let task = task
            lock.unlock()
            task?.cancel()
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard let next = request.url, SchemeURLDownloadService.isAcceptableTransportURL(next) else {
                fail(TransportError.redirectDowngrade)
                // Merely rejecting the redirect leaves the original request hanging until timeout; cancel immediately so the rejection completes at once.
                task.cancel()
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }

        func urlSession(
            _ session: URLSession, downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            // Unknown length (totalBytesExpectedToWrite < 0) is also limited by the cumulative count.
            if totalBytesWritten > Int64(maximumBytes) || totalBytesExpectedToWrite > Int64(maximumBytes) {
                fail(TransportError.tooLarge)
                downloadTask.cancel()
                return
            }
            let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
            progress(totalBytesWritten, expected)
        }

        func urlSession(
            _ session: URLSession, downloadTask: URLSessionDownloadTask,
            didFinishDownloadingTo location: URL
        ) {
            // The system deletes `location` once the callback returns: move it synchronously into the caller's staging (cleaned by the lease).
            do {
                try FileManager.default.moveItem(at: location, to: landing)
                lock.lock()
                landed = true
                lock.unlock()
            } catch { fail(error) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock()
            let continuation = continuation
            self.continuation = nil
            self.task = nil
            let cancelled = cancelled, problem = problem, landed = landed
            lock.unlock()
            if cancelled {
                continuation?.resume(throwing: CancellationError())
            } else if let problem {
                continuation?.resume(throwing: problem)
            } else if let error {
                continuation?.resume(throwing: error)
            } else if landed, let response = task.response {
                continuation?.resume(returning: response)
            } else {
                continuation?.resume(throwing: URLError(.badServerResponse))
            }
        }
    }
}

/// Recommended input schemes (pure data catalog; the import page has no source-specific logic). Downloaded from the public upstream
/// repository only after the user taps; not bundled or redistributed; the revision is pinned to a reviewed version and goes through the same recognition/install flow as any link.
struct RecommendedSchemeSource: Identifiable, Sendable {
    let name: String
    let detail: String
    let url: URL
    var id: String { url.absoluteString }

    static let catalog: [RecommendedSchemeSource] = [
        RecommendedSchemeSource(
            name: "雾凇拼音",
            detail: "全拼与多种双拼，词库丰富 · GPL-3.0",
            url: URL(string: "https://codeload.github.com/iDvel/rime-ice/zip/fbb516b2786e4d5444383706d13c31c2e4d10c08")!
        ),
        RecommendedSchemeSource(
            name: "万象拼音",
            detail: "全拼与多种双拼，另需下载约 400 MB 的模型 · CC-BY-4.0",
            // Release asset, not the repository zip: the repository only has OpenCC text sources, while the
            // compiled .ocd2 dictionaries that its opencc/*.json files reference ship only in the release.
            url: URL(
                string: "https://github.com/amzxyz/rime-wanxiang/releases/download/v18.1.3/rime-wanxiang-base.zip")!),
    ]
}
