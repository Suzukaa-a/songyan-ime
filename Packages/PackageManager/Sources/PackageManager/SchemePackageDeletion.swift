import Darwin
import Foundation
import KeyboardCore

/// Deleting a user-installed scheme package, made crash-safe by **step ordering** alone:
///
///   1. `prune`: the caller atomically removes the scheme from the published `active.json`;
///   2. rename the package directory into the trash directory (same volume, atomic);
///   3. delete the trash entry.
///
/// A kill after (1) leaves an installed but unpublished package; after (2) or during (3) it leaves
/// a trash entry that nothing references. `active.json` therefore never points at a missing
/// directory, and a still-published scheme is never touched. `purgeTrash` removes leftovers at launch.
public enum SchemePackageDeletion {

    public struct Layout: Sendable {
        /// Install slot root (`SchemePackages`).
        public let storeRoot: URL
        /// Trash root. Must be on the same volume as `storeRoot` so the rename is atomic.
        public let trashRoot: URL

        public init(storeRoot: URL, trashRoot: URL) {
            self.storeRoot = storeRoot
            self.trashRoot = trashRoot
        }

        /// Sibling of the install slot root: same volume by construction.
        public init(storeRoot: URL) {
            self.storeRoot = storeRoot
            self.trashRoot = storeRoot.deletingLastPathComponent()
                .appendingPathComponent("SchemePackageTrash", isDirectory: true)
        }
    }

    public enum Failure: Error, LocalizedError, Equatable {
        /// Target is not an exact package directory under storeRoot (escape, symlink, not a directory...).
        case invalidTarget(String)
        /// The trash directory cannot be created. Nothing was changed.
        case trashUnavailable(String)
        /// The scheme was already unpublished but the directory could not be moved into the trash.
        case moveFailed(String)

        public var errorDescription: String? {
            switch self {
            case .invalidTarget(let detail): return "输入方案路径无效：\(detail)"
            case .trashUnavailable(let detail): return "删除暂存区不可用：\(detail)"
            case .moveFailed: return "删除未完成，请返回列表核对后再操作。"
            }
        }

        /// Ordinary UI copy never includes a raw file path.
        public var userFacingDescription: String {
            switch self {
            case .invalidTarget:
                return "无法确认要删除的输入方案，未作任何更改。请返回列表后重试。"
            case .trashUnavailable:
                return "暂时无法删除这个输入方案，未作任何更改。请稍后重试。"
            case .moveFailed:
                return "删除未完成。请返回列表核对后再操作。"
            }
        }

        public var failureState: OperationFailureState {
            switch self {
            case .invalidTarget, .trashUnavailable: return .nothingCommitted
            case .moveFailed: return .unknown
            }
        }
    }

    /// A non-nil `leftoverTrash` means the final delete did not finish; the entry is unreferenced
    /// and is removed by the next `purgeTrash`.
    public struct Outcome: Sendable {
        public let packageID: String
        public let leftoverTrash: URL?
    }

    /// Pure-string package identity check (no disk access).
    public static func validatePackageID(_ packageID: String) throws {
        guard PublishedKeyboardSourceKey.validPackageID(packageID) else {
            throw Failure.invalidTarget("输入方案包标识无效")
        }
    }

    /// Whether the target is a real directory directly under `storeRoot` (symlinks not followed).
    public static func validateTarget(
        packageID: String,
        layout: Layout,
        values: URLResourceValues?
    ) throws -> URL {
        try validatePackageID(packageID)
        let root = layout.storeRoot.standardizedFileURL
        let target = root.appendingPathComponent(packageID, isDirectory: true).standardizedFileURL
        guard target.deletingLastPathComponent().standardizedFileURL.path == root.path else {
            throw Failure.invalidTarget("目标不在安装目录内")
        }
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let resolvedTarget = target.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedTarget.deletingLastPathComponent().path == resolvedRoot.path else {
            throw Failure.invalidTarget("目标指向安装目录之外")
        }
        guard values?.isSymbolicLink != true, values?.isDirectory == true else {
            throw Failure.invalidTarget("目标不是安装目录")
        }
        return target
    }

    /// Deletes one package. `prune` must atomically remove the scheme from the published state
    /// and throw if it could not; when it throws, the directory is left untouched.
    public static func delete(
        packageID: String,
        layout: Layout,
        prune: () async throws -> Void,
        fileManager fm: FileManager = .default
    ) async throws -> Outcome {
        try validatePackageID(packageID)
        let target = layout.storeRoot.appendingPathComponent(packageID, isDirectory: true).standardizedFileURL
        let values = try? target.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        _ = try validateTarget(packageID: packageID, layout: layout, values: values)
        guard fm.fileExists(atPath: target.path) else {
            throw Failure.invalidTarget("安装目录不存在")
        }
        let trashRoot = layout.trashRoot.standardizedFileURL
        do { try ensureRealDirectory(trashRoot, fm: fm) } catch {
            throw Failure.trashUnavailable(error.localizedDescription)
        }

        try await prune()

        let trashed = trashRoot.appendingPathComponent("\(packageID)-\(UUID().uuidString)", isDirectory: true)
        do { try fm.moveItem(at: target, to: trashed) } catch {
            throw Failure.moveFailed(error.localizedDescription)
        }
        try? fm.removeItem(at: trashed)
        let leftover = fm.fileExists(atPath: trashed.path) ? trashed : nil
        return Outcome(packageID: packageID, leftoverTrash: leftover)
    }

    /// Removes every trash entry. Entries only exist after the scheme was unpublished, so nothing
    /// in the trash is referenced. Returns developer diagnostics for entries that could not be removed.
    @discardableResult
    public static func purgeTrash(layout: Layout, fileManager fm: FileManager = .default) -> [String] {
        let trashRoot = layout.trashRoot.standardizedFileURL
        var metadata = stat()
        guard trashRoot.path.withCString({ lstat($0, &metadata) }) == 0,
            metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
        else { return [] }
        guard let entries = try? fm.contentsOfDirectory(at: trashRoot, includingPropertiesForKeys: nil) else {
            return ["trash-list-failed"]
        }
        var failures: [String] = []
        for entry in entries {
            do { try fm.removeItem(at: entry) } catch {
                failures.append("trash-remove-failed: \(entry.lastPathComponent) \(error.localizedDescription)")
            }
        }
        return failures
    }

    /// The trash root must be a real directory: `fileExists` follows symlinks.
    static func ensureRealDirectory(_ root: URL, fm: FileManager = .default) throws {
        var metadata = stat()
        if root.path.withCString({ lstat($0, &metadata) }) == 0 {
            guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
                throw CocoaError(.fileWriteFileExists)
            }
            return
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }
}
