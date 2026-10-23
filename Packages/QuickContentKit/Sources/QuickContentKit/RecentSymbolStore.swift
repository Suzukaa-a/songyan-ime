import Foundation

// MARK: - Recent symbols (dedupe + MRU + persistence; keep old file on failure)

/// Recently used symbols. The same text is deduped and moved to the front (MRU); the
/// default limit is 20. Persisted to an injected directory:
///   - `recent.json` is the current value; before each successful save the previous
///     content is backed up in full to `recent-last.json`.
///   - Reads: a corrupt current file falls back to the backup; if that is corrupt too the
///     result is empty (the panel shows "no recents"), never dropping recoverable data.
///   - Write failures (disk full / permissions): the old file is left untouched and the
///     new in-memory list is returned; callers observe the failure via `saveError`.
///
/// Entries are the **symbol text** (the string inserted into the host), not item ids, so
/// id changes in a user's custom catalog don't invalidate the recents list.
public struct RecentSymbolStore: Sendable {
    public let directory: URL
    public let limit: Int
    public init(directory: URL, limit: Int = 20) {
        self.directory = directory
        self.limit = max(1, min(limit, 100))
    }

    private var activeFile: URL { directory.appendingPathComponent("recent.json") }
    private var backupFile: URL { directory.appendingPathComponent("recent-last.json") }

    /// Reads the current list (current file, else backup, else empty; writes nothing).
    /// A missing file is the empty state; corruption, permission or oversize errors are
    /// reported through the callback even when the backup recovers the data.
    public func read(readError: ((Error) -> Void)? = nil) -> [String] {
        if let texts = decodeFile(activeFile, readError: readError) { return texts }
        if let texts = decodeFile(backupFile, readError: readError) { return texts }
        return []
    }

    /// Records a use: dedupes the text to the front, trims to `limit`, saves atomically
    /// (backing up the old value first).
    /// - Returns: (updated list, save error). On a failed save the old file is kept and
    ///   the returned list is the in-memory expected value for immediate display.
    @discardableResult
    public func record(_ text: String) -> (texts: [String], saveError: Error?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (read(), nil) }
        var texts = read().filter { $0 != trimmed }
        texts.insert(trimmed, at: 0)
        if texts.count > limit { texts = Array(texts.prefix(limit)) }
        return (texts, save(texts))
    }

    /// Clears recents: protect the recoverable current value, remove the backup, then
    /// atomically commit an empty list. The current value cannot be deleted first: if
    /// removing the backup then failed, the caller must still read back the old list.
    public func clear() throws {
        let fm = FileManager.default
        if validData(activeFile) == nil, let recovered = validData(backupFile) {
            try recovered.write(to: activeFile, options: .atomic)
        }
        if fm.fileExists(atPath: backupFile.path) { try fm.removeItem(at: backupFile) }
        if fm.fileExists(atPath: activeFile.path) {
            try Data("[]".utf8).write(to: activeFile, options: .atomic)
        }
    }

    private static let maximumBytes = 16 * 1024

    /// Atomic save: validate the new value, back up the valid current file atomically,
    /// then write the new value. Any failing step returns an error; a corrupt current
    /// file never overwrites a still-recoverable backup.
    @discardableResult
    public func save(_ texts: [String]) -> Error? {
        let fm = FileManager.default
        do {
            // Validate before touching either copy: a successful save must be readable.
            let data = try JSONEncoder().encode(texts)
            guard texts.count <= 100, data.count <= Self.maximumBytes else {
                throw SymbolCatalogError("最近使用记录超过大小限制")
            }
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            // Never replace the last good copy with a corrupt active file. Atomic
            // replacement also preserves the old backup if writing it fails.
            if let old = validData(activeFile) {
                try old.write(to: backupFile, options: .atomic)
            }
            try data.write(to: activeFile, options: .atomic)
            return nil
        } catch {
            return error
        }
    }

    private func validData(_ file: URL) -> Data? {
        try? readValidatedData(file)
    }

    private func readValidatedData(_ file: URL) throws -> Data {
        let data = try QuickContentFileReader.read(
            file, maximumBytes: Self.maximumBytes,
            sizeError: "最近使用记录超过大小限制")
        let texts = try JSONDecoder().decode([String].self, from: data)
        guard texts.count <= 100 else { throw SymbolCatalogError("最近使用记录超过数量限制") }
        return data
    }

    private func decodeFile(_ file: URL, readError: ((Error) -> Void)?) -> [String]? {
        do {
            return try JSONDecoder().decode([String].self, from: readValidatedData(file))
        } catch {
            let nsError = error as NSError
            let isMissing =
                (error as? POSIXError)?.code == .ENOENT
                || (nsError.domain == NSCocoaErrorDomain
                    && (nsError.code == NSFileReadNoSuchFileError || nsError.code == NSFileNoSuchFileError))
            if !isMissing { readError?(error) }
            return nil
        }
    }
}
