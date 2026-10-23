import Foundation

/// Read-only resource/appearance resolution queue for the keyboard.
///
/// Separate from `EngineOpQueue` (engine lifecycle serialization, the critical queue of the key
/// path): reads of `active.json` / `layouts.json` / the appearance snapshot go on an independent
/// low-priority queue, so a slow file read cannot queue behind engine operations and delay input.
/// These reads are still serialized among themselves (simple, deterministic), but never block
/// each other with the engine-ownership critical section.
///
/// The reads themselves are file I/O and do not touch the engine; publication atomicity (one
/// immutable read of `active.json`, immutable `generation` directories) guarantees ABA safety,
/// independent of the serial queue.
public enum KeyboardResourceReadQueue {
    private static let queue = DispatchQueue(
        label: "app.songyan.keyboard.resource.read",
        qos: .utility, attributes: [])

    /// Runs a read-only resolve on the independent low-priority queue without blocking the calling thread.
    public static func async<T>(_ body: @escaping @Sendable () throws -> T) async throws -> sending T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try body()) } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
