import Foundation
import KeyboardCore
import RimeBridge
import os

/// Owns librime's lifetime, including in-flight startup and shutdown.
/// Screen intent is latest-wins; exclusive jobs are FIFO.
@MainActor
public final class EngineOwnershipCoordinator {
    public static let shared = EngineOwnershipCoordinator()
    private struct Screen {
        let id: UUID
        let revision: UUID
        let start: () async -> Void
        let stop: () async -> Void
    }
    private final class Job {
        let isCancelled: () -> Bool
        let prepare: () throws -> Void
        let run: (Error?) async -> Void
        private var preparation: Result<Void, Error>?

        init(
            isCancelled: @escaping () -> Bool, prepare: @escaping () throws -> Void,
            run: @escaping (Error?) async -> Void
        ) {
            self.isCancelled = isCancelled
            self.prepare = prepare
            self.run = run
        }

        /// Check once, before stop changes the screen state that was checked.
        func preparationError() -> Error? {
            if preparation == nil { preparation = Result(catching: prepare) }
            if case .failure(let error) = preparation { return error }
            return nil
        }
    }
    private var desired: Screen?
    private var active: Screen?
    private var jobs: [Job] = []
    private var worker: Task<Void, Never>?
    private final class Cancellation: Sendable {
        private let state = OSAllocatedUnfairLock<(cancelled: Bool, operation: (@Sendable () -> Void)?)>(
            initialState: (false, nil))
        func cancel() {
            let action = state.withLock { state in
                state.cancelled = true
                return state.operation
            }
            action?()
        }
        func bind(_ action: (@Sendable () -> Void)?) {
            let cancelled = state.withLock { state in
                state.operation = action
                return state.cancelled
            }
            if cancelled { action?() }
        }
        var isCancelled: Bool { state.withLock { $0.cancelled } }
    }

    /// EngineOpQueue only throws errors from its body; this body cannot throw.
    public static func shutdown(_ body: @escaping @Sendable () -> Void) async {
        do { try await EngineOpQueue.async(body) } catch {
            preconditionFailure("Nonthrowing engine cleanup failed: \(error)")
        }
    }

    public func claim(
        _ id: UUID, start: @escaping () async -> Void,
        stop: @escaping () async -> Void
    ) {
        desired = Screen(id: id, revision: UUID(), start: start, stop: stop)
        schedule()
    }

    public func release(_ id: UUID) {
        if desired?.id == id { desired = nil }
        schedule()
    }

    /// Runs `beforeYield` once on the UI actor before stopping the active screen.
    /// A rejected request completes with its error while the screen keeps input ownership.
    public func withExclusive<T: Sendable>(
        beforeYield: @escaping () throws -> Void = {},
        _ operation: @escaping () async throws -> T
    ) async throws -> T {
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { continuation in
                    jobs.append(
                        Job(
                            isCancelled: { cancellation.isCancelled }, prepare: beforeYield,
                            run: { preparationError in
                                do {
                                    if let preparationError { throw preparationError }
                                    let task = Task {
                                        try Task.checkCancellation()
                                        return try await operation()
                                    }
                                    cancellation.bind { task.cancel() }
                                    defer { cancellation.bind(nil) }
                                    let value = try await task.value
                                    continuation.resume(returning: value)
                                } catch { continuation.resume(throwing: error) }
                            }))
                    schedule()
                }
            },
            onCancel: {
                cancellation.cancel()
            })
    }

    private func schedule() {
        guard worker == nil else { return }
        worker = Task { await drain() }
    }

    private func drain() async {
        while true {
            // A cancelled waiter must not interrupt a live screen merely to
            // deliver CancellationError to its continuation.
            if let first = jobs.first, first.isCancelled() {
                let job = jobs.removeFirst()
                await job.run(CancellationError())
                continue
            }
            if let first = jobs.first, let error = first.preparationError() {
                let job = jobs.removeFirst()
                await job.run(error)
                continue
            }
            if let current = active,
                !jobs.isEmpty || current.revision != desired?.revision
            {
                await current.stop()
                active = nil
                continue
            }
            if !jobs.isEmpty {
                let job = jobs.removeFirst()
                await job.run(nil)
                continue
            }
            if active == nil, let next = desired {
                active = next
                await next.start()
                continue
            }
            worker = nil
            return
        }
    }
}
