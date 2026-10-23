import Foundation

// MARK: - Symbol catalog store (import/export/active read; keep old file on failure)

/// Catalog store, same discipline as SkinStore/CandidateBarStore:
///   - The user directory is injected by the host (App Group container
///     `KeyboardSymbols/` recommended; the host writes, the extension reads); this type
///     does not guess paths.
///   - Import validates the whole file strictly and only then writes `catalog.json`
///     atomically; any failure (format / unknown fields / oversize) throws and leaves the
///     old file untouched.
///   - `loadActive()` prefers the custom catalog and falls back to the bundled default
///     when it is missing or corrupt (the default is read-only inside the package).
///
/// Threading: no internal lock; at most one process should write a directory at a time
/// (the keyboard extension only reads, the main app is the single writer, as for layouts/skins).
public struct SymbolCatalogStore: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    /// Recommended subdirectory name in the shared host container (relative to the App Group root).
    public static let sharedDirectoryName = "KeyboardSymbols"

    private var activeFile: URL { directory.appendingPathComponent("catalog.json") }

    /// Imports a custom catalog JSON. Writes to disk only if every item validates; on
    /// failure it throws and the old catalog stays.
    /// - Returns: the imported catalog.
    @discardableResult
    public func importCatalog(_ data: Data) throws -> SymbolCatalog {
        try install(SymbolCatalog.decode(data))
    }

    /// URL imports share the same byte budget as decoding, before allocating the
    /// entire file. The caller owns any security-scoped access for this duration.
    @discardableResult
    public func importCatalog(from url: URL) throws -> SymbolCatalog {
        try install(SymbolCatalog.decode(contentsOf: url))
    }

    private func install(_ catalog: SymbolCatalog) throws -> SymbolCatalog {
        let data = try catalog.encoded()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: activeFile, options: .atomic)
        return catalog
    }

    /// Deletes the custom catalog, reverting to the bundled default.
    public func removeCustomCatalog() throws {
        guard FileManager.default.fileExists(atPath: activeFile.path) else { return }
        try FileManager.default.removeItem(at: activeFile)
    }

    /// The active catalog: custom first, falling back to the bundled default when missing
    /// or corrupt (the default is read-only and cannot break).
    /// - Parameter readError: optional read error out-parameter (the UI shows "symbol catalog failed to load, using built-in").
    @discardableResult
    public func loadActive(readError: ((Error) -> Void)? = nil) -> SymbolCatalog {
        if FileManager.default.fileExists(atPath: activeFile.path) {
            do {
                return try SymbolCatalog.decode(contentsOf: activeFile)
            } catch {
                readError?(SymbolCatalogError("自定义符号目录读取失败：\(error.localizedDescription)"))
            }
        }
        // A missing bundled default is a packaging error; throwing here would break keyboard
        // rendering, so return an empty catalog and report via the callback (the panel shows
        // an empty state, never fabricated items).
        do {
            return try SymbolCatalog.bundledDefault()
        } catch {
            readError?(error)
            return SymbolCatalog(version: 1, categories: [], items: [])
        }
    }

    /// Exports the active catalog (custom or bundled default) for backup/migration.
    public func exportActive() throws -> Data {
        var readError: Error?
        let catalog = loadActive { readError = $0 }
        if let readError { throw readError }
        return try catalog.encoded()
    }

    /// Whether a custom import exists (the UI shows "custom symbol library imported").
    public var hasCustomCatalog: Bool {
        FileManager.default.fileExists(atPath: activeFile.path)
    }
}
