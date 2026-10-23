import CryptoKit
import XCTest
import os

@testable import PackageManager

/// Deterministic offline coverage for the bounded HTTPS transport. A `URLProtocol`
/// fixture serves every response from memory, so these tests exercise redirect
/// refusal, the pre-body Content-Length rejection, incremental byte enforcement,
/// cancellation and batch transport reuse without touching the network.
final class HTTPSResourceReaderTests: XCTestCase {
    override func tearDown() {
        FixtureTransport.reset()
        super.tearDown()
    }

    // MARK: - Over budget

    /// Declared length over budget must fail before any body byte is buffered. The
    /// fixture keeps pushing (as a hostile peer would), so the invariant under test is
    /// the delegate's own buffer, observed directly.
    func testDeclaredLengthOverBudgetRejectedBeforeBody() async throws {
        let body = Data(repeating: 0x41, count: 8192)
        FixtureTransport.plan = [
            .init(path: "/declared", status: 200, declaredLength: 8192, body: body, chunkCount: 8, chunkDelay: 0.002)
        ]
        let observations = Observation()
        do {
            _ = try await read(FixtureTransport.url("/declared"), maximumBytes: 1024, observations: observations)
            XCTFail("Declared over-budget length was accepted")
        } catch let error as RecipeInstallError {
            guard case .invalidResource(let detail) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(detail.contains("exceeds"), detail)
        }
        XCTAssertEqual(
            observations.values.count, 0,
            "the declared length is rejected in didReceive, before any body chunk is delivered")
    }

    /// A lying/absent Content-Length must not grow the buffer; the running count stops it.
    func testUnannouncedBodyOverBudgetStopsIncrementally() async throws {
        let body = Data(repeating: 0x42, count: 4096)
        FixtureTransport.plan = [
            .init(
                path: "/unannounced", status: 200, declaredLength: nil,
                body: body, chunkCount: 8, chunkDelay: 0.002)
        ]
        let observations = Observation()
        do {
            _ = try await read(FixtureTransport.url("/unannounced"), maximumBytes: 1024, observations: observations)
            XCTFail("Unannounced over-budget body was accepted")
        } catch let error as RecipeInstallError {
            guard case .invalidResource(let detail) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(detail.contains("exceeds"), detail)
        }
        let peak = observations.values.max() ?? 0
        XCTAssertLessThanOrEqual(peak, 1024, "the accumulated buffer must never exceed the budget")
        XCTAssertGreaterThan(peak, 0, "the first chunk under budget is legitimately buffered")
    }

    func testExactBudgetIsAccepted() async throws {
        let body = Data(repeating: 0x43, count: 1024)
        FixtureTransport.plan = [.init(path: "/exact", status: 200, declaredLength: 1024, body: body)]
        let data = try await read(FixtureTransport.url("/exact"), maximumBytes: 1024)
        XCTAssertEqual(data, body, "a body exactly at the budget is allowed")
    }

    /// An empty body is a valid, empty read (not a silent failure).
    func testEmptyBodyAccepted() async throws {
        FixtureTransport.plan = [.init(path: "/empty", status: 200, declaredLength: 0, body: Data())]
        let data = try await read(FixtureTransport.url("/empty"), maximumBytes: 16)
        XCTAssertEqual(data, Data())
    }

    // MARK: - Redirects

    /// https -> https is followed, and the final bytes are what the caller gets.
    func testHTTPSRedirectIsFollowed() async throws {
        FixtureTransport.plan = [
            .init(path: "/start", status: 302, redirectTo: "https://fixture.test/final"),
            .init(path: "/final", status: 200, declaredLength: 4, body: Data("done".utf8)),
        ]
        let data = try await read(FixtureTransport.url("/start"), maximumBytes: 64)
        XCTAssertEqual(data, Data("done".utf8))
        XCTAssertEqual(FixtureTransport.requestedPaths, ["/start", "/final"])
    }

    /// https -> http downgrade is refused; the insecure target is never fetched.
    func testHTTPDowngradeRedirectIsRefused() async throws {
        FixtureTransport.plan = [
            .init(path: "/downgrade", status: 302, redirectTo: "http://fixture.test/final"),
            .init(path: "/final", status: 200, declaredLength: 4, body: Data("leak".utf8)),
        ]
        do {
            _ = try await read(FixtureTransport.url("/downgrade"), maximumBytes: 64)
            XCTFail("Insecure redirect was followed")
        } catch let error as RecipeInstallError {
            guard case .invalidResource(let detail) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(detail.contains("不安全的地址"), detail)
        }
        XCTAssertEqual(FixtureTransport.requestedPaths, ["/downgrade"], "the downgraded target must never be requested")
    }

    /// A redirect to a URL carrying embedded credentials is refused as well.
    func testCredentialedRedirectIsRefused() async throws {
        FixtureTransport.plan = [
            .init(path: "/credentials", status: 302, redirectTo: "https://user:secret@fixture.test/final"),
            .init(path: "/final", status: 200, declaredLength: 4, body: Data("leak".utf8)),
        ]
        do {
            _ = try await read(FixtureTransport.url("/credentials"), maximumBytes: 64)
            XCTFail("Credentialed redirect was followed")
        } catch is RecipeInstallError {}
        XCTAssertEqual(FixtureTransport.requestedPaths, ["/credentials"])
    }

    // MARK: - Status and scheme

    func testNonHTTPSInputIsRejectedWithoutStartingATransfer() async throws {
        do {
            _ = try await read(URL(string: "http://fixture.test/insecure")!, maximumBytes: 64)
            XCTFail("Plain HTTP input was accepted")
        } catch let error as RecipeInstallError {
            guard case .invalidResource = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(FixtureTransport.requestedPaths, [])
    }

    func testNonSuccessStatusIsReportedAsHTTPError() async throws {
        FixtureTransport.plan = [.init(path: "/missing", status: 404, declaredLength: 3, body: Data("no!".utf8))]
        do {
            _ = try await read(FixtureTransport.url("/missing"), maximumBytes: 64)
            XCTFail("404 was accepted")
        } catch let error as RecipeInstallError {
            guard case .http(let code) = error, code == 404 else { return XCTFail("\(error)") }
        }
    }

    // MARK: - Cancellation

    func testCancellationBeforeRunCompletesRegardlessOfCallbackOrder() async {
        for completesBeforeRun in [true, false] {
            let session = URLSession(configuration: FixtureTransport.configuration())
            defer { session.invalidateAndCancel() }
            // Leave the task's delegate unset: manually deliver completion so the
            // regression cannot pass because URLSession happens to deliver it late.
            let dataTask = session.dataTask(with: FixtureTransport.url("/cancel-before-run"))
            let delegate = HTTPSResourceDelegate(maximumBytes: 64)
            delegate.cancel(task: dataTask)
            if completesBeforeRun {
                delegate.urlSession(session, task: dataTask, didCompleteWithError: URLError(.cancelled))
            }
            let finished = expectation(description: "cancelled run finishes; early callback: \(completesBeforeRun)")
            finished.assertForOverFulfill = true
            let read = Task {
                do {
                    _ = try await delegate.run(task: dataTask)
                    XCTFail("Cancelled read returned data")
                } catch is CancellationError {
                } catch {
                    XCTFail("Expected CancellationError, got \(error)")
                }
                finished.fulfill()
            }
            await fulfillment(of: [finished], timeout: 1)
            // Late/duplicate completions must not resume the checked continuation
            // twice. This also releases a stuck read if the regression returns.
            delegate.urlSession(session, task: dataTask, didCompleteWithError: URLError(.cancelled))
            delegate.urlSession(session, task: dataTask, didCompleteWithError: nil)
            await read.value
        }
        XCTAssertEqual(FixtureTransport.requestedPaths, [])
    }

    func testCancellationPropagatesAndStopsTransfer() async throws {
        FixtureTransport.plan = [
            .init(
                path: "/slow", status: 200, declaredLength: nil,
                body: Data(repeating: 0x44, count: 4096), chunkCount: 64, chunkDelay: 0.02)
        ]
        let task = Task { try await read(FixtureTransport.url("/slow"), maximumBytes: 1024 * 1024) }
        try await FixtureTransport.waitForFirstChunk()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled read returned data")
        } catch is CancellationError {}
        // Let any already-queued chunk land, then prove delivery has stopped for good.
        try await Task.sleep(nanoseconds: 300_000_000)
        let deliveredAtCancel = FixtureTransport.servedBodyBytes
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(
            FixtureTransport.servedBodyBytes, deliveredAtCancel, "no chunk may be delivered after cancellation")
        XCTAssertLessThan(deliveredAtCancel, 4096, "cancellation must stop a slow transfer early")
    }

    // MARK: - Batch transport reuse

    /// One transport serves a whole batch: every request shares the same session
    /// (proved by the transport marker) and no per-file session is created.
    func testBatchReusesOneTransportAcrossFiles() async throws {
        FixtureTransport.plan = (0..<5).map { index in
            .init(path: "/batch/\(index)", status: 200, declaredLength: 3, body: Data("f\(index)".utf8))
        }
        let transport = HTTPSResourceTransport(configuration: FixtureTransport.configuration())
        defer { transport.invalidate() }
        for index in 0..<5 {
            let data = try await transport.read(FixtureTransport.url("/batch/\(index)"), maximumBytes: 64)
            XCTAssertEqual(data, Data("f\(index)".utf8))
        }
        XCTAssertTrue(
            FixtureTransport.transportMarkers.allSatisfy { $0 == FixtureTransport.marker },
            "all batch reads must flow through one transport: \(FixtureTransport.transportMarkers)")
        // One capacity prefix reserved per read would be invisible; what matters is that
        // the batch is actually serialized on the shared transport and completes.
        XCTAssertEqual(FixtureTransport.requestedPaths.count, 5)
    }

    /// The manager-batch read keeps the public per-manager transport while never
    /// creating a new session per file. Exercised through the real `prefetch` path,
    /// which is what a recipe install actually calls.
    func testRecipePackageManagerReusesItsOwnTransportForPrefetch() async throws {
        let files = [
            "a.schema.yaml": Data("schema: {schema_id: a}".utf8),
            "LICENSE": Data("license".utf8),
            "recipe.yaml": Data("recipe: {}".utf8),
        ]
        FixtureTransport.plan = files.map { path, body in
            .init(path: "/" + path, status: 200, declaredLength: body.count, body: body)
        }
        let manifest = RecipeManifest(
            id: "test", repository: "user/test", revision: String(repeating: "a", count: 40),
            recipePath: "recipe.yaml", license: "LICENSE", schemaID: "a", requiredComponents: [],
            files: files.map { path, body in
                .init(
                    path: path, sha256: SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined(),
                    size: body.count)
            }, origin: nil)
        let manager = RecipePackageManager(
            rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("transport-" + UUID().uuidString),
            configuration: FixtureTransport.configuration())
        // `prefetch` builds raw.githubusercontent.com URLs; the fixture matches on path.
        let prepared = try await manager.prefetch(manifest)
        XCTAssertEqual(prepared.manifest.files.count, files.count)
        XCTAssertEqual(FixtureTransport.requestedPaths.count, files.count)
        XCTAssertTrue(
            files.keys.allSatisfy { path in FixtureTransport.requestedPaths.contains { $0.hasSuffix("/" + path) } },
            "every pinned file must have been requested: \(FixtureTransport.requestedPaths)")
        XCTAssertTrue(
            FixtureTransport.transportMarkers.allSatisfy { $0 == FixtureTransport.marker },
            "every prefetch read must flow through the manager's one transport")
    }

    /// `RecipeFileResource.download` uses the disk path and the same bounded transport.
    func testDiskBackedDownloadEnforcesBudgetAndCleansUp() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("download-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        FixtureTransport.plan = [
            .init(
                path: "/model", status: 200, declaredLength: nil,
                body: Data(repeating: 0x45, count: 4096))
        ]
        do {
            _ = try await RecipeFileResource.download(
                from: FixtureTransport.url("/model"), directory: directory, maximumBytes: 1024)
            XCTFail("Over-budget disk download was accepted")
        } catch {}
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path), [],
            "an over-budget download must not publish or leak a resource")
    }

    // MARK: - Helpers

    /// Thread-safe sink for the transport's internal buffer observations.
    fileprivate final class Observation: Sendable {
        private let recorded = OSAllocatedUnfairLock(initialState: [Int]())
        var values: [Int] { recorded.withLock { $0 } }
        func record(_ value: Int) { recorded.withLock { $0.append(value) } }
    }
}

private func read(_ url: URL, maximumBytes: Int, observations: HTTPSResourceReaderTests.Observation? = nil) async throws
    -> Data
{
    var observer: (@Sendable (Int) -> Void)?
    if let observations { observer = { observations.record($0) } }
    let transport = HTTPSResourceTransport(
        configuration: FixtureTransport.configuration(),
        bufferedByteObserver: observer)
    defer { transport.invalidate() }
    return try await transport.read(url, maximumBytes: maximumBytes)
}

/// In-memory `URLProtocol` fixture. Responses are planned per path; body delivery is
/// chunked so incremental budget enforcement and cancellation are observable.
// @unchecked: URLProtocol is not Sendable; this subclass keeps its own state in a lock and
// URLProtocolClient callbacks may come from any thread.
private final class FixtureTransport: URLProtocol, @unchecked Sendable {
    struct Response: Sendable {
        var path: String
        var status: Int
        var declaredLength: Int?
        var body: Data = Data()
        var redirectTo: String?
        var chunkCount: Int = 1
        var chunkDelay: TimeInterval = 0
    }

    static let marker = "fixture-transport"
    static let markerHeader = "X-Fixture-Transport"
    private struct Shared {
        var plan: [Response] = []
        var requestedPaths: [String] = []
        var servedBodyBytes = 0
        var markers: [String] = []
        var firstChunk: CheckedContinuation<Void, Never>?
        var sawFirstChunk = false
    }
    private static let shared = OSAllocatedUnfairLock(initialState: Shared())
    // URLProtocol object addresses can be reused between successive file requests.
    private let delivery = OSAllocatedUnfairLock(initialState: (isStopped: false, generation: 0))

    static var plan: [Response] {
        get { shared.withLock { $0.plan } }
        set { shared.withLock { $0.plan = newValue } }
    }
    static var requestedPaths: [String] { shared.withLock { $0.requestedPaths } }
    static var servedBodyBytes: Int { shared.withLock { $0.servedBodyBytes } }
    static var transportMarkers: [String] { shared.withLock { $0.markers } }

    static func reset() {
        shared.withLock { $0 = Shared() }
    }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureTransport.self]
        configuration.httpAdditionalHeaders = [markerHeader: marker]
        return configuration
    }

    static func url(_ path: String) -> URL { URL(string: "https://fixture.test\(path)")! }

    static func waitForFirstChunk() async throws {
        if shared.withLock({ $0.sawFirstChunk }) { return }
        await withCheckedContinuation { continuation in
            let seen = shared.withLock { state in
                if !state.sawFirstChunk { state.firstChunk = continuation }
                return state.sawFirstChunk
            }
            if seen { continuation.resume() }
        }
    }

    private func stopped(generation: Int) -> Bool {
        delivery.withLock { $0.isStopped || $0.generation != generation }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let generation = delivery.withLock { state -> Int in
            state.isStopped = false
            state.generation &+= 1
            return state.generation
        }
        let path = request.url?.path ?? ""
        let marker = request.value(forHTTPHeaderField: Self.markerHeader)
        let plan = Self.shared.withLock { state in
            state.requestedPaths.append(path)
            if let marker { state.markers.append(marker) }
            return state.plan.first { plan in
                // `prefetch` builds raw.githubusercontent.com URLs, so match on the suffix.
                path == plan.path || path.hasSuffix(plan.path)
            }
        }
        guard let plan else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        // Redirects are expressed as an HTTP redirect; the session then re-enters this
        // fixture for the target path (or refuses it in willPerformHTTPRedirection).
        if let target = plan.redirectTo {
            let response = HTTPURLResponse(
                url: request.url!, statusCode: plan.status, httpVersion: "HTTP/1.1",
                headerFields: ["Location": target])!
            var next = URLRequest(url: URL(string: target)!)
            next.httpMethod = request.httpMethod
            next.httpBody = request.httpBody
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            return
        }
        var headers: [String: String] = [:]
        if let length = plan.declaredLength { headers["Content-Length"] = String(length) }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: plan.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // Deliver on a background queue, like a real connection, so the framework's
        // `stopLoading()` can actually preempt the remaining chunks. A synchronous loop
        // would drain the whole body before any cancel could be observed.
        let chunks = Self.split(plan.body, into: plan.chunkCount)
        DispatchQueue.global().async { [weak self] in
            for chunk in chunks {
                guard let self, !self.stopped(generation: generation) else { return }
                if plan.chunkDelay > 0 { Thread.sleep(forTimeInterval: plan.chunkDelay) }
                guard !self.stopped(generation: generation) else { return }
                let continuation = Self.shared.withLock { state in
                    state.servedBodyBytes += chunk.count
                    let first = !state.sawFirstChunk
                    state.sawFirstChunk = true
                    let continuation = first ? state.firstChunk : nil
                    if first { state.firstChunk = nil }
                    return continuation
                }
                continuation?.resume()
                self.client?.urlProtocol(self, didLoad: chunk)
            }
            guard let self, !self.stopped(generation: generation) else { return }
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        delivery.withLock { state in
            state.isStopped = true
            state.generation &+= 1
        }
    }

    private static func split(_ data: Data, into count: Int) -> [Data] {
        guard count > 1, data.count > 1 else { return data.isEmpty ? [] : [data] }
        let size = max(1, data.count / count)
        var chunks: [Data] = []
        var offset = 0
        while offset < data.count {
            let end = min(offset + size, data.count)
            chunks.append(data.subdata(in: offset..<end))
            offset = end
        }
        return chunks
    }
}
