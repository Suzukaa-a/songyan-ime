import CryptoKit
import Darwin
import Foundation

extension SHA256Digest {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

/// The one lowercase-hex SHA-256 helper of the install pipeline.
func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).hex }

/// Size-capped read of a user-imported file. Symlinks are followed (Files providers use them);
/// only regular files are accepted, so a FIFO or directory is rejected before it is opened.
final class BoundedLocalFile {
    private let input: FileHandle
    private let maximumBytes: Int
    let size: Int

    init(_ url: URL, maximumBytes: Int) throws {
        guard url.isFileURL, maximumBytes >= 0 else {
            throw RecipeInstallError.invalidResource("本地文件路径或大小限制无效")
        }
        let resolved = url.resolvingSymlinksInPath()
        let values = try resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let fileSize = values.fileSize, fileSize <= maximumBytes else {
            throw RecipeInstallError.invalidResource("文件类型不支持或文件过大：\(url.lastPathComponent)")
        }
        input = try FileHandle(forReadingFrom: resolved)
        size = fileSize
        self.maximumBytes = maximumBytes
    }

    /// The consumer never receives more than the budget, even if the file grows while reading.
    func consume(_ body: (Data) throws -> Void) throws {
        var count = 0
        while try autoreleasepool(invoking: {
            try Task.checkCancellation()
            let remaining = maximumBytes - count
            let limit = remaining < RecipeResourceBudget.bufferBytes ? remaining + 1 : RecipeResourceBudget.bufferBytes
            guard let chunk = try input.read(upToCount: limit), !chunk.isEmpty else { return false }
            guard chunk.count <= remaining else { throw RecipeInstallError.invalidResource("文件超过大小限制") }
            count += chunk.count
            try body(chunk)
            return true
        }) {}
    }

    func readPrefix(_ count: Int) throws -> Data {
        try Task.checkCancellation()
        return try input.read(upToCount: min(max(count, 0), size)) ?? Data()
    }

    static func read(_ url: URL, maximumBytes: Int) throws -> Data {
        let file = try BoundedLocalFile(url, maximumBytes: maximumBytes)
        var data = Data()
        data.reserveCapacity(min(file.size, RecipeResourceBudget.bufferBytes))
        try file.consume { data.append($0) }
        return data
    }

    /// Clones when the volume allows it: installed generations, staging and recipe inputs share one
    /// APFS container, so regenerating a generation must not rewrite every model byte. Anything the
    /// clone cannot do falls back to the bounded stream, which reports its own error.
    func copy(to destination: URL) throws {
        try Task.checkCancellation()
        if try clone(to: destination) { return }
        let descriptor = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var completed = false
        defer {
            try? output.close()
            if !completed { try? FileManager.default.removeItem(at: destination) }
        }
        try consume { try output.write(contentsOf: $0) }
        try output.synchronize()
        completed = true
    }

    /// Clones the descriptor opened (and type-checked) in `init`, so the checked file is the one
    /// cloned. The clone is a point-in-time copy; its size is re-checked against the budget because
    /// the file may have grown since `init`. Same owner-only mode and durability as the stream path.
    private func clone(to destination: URL) throws -> Bool {
        guard fclonefileat(input.fileDescriptor, AT_FDCWD, destination.path, 0) == 0 else { return false }
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: destination) } }
        let descriptor = open(destination.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size <= maximumBytes else {
            throw RecipeInstallError.invalidResource("文件超过大小限制")
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0, fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        completed = true
        return true
    }
}
