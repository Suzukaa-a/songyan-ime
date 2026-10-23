import Foundation

/// Non-blocking serial writer for the on-disk diagnostic log.
///
/// Synchronous `FileHandle` / `Data.write` on the MainActor blocks the main thread even for
/// one log line. The main thread only updates in-memory state; disk writes are queued on a
/// dedicated serial queue.
///
///  - `append` only enqueues on the calling thread (non-blocking); the write happens on the queue.
///  - The serial queue keeps write order equal to call order and does not contend with the main thread.
///  - `sink` is injectable so tests can check "off the main thread, in order, without blocking the caller".
public final class DiskLogWriter: Sendable {
    /// The actual write action (line, fileURL).
    public typealias Sink = @Sendable (String, URL) -> Void

    private let queue: DispatchQueue
    private let sink: Sink

    public init(
        label: String = "app.songyan.host.disklog",
        sink: @escaping Sink = DiskLogWriter.defaultSink
    ) {
        self.queue = DispatchQueue(label: label, qos: .utility)
        self.sink = sink
    }

    /// Appends a line asynchronously (non-blocking). Does nothing when `url` is nil.
    public func append(_ line: String, to url: URL?) {
        guard let url else { return }
        queue.async { [sink] in sink(line, url) }
    }

    public static let maximumLogBytes = 512 * 1024
    private static let maximumLineBytes = 4 * 1024

    /// Default sink: keeps the current and previous segments at up to 512 KiB each; failures are silent and never block the main thread.
    public static let defaultSink: Sink = { line, url in
        let fm = FileManager.default
        var data = Data(line.utf8.prefix(maximumLineBytes))
        data.append(0x0A)
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let previous = url.appendingPathExtension("previous")
        let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
        if size + data.count > maximumLogBytes {
            if fm.fileExists(atPath: previous.path) {
                do { try fm.removeItem(at: previous) } catch { return }
            }
            if size > maximumLogBytes {
                // Older unlimited logs must not become an unlimited rotated copy.
                do { try fm.removeItem(at: url) } catch { return }
            } else if fm.fileExists(atPath: url.path) {
                do { try fm.moveItem(at: url, to: previous) } catch {
                    // If rotation cannot rename, a truncation still enforces the cap.
                    if let handle = try? FileHandle(forWritingTo: url) {
                        do { try handle.truncate(atOffset: 0) } catch {
                            try? handle.close()
                            return
                        }
                        try? handle.close()
                    } else {
                        return
                    }
                }
            }
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else if !fm.fileExists(atPath: url.path) {
            try? data.write(to: url, options: .atomic)
        }
        for file in [url, previous] where fm.fileExists(atPath: file.path) {
            var file = file
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? file.setResourceValues(values)
        }
    }

    /// Both operations use the writer's queue, so Clear cannot race an earlier append.
    public func clear(_ url: URL?) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                guard let url else {
                    continuation.resume(returning: false)
                    return
                }
                let fm = FileManager.default
                var succeeded = true
                for file in [url, url.appendingPathExtension("previous")] where fm.fileExists(atPath: file.path) {
                    do { try fm.removeItem(at: file) } catch { succeeded = false }
                }
                continuation.resume(returning: succeeded)
            }
        }
    }

    /// A bounded view of recent diagnostics, serialized after earlier writes.
    public func tail(_ url: URL?, maximumBytes: Int = 32 * 1024) async -> String? {
        await withCheckedContinuation { continuation in
            queue.async {
                guard let url, maximumBytes > 0, let handle = try? FileHandle(forReadingFrom: url) else {
                    continuation.resume(returning: nil)
                    return
                }
                defer { try? handle.close() }
                let size = (try? handle.seekToEnd()) ?? 0
                _ = try? handle.seek(toOffset: size > UInt64(maximumBytes) ? size - UInt64(maximumBytes) : 0)
                let data = try? handle.read(upToCount: maximumBytes)
                continuation.resume(returning: data.map { String(decoding: $0, as: UTF8.self) })
            }
        }
    }

    /// Log file in the Documents directory.
    public static func documentsLogURL(named name: String) -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent(name)
    }
}
