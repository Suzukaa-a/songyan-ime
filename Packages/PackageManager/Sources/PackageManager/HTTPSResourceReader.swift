import Foundation
import os

/// The same transport serves reviewed recipes and user-entered HTTPS URLs.
///
/// `HTTPSResourceTransport` owns one ephemeral `URLSession` and is deliberately NOT a
/// global singleton: the caller creates one per installation/batch, so redirect policy,
/// cookies and connection reuse never cross unrelated installs. Callers that fetch many
/// files (a recipe prefetch, one source acquisition, the whole source dependency
/// resolution) share one instance for that batch and let ARC release it afterwards.
///
/// Bounds applied to every transfer:
/// - a declared `Content-Length` over budget is rejected before any body byte is consumed;
/// - the running byte count is re-checked before every chunk is accumulated, so a lying
///   or absent `Content-Length` can never grow the `Data` past `maximumBytes` (peak is
///   the budget itself, not budget + one chunk);
/// - each redirect target must itself pass `HTTPSResourceReader.validate` (HTTPS, host
///   present, no embedded credentials), otherwise the redirect is refused, not followed;
/// - cancellation cancels the underlying task; no partial `Data` is ever returned.
final class HTTPSResourceTransport: Sendable {
    private let session: URLSession
    private let delegateQueue: OperationQueue
    /// Internal invariant probe: reports the bytes currently buffered by an in-flight
    /// read's delegate. Tests use it to prove the accumulated `Data` never exceeds the
    /// budget even when the peer ignores cancellation. Not part of the public surface.
    private let bufferedByteObserver: (@Sendable (Int) -> Void)?

    init(
        configuration: URLSessionConfiguration = .ephemeral,
        bufferedByteObserver: (@Sendable (Int) -> Void)? = nil
    ) {
        self.bufferedByteObserver = bufferedByteObserver
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        delegateQueue = queue
        // No session-level delegate: session delegates are retained by the session
        // (a cycle) and would serialize unrelated reads onto shared mutable state.
        session = URLSession(configuration: configuration, delegate: nil, delegateQueue: queue)
    }

    deinit {
        // An in-flight `read` retains `self`, so reaching deinit proves no transfer
        // is live: release pooled connections immediately instead of waiting for
        // URLSession's own dealloc.
        session.invalidateAndCancel()
    }

    func invalidate() {
        session.invalidateAndCancel()
    }

    /// Creates a download task on the shared session for a caller-owned
    /// `URLSessionDownloadDelegate`. The disk-backed model path uses this so one
    /// transport can serve a batch of file downloads too.
    func makeDownloadTask(url: URL) -> URLSessionDownloadTask {
        session.downloadTask(
            with: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60))
    }

    /// One bounded HTTPS transfer.
    func read(_ url: URL, maximumBytes: Int) async throws -> Data {
        try Task.checkCancellation()
        guard maximumBytes >= 0 else { throw RecipeInstallError.invalidResource("Negative byte budget") }
        try HTTPSResourceReader.validate(url)
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        let task = session.dataTask(with: request)
        // A per-task delegate keeps concurrent reads on one session independent
        // without any shared mutable state on the transport.
        let delegate = HTTPSResourceDelegate(maximumBytes: maximumBytes, observer: bufferedByteObserver)
        task.delegate = delegate
        return try await withTaskCancellationHandler(
            operation: {
                try await delegate.run(task: task)
            },
            onCancel: {
                delegate.cancel(task: task)
            })
    }
}

final class HTTPSResourceDelegate: NSObject, URLSessionDataDelegate, Sendable {
    private let maximumBytes: Int
    private let observer: (@Sendable (Int) -> Void)?
    private struct State {
        var problem: Error?
        var cancelled = false
        var data = Data()
        var continuation: CheckedContinuation<Data, Error>?
    }
    private let state: OSAllocatedUnfairLock<State>

    init(maximumBytes: Int, observer: (@Sendable (Int) -> Void)? = nil) {
        self.maximumBytes = maximumBytes
        self.observer = observer
        var initial = State()
        // Reserve only a modest head start: capacity growth stays amortized and
        // bounded by `maximumBytes`, and never follows Content-Length.
        initial.data.reserveCapacity(min(maximumBytes, RecipeResourceBudget.bufferBytes))
        state = OSAllocatedUnfairLock(initialState: initial)
    }

    /// First failure wins: it is the actionable cause of the transport error that follows.
    private func fail(_ error: Error) {
        state.withLock { if $0.problem == nil { $0.problem = error } }
    }

    func cancel(task: URLSessionTask) {
        state.withLock { $0.cancelled = true }
        task.cancel()
    }

    func run(task: URLSessionDataTask) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let stored = state.withLock { state -> Bool in
                guard !state.cancelled else { return false }
                state.continuation = continuation
                return true
            }
            guard stored else {
                // Cancellation may already have completed the task before run began.
                // Do not store a continuation that will never receive another callback.
                continuation.resume(throwing: CancellationError())
                return
            }
            // `delegate` must be set and the continuation stored before resuming.
            task.resume()
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, (try? HTTPSResourceReader.validate(url)) != nil else {
            fail(RecipeInstallError.invalidResource("链接跳转到了不安全的地址，已停止下载"))
            // Refusing the redirect alone leaves URLSession waiting for the original
            // request until the 60s timeout; cancel the task so refusal completes now.
            task.cancel()
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            fail(RecipeInstallError.http(0))
            completionHandler(.cancel)
            return
        }
        guard http.statusCode == 200 else {
            fail(RecipeInstallError.http(http.statusCode))
            completionHandler(.cancel)
            return
        }
        // An unknown length (-1) is allowed here; it is still enforced incrementally.
        guard response.expectedContentLength <= Int64(maximumBytes) else {
            fail(RecipeInstallError.invalidResource("Download exceeds \(maximumBytes) bytes"))
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let (buffered, overBudget) = state.withLock { [maximumBytes] state -> (Int, Bool) in
            guard state.problem == nil else { return (-1, false) }
            guard state.data.count + data.count <= maximumBytes else {
                state.problem = RecipeInstallError.invalidResource("Download exceeds \(maximumBytes) bytes")
                return (state.data.count, true)
            }
            state.data.append(data)
            return (state.data.count, false)
        }
        observer?(buffered)
        if overBudget { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, cancelled, problem, data) = state.withLock { state in
            let continuation = state.continuation
            state.continuation = nil
            return (continuation, state.cancelled, state.problem, state.data)
        }
        guard let continuation else { return }
        // Caller cancellation wins over the -999 URLSession reports for a cancel we
        // requested ourselves (refused redirect, over-budget stop, rejected status).
        if cancelled {
            continuation.resume(throwing: CancellationError())
        } else if let problem {
            continuation.resume(throwing: problem)
        } else if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(returning: data)
        }
    }
}

enum HTTPSResourceReader {
    static func validate(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https", url.host?.isEmpty == false,
            url.user == nil, url.password == nil
        else {
            throw RecipeInstallError.invalidResource("Only HTTPS URLs without embedded credentials are supported")
        }
    }

    /// One-shot bounded read on a transport created and released for this call.
    /// Batch callers use `HTTPSResourceTransport` directly so one transport serves
    /// the whole batch instead of one ephemeral session per file.
    static func read(_ url: URL, maximumBytes: Int) async throws -> Data {
        let transport = HTTPSResourceTransport()
        defer { transport.invalidate() }
        return try await transport.read(url, maximumBytes: maximumBytes)
    }
}
