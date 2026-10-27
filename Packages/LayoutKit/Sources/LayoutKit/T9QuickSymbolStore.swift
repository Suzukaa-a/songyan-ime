import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// One explicit container URL, shared by Host and Extension. Atomic replacement
/// prevents torn reads; a shared file lock serializes slot edits.
public struct T9QuickSymbolStore: Sendable {
    /// Directory name under the App Group container.
    public static let directoryName = "KeyboardQuickSymbols"
    public static let defaultSymbols = "，。？！、…"
    public struct Snapshot: Codable, Equatable, Sendable {
        public let version: Int
        public let revision: UUID
        public let symbols: String
        public init(symbols: String) {
            version = 1
            revision = UUID()
            self.symbols = symbols
        }
    }
    public struct EditResult: Equatable, Sendable {
        public let snapshot: Snapshot
        /// A first explicit selection persists the baseline even if its text
        /// equals the displayed default. Re-selecting an already saved value
        /// makes no write and must not produce another success tick.
        public let didWrite: Bool
    }
    public let directory: URL
    public var fileURL: URL { directory.appendingPathComponent("t9-quick-symbols.json") }
    public init(directory: URL) { self.directory = directory }

    /// A missing file is the untouched default; nothing is written until the user edits.
    public func load() throws -> Snapshot {
        try readExisting() ?? Snapshot(symbols: Self.defaultSymbols)
    }

    /// Read-modify-write the latest shared value, never the caller's stale list.
    public func replaceSlot(_ index: Int, with symbol: String) throws -> Snapshot {
        try replaceSlotResult(index, with: symbol).snapshot
    }

    public func replaceSlotResult(_ index: Int, with symbol: String) throws -> EditResult {
        guard symbol.count == 1, Self.isValid(symbol) else { throw StoreError.invalidSymbols }
        return try withLock {
            let existing = try readExisting()
            let current = existing ?? Snapshot(symbols: Self.defaultSymbols)
            var values = Array(current.symbols)
            guard values.indices.contains(index), let value = symbol.first else { throw StoreError.invalidSlot }
            if values[index] == value {
                // Explicitly choosing the displayed default is still a save.
                // Only an already-persisted canonical snapshot can skip writing.
                if existing == nil { try write(current) }
                return EditResult(snapshot: current, didWrite: existing == nil)
            }
            values[index] = value
            let updated = Snapshot(symbols: String(values))
            try write(updated)
            return EditResult(snapshot: updated, didWrite: true)
        }
    }

    /// An explicit whole-list edit replaces the latest saved list under the lock.
    /// Duplicates are rejected rather than silently changing the requested order.
    public func replaceSymbolsResult(_ symbols: String) throws -> EditResult {
        guard Self.isValid(symbols), Set(symbols).count == symbols.count else { throw StoreError.invalidSymbols }
        return try withLock {
            let existing = try readExisting()
            if let existing, existing.symbols == symbols {
                return EditResult(snapshot: existing, didWrite: false)
            }
            let updated = Snapshot(symbols: symbols)
            try write(updated)
            return EditResult(snapshot: updated, didWrite: true)
        }
    }

    /// Grapheme count does not bound Unicode storage: one combining-character
    /// sequence can contain arbitrarily many bytes. Bound the whole JSON too.
    public static let maximumFileBytes = 16 * 1024

    public static func isValid(_ symbols: String) -> Bool {
        !symbols.isEmpty && symbols.utf8.count <= maximumFileBytes && symbols.count <= 12
            && !symbols.unicodeScalars.contains {
                CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
            }
    }

    private func readExisting() throws -> Snapshot? {
        let data: Data
        do {
            data = try LayoutResourceBudget.read(fileURL, maximumBytes: Self.maximumFileBytes)
        } catch let error as POSIXError where error.code == .ENOENT {
            return nil
        }
        let value = try JSONDecoder().decode(Snapshot.self, from: data)
        guard value.version == 1, Self.isValid(value.symbols) else { throw StoreError.invalidSymbols }
        return value
    }
    private func write(_ value: Snapshot) throws {
        guard value.version == 1, Self.isValid(value.symbols) else { throw StoreError.invalidSymbols }
        let data = try JSONEncoder().encode(value)
        guard data.count <= Self.maximumFileBytes else { throw StoreError.invalidSymbols }
        try data.write(to: fileURL, options: .atomic)
    }
    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(
            directory.appendingPathComponent("t9-quick-symbols.lock").path,
            O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw StoreError.lockUnavailable }
        defer { close(fd) }
        var facts = stat()
        guard fstat(fd, &facts) == 0, facts.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            flock(fd, LOCK_EX) == 0
        else { throw StoreError.lockUnavailable }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
    public enum StoreError: Error { case invalidSymbols, invalidSlot, lockUnavailable }
}
