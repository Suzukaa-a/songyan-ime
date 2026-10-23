import Darwin
import Foundation
import os

// MARK: - Engine directories and single-instance serial operations
//
// librime is a process-wide singleton engine (the C API does not support two active
// instances writing in one process), so this file funnels engine create/start/destroy within
// a process onto one serial queue. The host app's runtime self-check and interactive engine
// and the keyboard extension's engine live in separate processes with separate user
// directories (see RimePaths).

/// In-process serial queue for the engine lifecycle (see the file header).
public enum EngineOpQueue {
    private static let serial = DispatchQueue(label: "app.songyan.engine.op", qos: .userInitiated)

    /// Runs an engine operation synchronously on the serial queue (blocks the calling thread; call only from a background thread).
    public static func sync<T>(_ body: () throws -> T) throws -> T {
        #if DEBUG
            let probe = DebugProbe.engineOp("sync")
            defer { probe(false) }
            return try serial.sync {
                probe(true)
                return try body()
            }
        #else
            try serial.sync { try body() }
        #endif
    }

    /// Enqueues an engine operation on the serial queue without waiting for the result (`body` hands the result back itself).
    public static func enqueue(_ body: @escaping @Sendable () -> Void) {
        #if DEBUG
            let probe = DebugProbe.engineOp("enqueue")
            serial.async {
                probe(true)
                body()
                probe(false)
            }
        #else
            serial.async { body() }
        #endif
    }

    /// Runs an engine operation asynchronously on the serial queue (does not block the calling thread).
    public static func async<T>(_ body: @escaping @Sendable () throws -> T) async throws -> sending T {
        #if DEBUG
            let probe = DebugProbe.engineOp("async")
            defer { probe(false) }
        #endif
        return try await withCheckedThrowingContinuation { continuation in
            serial.async {
                #if DEBUG
                    probe(true)
                #endif
                do {
                    continuation.resume(returning: try body())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Runs an `async` engine operation on the same serial queue. The queue is held exclusively for
    /// the whole lifetime of `body` (consistent with the `async`/`sync` mutual-exclusion order), so it
    /// is serialized with engine lifecycle operations while still allowing `body` to `await` other
    /// background boundaries (for example the async CAS of the publication list).
    ///
    /// Must not run on the MainActor: `body` must be explicitly `@Sendable` and runs through
    /// `Task.detached`, because `Task {}` inherits the caller's actor isolation (MainActor) and would pull disk I/O back onto the main thread.
    ///
    /// Implementation notes: the serial-queue thread waits for the detached task to finish
    /// (`DispatchSemaphore`; `signal` before `wait` returning establishes happens-before), so
    /// serialization is kept; each `serial.async` block resumes the continuation only once (no
    /// double resume), and a throwing `body` also resumes only once.
    /// Never use `EngineOpQueue` inside `body` (self-wait deadlock).
    public static func asyncExclusive<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            serial.async {
                let semaphore = DispatchSemaphore(value: 0)
                let box = ResultBox<T>()
                Task.detached(priority: .userInitiated) {
                    do { box.set(.success(try await body())) } catch { box.set(.failure(error)) }
                    semaphore.signal()
                }
                semaphore.wait()
                continuation.resume(with: box.take() ?? .failure(CancellationError()))
            }
        }
    }

    /// Cross-task result storage for `asyncExclusive`; the semaphore orders the single write before the read.
    private final class ResultBox<T: Sendable>: Sendable {
        private let value = OSAllocatedUnfairLock<Result<T, Error>?>(initialState: nil)
        func set(_ result: Result<T, Error>) { value.withLock { $0 = result } }
        func take() -> Result<T, Error>? { value.withLock { $0 } }
    }
}
