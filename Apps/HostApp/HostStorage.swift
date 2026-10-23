import Foundation
import KeyboardCore

/// Roots of the host app's private stores (never shared with the keyboard through the App Group).
enum HostStorePaths {
    static var applicationSupport: URL {
        let fm = FileManager.default
        return fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.urls(for: .documentDirectory, in: .userDomainMask).first!
    }
}

/// On-disk diagnostic log of the host app (Documents/host.log), shown under Settings > Advanced.
///
/// Callers only enqueue; `DiskLogWriter` writes on its own serial queue, so logging from the
/// main actor never blocks on file I/O.
enum HostLog {
    nonisolated static func append(_ line: String) {
        writer.append(line, to: url)
    }

    static func recent() async -> String? {
        await writer.tail(url)
    }

    static func clear() async -> Bool {
        await writer.clear(url)
    }

    private nonisolated static let writer = DiskLogWriter()
    private nonisolated static var url: URL? {
        DiskLogWriter.documentsLogURL(named: "host.log")
    }
}
