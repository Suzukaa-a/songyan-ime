import CryptoKit
import Foundation
import os

/// Disk budgets, not claims about the engine's resident memory. Models are never loaded as Data.
public enum RecipeResourceBudget {
    public static let sourceTotal = 256 * 1024 * 1024
    public static let sourceFile = 128 * 1024 * 1024
    public static let modelFile = 512 * 1024 * 1024
    public static let modelTotal = 1024 * 1024 * 1024
    public static let archiveFile = 1536 * 1024 * 1024
    public static let bufferBytes = 1024 * 1024
    /// Large binary resources passed by file reference, never loaded as Data: grammar models
    /// (`*.gram`) and root-level prediction databases (`*.db`, checked by `Prediction`).
    public static func isModel(_ path: String) -> Bool { path.hasSuffix(".gram") || Prediction.isDatabasePath(path) }
    public static func maximumFileBytes(_ path: String) -> Int { isModel(path) ? modelFile : sourceFile }
    public static func validate(_ sizes: [String: Int]) throws {
        try validate(sizes, logicalPath: { $0 })
    }

    /// Only source catalogs add this namespace; ordinary installed nested *.db
    /// files must not be reclassified as root prediction databases.
    static func sourceArchiveLogicalPath(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 4, parts[0] == "source-repositories" else { return path }
        return parts.dropFirst(3).joined(separator: "/")
    }

    static func validate(_ sizes: [String: Int], logicalPath: (String) -> String) throws {
        var sources = 0, models = 0
        guard sizes.count <= 2000 else { throw RecipeInstallError.invalidResource("文件数量超过 2000 个") }
        for (path, size) in sizes {
            guard SchemeSourceCheck.safe(path) else { throw RecipeInstallError.invalidResource(path) }
            let logical = logicalPath(path)
            guard size >= 0, size <= maximumFileBytes(logical) else {
                throw RecipeInstallError.invalidResource("单个文件超过大小限制：\(path)")
            }
            if isModel(logical) { models += size } else { sources += size }
        }
        guard sources <= sourceTotal, models <= modelTotal else {
            throw RecipeInstallError.invalidResource("方案文件或模型文件总大小超过限制")
        }
    }
}

/// Reference to immutable, process-readable bytes. Capture a user-selected file while its security
/// lease is held, or reference an existing immutable installation. The hash is taken once, when the bytes are first read.
public struct RecipeFileResource: Sendable {
    public let url: URL
    public let size: Int
    public let sha256: String
    private let lease: TemporaryResourceLease?
    /// Wraps a file whose identity is already known (recorded at capture); nothing is hashed.
    init(url: URL, size: Int, sha256: String) {
        self.url = url
        self.size = size
        self.sha256 = sha256
        lease = nil
    }
    private init(url: URL, size: Int, sha256: String, lease: TemporaryResourceLease) {
        self.url = url
        self.size = size
        self.sha256 = sha256
        self.lease = lease
    }

    public static func reference(
        at url: URL, maximumBytes: Int = RecipeResourceBudget.modelFile,
        expectedSHA256: String? = nil
    ) throws -> RecipeFileResource {
        let result = try stream(url, to: nil, maximumBytes: maximumBytes)
        guard expectedSHA256 == nil || expectedSHA256 == result.sha256 else {
            throw RecipeInstallError.invalidResource("文件校验不符：\(url.lastPathComponent)")
        }
        return RecipeFileResource(url: url, size: result.size, sha256: result.sha256)
    }

    public static func snapshot(
        from source: URL, directory: URL, maximumBytes: Int = RecipeResourceBudget.modelFile,
        expectedSHA256: String? = nil
    ) throws -> RecipeFileResource {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(UUID().uuidString + ".resource")
        let lease = TemporaryResourceLease(destination)
        let result = try stream(source, to: destination, maximumBytes: maximumBytes)
        guard expectedSHA256 == nil || expectedSHA256 == result.sha256 else {
            throw RecipeInstallError.invalidResource("文件校验不符：\(source.lastPathComponent)")
        }
        return RecipeFileResource(url: destination, size: result.size, sha256: result.sha256, lease: lease)
    }

    /// Picker-friendly off-main capture. Caller keeps the security-scoped lease until this await
    /// finishes. Cancellation propagates to the blockwise worker before the lease can be released.
    public static func capture(
        from source: URL, directory: URL, maximumBytes: Int = RecipeResourceBudget.modelFile,
        expectedSHA256: String? = nil
    ) async throws -> RecipeFileResource {
        try Task.checkCancellation()
        let task = Task.detached(priority: .userInitiated) {
            try snapshot(from: source, directory: directory, maximumBytes: maximumBytes, expectedSHA256: expectedSHA256)
        }
        let result = try await withTaskCancellationHandler(
            operation: { try await task.value }, onCancel: { task.cancel() })
        try Task.checkCancellation()
        return result
    }

    /// Explicit user-requested acquisition. URLSession writes to disk; no response-body Data is made.
    /// `maximumBytes` is a hard cap enforced both from the declared length and from the
    /// running byte count, so a missing/lying `Content-Length` cannot fill the disk.
    /// `transport` lets a batch reuse one ephemeral session; `nil` creates and releases one
    /// for this single download. The transport is never invalidated here: the caller owns it
    /// and may still be using it for the rest of the batch. Cancellation cancels the transfer,
    /// and the partial temporary file is removed before any resource is published.
    public static func download(
        from url: URL, directory: URL, maximumBytes: Int = RecipeResourceBudget.modelFile,
        expectedSHA256: String? = nil,
        progress: @escaping @Sendable (Int64) -> Void = { _ in }
    ) async throws -> RecipeFileResource {
        let transport = HTTPSResourceTransport()
        defer { transport.invalidate() }
        return try await download(
            from: url, directory: directory, maximumBytes: maximumBytes,
            expectedSHA256: expectedSHA256, transport: transport, progress: progress)
    }

    /// Batch variant of `download(from:directory:maximumBytes:expectedSHA256:progress:)`.
    /// Package-internal because `HTTPSResourceTransport` is not part of the public surface.
    static func download(
        from url: URL, directory: URL, maximumBytes: Int = RecipeResourceBudget.modelFile,
        expectedSHA256: String? = nil, transport: HTTPSResourceTransport,
        progress: @escaping @Sendable (Int64) -> Void = { _ in }
    ) async throws -> RecipeFileResource {
        guard maximumBytes >= 0, maximumBytes <= RecipeResourceBudget.modelFile else {
            throw RecipeInstallError.invalidResource("文件大小参数超出限制")
        }
        try HTTPSResourceReader.validate(url)
        let delegate = ResourceDownloadDelegate(maximumBytes: maximumBytes, progress: progress)
        do {
            try Task.checkCancellation()
            let (temporary, response) = try await withTaskCancellationHandler(
                operation: {
                    try await delegate.transfer(from: url, makeTask: { transport.makeDownloadTask(url: $0) })
                }, onCancel: { delegate.cancel() })
            defer { try? FileManager.default.removeItem(at: temporary) }
            try Task.checkCancellation()
            if let failure = delegate.failure { throw RecipeInstallError.invalidResource(failure) }
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                response.url?.scheme == "https"
            else {
                throw RecipeInstallError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
            }
            let asset = try await capture(
                from: temporary, directory: directory, maximumBytes: maximumBytes, expectedSHA256: expectedSHA256)
            try Task.checkCancellation()
            return asset
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if let failure = delegate.failure { throw RecipeInstallError.invalidResource(failure) }
            throw error
        }
    }

    /// Copies without hashing again: the identity was fixed when the file was captured.
    func copy(to destination: URL, maximumBytes: Int) throws {
        let input = try BoundedLocalFile(url, maximumBytes: maximumBytes)
        guard input.size == size else {
            throw RecipeInstallError.invalidResource("文件在准备期间已被修改：\(url.lastPathComponent)")
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try input.copy(to: destination)
    }

    private static func stream(_ source: URL, to destination: URL?, maximumBytes: Int) throws -> (
        size: Int, sha256: String
    ) {
        guard maximumBytes >= 0, maximumBytes <= RecipeResourceBudget.modelFile else {
            throw RecipeInstallError.invalidResource("文件大小参数超出限制")
        }
        let input = try BoundedLocalFile(source, maximumBytes: maximumBytes)
        var output: FileHandle?
        var created = false
        var completed = false
        defer {
            try? output?.close()
            if created && !completed, let destination { try? FileManager.default.removeItem(at: destination) }
        }
        if let destination {
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw RecipeInstallError.invalidResource("目标文件已存在：\(destination.path)")
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                throw RecipeInstallError.invalidResource(destination.path)
            }
            created = true
            output = try FileHandle(forWritingTo: destination)
        }
        defer { try? output?.close() }
        var hash = SHA256(), count = 0
        try input.consume { chunk in
            count += chunk.count
            hash.update(data: chunk)
            try output?.write(contentsOf: chunk)
        }
        try output?.synchronize()
        completed = true
        return (count, hash.finalize().hex)
    }
}

/// Only UUID files created by snapshot are owned. References to installed/user files never delete.
private final class TemporaryResourceLease: Sendable {
    let url: URL
    init(_ url: URL) { self.url = url }
    deinit { try? FileManager.default.removeItem(at: url) }
}

private final class ResourceDownloadDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    private let maximumBytes: Int
    private let progress: @Sendable (Int64) -> Void
    private struct State {
        var problem: String?
        var cancelled = false
        var task: URLSessionDownloadTask?
        var continuation: CheckedContinuation<(URL, URLResponse), Error>?
        var downloaded: TemporaryResourceLease?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var failure: String? { state.withLock { $0.problem } }
    init(maximumBytes: Int, progress: @escaping @Sendable (Int64) -> Void) {
        self.maximumBytes = maximumBytes
        self.progress = progress
    }
    private func fail(_ value: String) { state.withLock { $0.problem = value } }
    func transfer(from url: URL, makeTask: (URL) -> URLSessionDownloadTask) async throws -> (URL, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            // Unchecked only because `makeTask` is not @Sendable; it runs synchronously here.
            let task = state.withLockUnchecked { state -> URLSessionDownloadTask? in
                guard !state.cancelled else { return nil }
                state.continuation = continuation
                let task = makeTask(url)
                // The session has no session-level delegate, so the per-task delegate carries
                // cancellation and progress for this download only.
                task.delegate = self
                state.task = task
                return task
            }
            guard let task else {
                continuation.resume(throwing: CancellationError())
                return
            }
            task.resume()
        }
    }
    func cancel() {
        let task = state.withLock { state in
            state.cancelled = true
            return state.task
        }
        task?.cancel()
    }
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, (try? HTTPSResourceReader.validate(url)) != nil else {
            fail("链接跳转到了不安全的地址，已停止下载")
            // Refusing the redirect alone leaves URLSession waiting for the original
            // request until the timeout; cancel so the refusal completes immediately.
            task.cancel()
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesWritten > Int64(maximumBytes) || totalBytesExpectedToWrite > Int64(maximumBytes) {
            fail("外部下载文件超过大小限制")
            downloadTask.cancel()
        }
        progress(totalBytesWritten)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // URLSession removes location as soon as this callback returns. Move only
        // the completed transfer into a UUID-owned lease; never create resume data.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".model-download")
        let lease = TemporaryResourceLease(url)
        do {
            try FileManager.default.moveItem(at: location, to: url)
            state.withLock { $0.downloaded = lease }
        } catch { fail("保存模型下载文件失败：\(error.localizedDescription)") }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, cancelled, problem, downloaded) = state.withLock { state in
            let continuation = state.continuation
            state.continuation = nil
            state.task = nil
            return (continuation, state.cancelled, state.problem, state.downloaded)
        }
        if cancelled {
            continuation?.resume(throwing: CancellationError())
        } else if let problem {
            continuation?.resume(throwing: RecipeInstallError.invalidResource(problem))
        } else if let error {
            continuation?.resume(throwing: error)
        } else if let downloaded, let response = task.response {
            continuation?.resume(returning: (downloaded.url, response))
        } else {
            continuation?.resume(throwing: RecipeInstallError.invalidResource("模型下载未返回完整文件，请重试。"))
        }
    }
}

public struct RecipeWorkspaceSnapshot: Sendable {
    public let files: [String: Data]
    public let fileResources: [String: RecipeFileResource]
    public let userCustomFiles: [String: Data]
    public init(
        files: [String: Data], fileResources: [String: RecipeFileResource], userCustomFiles: [String: Data] = [:]
    ) {
        self.files = files
        self.fileResources = fileResources
        self.userCustomFiles = userCustomFiles
    }
}
