import Darwin
import Foundation

public struct RimeLearningSnapshot: Equatable, Sendable {
    public let name: String
    public let data: Data

    public init(name: String, data: Data) {
        self.name = name
        self.data = data
    }
}

public enum RimeLearningBackupError: Error, Equatable, LocalizedError {
    case invalidSnapshot
    case identityMismatch
    case unsupported
    case backupFailed
    /// A native write was attempted and did not finish; learning data may be partly merged.
    case mergeUnverified

    public var errorDescription: String? {
        switch self {
        case .invalidSnapshot: return "The learning snapshot is invalid or exceeds the supported limits."
        case .identityMismatch: return "The learning dictionary does not belong to the current input source."
        case .unsupported: return "The current engine cannot perform learning backup or restore."
        case .backupFailed: return "The learning backup could not be completed."
        case .mergeUnverified: return "Learning restore did not finish; some learning data may have changed."
        }
    }
}

/// Identity and size facts of a `.userdb.txt` snapshot. Rows are left to librime.
struct RimeLearningDocument {
    let name: String
    let version: String
    let userID: String
    let entryCount: Int
}

enum RimeLearningFormat {
    static let maximumCount = 32
    static let maximumBytes = 4 * 1_024 * 1_024
    static let maximumTotalBytes = 8 * 1_024 * 1_024

    static func validateName(_ name: String) throws {
        let control = name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        guard !name.isEmpty, name.utf8.count <= 256, !name.hasPrefix("."), !name.contains("/"),
            !name.contains("\\"), !name.contains(".userdb"), !control,
            name == name.trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            throw RimeLearningBackupError.invalidSnapshot
        }
    }

    static func parseBatch(_ snapshots: [RimeLearningSnapshot]) throws -> [RimeLearningDocument] {
        let keys = snapshots.map { $0.name.precomposedStringWithCanonicalMapping.lowercased() }
        guard !snapshots.isEmpty, snapshots.count <= maximumCount,
            snapshots.reduce(0, { $0 + $1.data.count }) <= maximumTotalBytes,
            Set(keys).count == keys.count
        else {
            throw RimeLearningBackupError.invalidSnapshot
        }
        return try snapshots.map(parse)
    }

    static func parse(_ snapshot: RimeLearningSnapshot) throws -> RimeLearningDocument {
        try validateName(snapshot.name)
        guard !snapshot.data.isEmpty, snapshot.data.count <= maximumBytes,
            let text = String(data: snapshot.data, encoding: .utf8)
        else {
            throw RimeLearningBackupError.invalidSnapshot
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first == "# Rime user dictionary" else { throw RimeLearningBackupError.invalidSnapshot }
        var metadata: [String: String] = [:]
        var entryCount = 0
        for line in lines.dropFirst() {
            if line.hasPrefix("#@") {
                let pair = line.dropFirst(2).split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2, !pair[1].isEmpty, pair[1].utf8.count <= 256,
                    metadata.updateValue(String(pair[1]), forKey: String(pair[0])) == nil
                else {
                    throw RimeLearningBackupError.invalidSnapshot
                }
            } else if !line.isEmpty, !line.hasPrefix("#") {
                entryCount += 1
            }
        }
        guard metadata["/db_type"] == "userdb", let name = metadata["/db_name"],
            Data(name.utf8) == Data(snapshot.name.utf8),
            let version = metadata["/rime_version"], let userID = metadata["/user_id"]
        else {
            throw RimeLearningBackupError.identityMismatch
        }
        return RimeLearningDocument(name: name, version: version, userID: userID, entryCount: entryCount)
    }
}

/// Sets the existing sync-folder snapshot of a dictionary aside while a backup overwrites it,
/// so a failed run leaves the user's previous snapshot where it was.
struct RimeLearningSnapshotFiles {
    let directory: URL

    func target(_ name: String) -> URL { directory.appendingPathComponent(name + ".userdb.txt") }
    private func prior(_ name: String) -> URL { directory.appendingPathComponent(name + ".userdb.txt.prior") }

    /// A leftover `.prior` file from an interrupted run is the real previous snapshot.
    func setAside(_ name: String) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: prior(name).path) {
            try move(prior(name), to: target(name))
        }
        if fileManager.fileExists(atPath: target(name).path) {
            try move(target(name), to: prior(name))
        }
    }

    func settle(_ name: String, keepNew: Bool) throws {
        guard FileManager.default.fileExists(atPath: prior(name).path) else { return }
        if keepNew {
            try FileManager.default.removeItem(at: prior(name))
        } else {
            try move(prior(name), to: target(name))
        }
    }

    private func move(_ source: URL, to destination: URL) throws {
        guard Darwin.rename(source.path, destination.path) == 0 else { throw RimeLearningBackupError.backupFailed }
    }
}

#if canImport(RimeKit)
    import RimeKit
    import RimeLeversSupport

    /// Only invoked on RimeEngine's process queue after all sessions have been released.
    final class RimeLearningNative {
        let api: UnsafeMutablePointer<RimeApi>
        private let user: URL
        let declaredNames: Set<String>
        private let version: String

        static func provided<T, F>(_ pointer: UnsafeMutablePointer<T>, _ key: KeyPath<T, F?>) throws -> F {
            let payload = UnsafeRawPointer(pointer).load(as: Int32.self)
            guard payload >= 0, let offset = MemoryLayout<T>.offset(of: key),
                offset + MemoryLayout<F?>.size <= Int(payload) + MemoryLayout<Int32>.size,
                let function = pointer.pointee[keyPath: key]
            else { throw RimeLearningBackupError.unsupported }
            return function
        }

        static func cString(_ pointer: UnsafePointer<CChar>?, limit: Int = 256) throws -> String {
            guard let pointer, strnlen(pointer, limit + 1) <= limit,
                let value = String(validatingCString: pointer)
            else { throw RimeLearningBackupError.unsupported }
            return value
        }

        init(api: UnsafeMutablePointer<RimeApi>, user: URL) throws {
            self.api = api
            self.user = user.standardizedFileURL
            guard rls_available() != 0 else { throw RimeLearningBackupError.unsupported }
            let getVersion = try Self.provided(api, \.get_version)
            version = try Self.cString(getVersion(), limit: 128)
            guard version == "1.17.0" else { throw RimeLearningBackupError.unsupported }
            declaredNames = try Self.dictionaryDeclarations(api)
        }

        private static func dictionaryDeclarations(_ api: UnsafeMutablePointer<RimeApi>) throws -> Set<String> {
            let getList = try provided(api, \.get_schema_list)
            let freeList = try provided(api, \.free_schema_list)
            let open = try provided(api, \.schema_open)
            let close = try provided(api, \.config_close)
            let scalar = try provided(api, \.config_get_cstring)
            let getBool = try provided(api, \.config_get_bool)
            let begin = try provided(api, \.config_begin_list)
            let next = try provided(api, \.config_next)
            let end = try provided(api, \.config_end)
            var schemas = RimeSchemaList()
            guard getList(&schemas) != 0 else { throw RimeLearningBackupError.unsupported }
            defer { freeList(&schemas) }
            guard schemas.size > 0, schemas.size <= 64, let items = schemas.list else {
                throw RimeLearningBackupError.unsupported
            }
            var pending = try (0..<Int(schemas.size)).map { try cString(items[$0].schema_id) }
            var seen = Set<String>(), names = Set<String>()
            while let id = pending.popLast() {
                guard seen.insert(id).inserted else { continue }
                guard seen.count <= 64 else { throw RimeLearningBackupError.unsupported }
                var config = RimeConfig()
                guard id.withCString({ open($0, &config) }) != 0 else { throw RimeLearningBackupError.unsupported }
                defer { _ = close(&config) }
                func string(_ key: String) throws -> String? {
                    guard let pointer = key.withCString({ scalar(&config, $0) }) else { return nil }
                    return try cString(pointer)
                }
                func list(_ key: String) throws -> [String] {
                    var iterator = RimeConfigIterator()
                    guard key.withCString({ begin(&iterator, &config, $0) }) != 0 else { return [] }
                    defer { end(&iterator) }
                    var values: [String] = []
                    while next(&iterator) != 0 {
                        guard values.count < 128, let path = iterator.path,
                            let value = scalar(&config, path)
                        else { throw RimeLearningBackupError.unsupported }
                        values.append(try cString(value))
                    }
                    return values
                }
                pending.append(contentsOf: try list("schema/dependencies"))
                for translator in try list("engine/translators") {
                    let pieces = translator.split(separator: "@", omittingEmptySubsequences: false)
                    guard let component = pieces.first,
                        component == "script_translator" || component == "table_translator"
                    else { continue }
                    guard pieces.count <= 2, pieces.last?.isEmpty == false else {
                        throw RimeLearningBackupError.unsupported
                    }
                    let namespace = pieces.count == 2 ? String(pieces[1]) : "translator"
                    var enabled: Int32 = 1
                    let hasEnabled = (namespace + "/enable_user_dict").withCString { getBool(&config, $0, &enabled) }
                    if hasEnabled != 0 && enabled == 0 { continue }
                    if let dbClass = try string(namespace + "/db_class"), dbClass != "userdb" { continue }
                    let name: String
                    if let explicit = try string(namespace + "/user_dict") {
                        name = explicit
                    } else if let dictionary = try string(namespace + "/dictionary") {
                        name = String(dictionary.split(separator: ".", omittingEmptySubsequences: false).first ?? "")
                    } else {
                        throw RimeLearningBackupError.unsupported
                    }
                    try RimeLearningFormat.validateName(name)
                    names.insert(name)
                }
            }
            guard names.count <= RimeLearningFormat.maximumCount else { throw RimeLearningBackupError.unsupported }
            return names
        }

        func validate(_ snapshots: [RimeLearningSnapshot]) throws -> [RimeLearningDocument] {
            let documents = try RimeLearningFormat.parseBatch(snapshots)
            for document in documents {
                guard declaredNames.contains(document.name), document.version == version else {
                    throw RimeLearningBackupError.identityMismatch
                }
            }
            return documents
        }

        private func prepareSyncDirectory() throws -> URL {
            let sync = try Self.provided(api, \.get_user_data_sync_dir)
            guard rls_prepare_installation() != 0 else { throw RimeLearningBackupError.backupFailed }
            var buffer = [CChar](repeating: 0, count: 4_096)
            sync(&buffer, buffer.count)
            guard buffer.contains(0) else { throw RimeLearningBackupError.backupFailed }
            let path = try buffer.withUnsafeBufferPointer { try Self.cString($0.baseAddress, limit: 4_095) }
            guard path.hasPrefix("/") else { throw RimeLearningBackupError.backupFailed }
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }

        /// Declared dictionaries that already have learning data on disk.
        private func namesOnDisk() throws -> [String] {
            var iterator: UnsafeMutableRawPointer?
            guard rls_user_dict_list_create(&iterator) != 0 else { throw RimeLearningBackupError.backupFailed }
            defer { rls_user_dict_list_destroy(iterator) }
            var names: [String] = []
            while let pointer = rls_user_dict_list_next(iterator) {
                let name = try Self.cString(pointer)
                if declaredNames.contains(name) { names.append(name) }
            }
            return names.sorted()
        }

        func backupAll() throws -> [RimeLearningSnapshot] {
            let files = RimeLearningSnapshotFiles(directory: try prepareSyncDirectory())
            var setAside: [String] = []
            do {
                var snapshots: [RimeLearningSnapshot] = []
                var total = 0
                for name in try namesOnDisk() {
                    try files.setAside(name)
                    setAside.append(name)
                    guard name.withCString({ rls_backup_user_dict($0) }) != 0 else {
                        throw RimeLearningBackupError.backupFailed
                    }
                    let size =
                        try FileManager.default.attributesOfItem(atPath: files.target(name).path)[.size] as? Int ?? 0
                    total += size
                    guard size > 0, size <= RimeLearningFormat.maximumBytes,
                        total <= RimeLearningFormat.maximumTotalBytes
                    else { throw RimeLearningBackupError.backupFailed }
                    let snapshot = RimeLearningSnapshot(name: name, data: try Data(contentsOf: files.target(name)))
                    guard try RimeLearningFormat.parse(snapshot).version == version else {
                        throw RimeLearningBackupError.backupFailed
                    }
                    snapshots.append(snapshot)
                }
                for name in setAside { try files.settle(name, keepNew: true) }
                return snapshots
            } catch {
                for name in setAside { try? files.settle(name, keepNew: false) }
                if let known = error as? RimeLearningBackupError { throw known }
                throw RimeLearningBackupError.backupFailed
            }
        }

        /// Merges the snapshots with librime's own restore. The caller keeps a safety backup beforehand.
        func restore(_ snapshots: [RimeLearningSnapshot], documents: [RimeLearningDocument]) throws {
            _ = try prepareSyncDirectory()
            let staging = user.appendingPathComponent("learning-backup-work", isDirectory: true)
            try? FileManager.default.removeItem(at: staging)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            var staged: [URL] = []
            for (index, snapshot) in snapshots.enumerated() where documents[index].entryCount > 0 {
                let file = staging.appendingPathComponent("incoming-\(index).userdb.txt")
                try snapshot.data.write(to: file, options: .atomic)
                staged.append(file)
            }
            for file in staged {
                guard file.path.withCString({ rls_restore_user_dict($0) }) != 0 else {
                    throw RimeLearningBackupError.mergeUnverified
                }
            }
        }
    }
#endif
