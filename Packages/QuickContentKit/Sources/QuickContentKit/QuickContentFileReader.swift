import Foundation

/// Reads a user-imported file within a byte budget: regular files only (symlinks followed),
/// so a FIFO or directory is rejected before it is opened.
enum QuickContentFileReader {
    static func read(_ url: URL, maximumBytes: Int, sizeError: String) throws -> Data {
        guard url.isFileURL else { throw SymbolCatalogError("需要本地普通文件") }
        let resolved = url.resolvingSymlinksInPath()
        let values = try resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw SymbolCatalogError("需要普通文件") }
        guard let size = values.fileSize, size <= maximumBytes else { throw SymbolCatalogError(sizeError) }
        return try Data(contentsOf: resolved)
    }
}
