import Foundation

/// A labelled serial queue whose work is awaited from async code, so callers never block on disk I/O.
public struct SerialIOQueue: Sendable {
    private let queue: DispatchQueue

    public init(label: String, qos: DispatchQoS) {
        queue = DispatchQueue(label: label, qos: qos)
    }

    /// Runs `body` on the queue and returns its result.
    public func async<T>(_ body: @escaping @Sendable () throws -> T) async throws -> sending T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try body()) } catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Non-throwing variant.
    public func async<T>(_ body: @escaping @Sendable () -> T) async -> sending T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }
}
