import CryptoKit
import Foundation
import KeyboardCore
import Yams
import ZIPFoundation

/// Explicit input contract supplied with a source package, never inferred from its brand.
/// Codes are the actual logical key events produced by the selected keyboard, not display labels.
public struct SchemeInputBinding: Codable, Equatable, Sendable {
    public let layout: String
    public let schemaID: String
    public let code: String
    public let candidate: String
    public init(layout: String, schemaID: String, code: String, candidate: String) {
        self.layout = layout
        self.schemaID = schemaID
        self.code = code
        self.candidate = candidate
    }
}

/// Optional keyboard-package.json augments, but never replaces, the Rime source files.
/// id defines the learning namespace; changing it deliberately creates an independent installation.
public struct SchemePackageDeclaration: Codable, Sendable {
    public let id: String
    public let name: String
    public let bindings: [SchemeInputBinding]
    public init(id: String, name: String, bindings: [SchemeInputBinding]) {
        self.id = id
        self.name = name
        self.bindings = bindings
    }
}

public struct PreparedSchemeImport: Sendable {
    /// Original selected package bytes, before generated default/product metadata. Recipe planning
    /// must use this snapshot so a generated fallback cannot satisfy a missing install_files source.
    public let sourceFiles: [String: Data]
    public let fileResources: [String: RecipeFileResource]
    public var sourceFileResources: [String: RecipeFileResource] { fileResources }
    public let declaration: SchemePackageDeclaration
    public let manifest: RecipeManifest
    public let schemaIDs: [String]
    public let resourceBytes: Int
    public let diagnostics: [String]
    private let bytes: [String: Data]
    /// Source-declared grammar is required for this unchanged installation. Runtime
    /// validation remains authoritative for includes/patches and actual model loading.
    public var requiredModelPaths: [String] { SchemeGrammarRequirements.paths(in: bytes) }

    /// The exact bytes this prepared import will write for `path`, including generated
    /// products such as the standard telephone-key companion. Read-only.
    public func preparedBytes(for path: String) -> Data? { bytes[path] }

    public func preparingModels(_ supplied: [String: RecipeFileResource]) throws -> PreparedSchemeImport {
        var models = fileResources
        for path in requiredModelPaths {
            guard let model = supplied[path] ?? models[path] else {
                throw RecipeInstallError.missingGrammarModels(requiredModelPaths)
            }
            models[path] = model
        }
        try RecipeResourceBudget.validate(bytes.mapValues(\.count).merging(models.mapValues(\.size)) { _, new in new })
        let records = Set(bytes.keys).union(models.keys).sorted().map { path in
            if let model = models[path] {
                return RecipeManifest.File(path: path, sha256: model.sha256, size: model.size)
            }
            return RecipeManifest.File(
                path: path, sha256: SchemeSourceCheck.hash(bytes[path]!), size: bytes[path]!.count)
        }
        let revision = String(
            SchemeSourceCheck.hash(Data(records.map { $0.path + $0.sha256 }.joined().utf8)).prefix(40))
        let updated = RecipeManifest(
            id: manifest.id, repository: manifest.repository, revision: revision,
            recipePath: manifest.recipePath, license: manifest.license, schemaID: manifest.schemaID,
            requiredComponents: manifest.requiredComponents, files: records, origin: manifest.origin)
        return PreparedSchemeImport(
            declaration: declaration, manifest: updated, schemaIDs: schemaIDs,
            bytes: bytes, sourceFiles: sourceFiles, fileResources: models)
    }
    fileprivate init(
        declaration: SchemePackageDeclaration, manifest: RecipeManifest,
        schemaIDs: [String], bytes: [String: Data], sourceFiles: [String: Data],
        fileResources: [String: RecipeFileResource]
    ) {
        self.declaration = declaration
        self.manifest = manifest
        self.schemaIDs = schemaIDs
        self.bytes = bytes
        resourceBytes = bytes.values.reduce(0) { $0 + $1.count } + fileResources.values.reduce(0) { $0 + $1.size }
        self.fileResources = fileResources
        self.sourceFiles = sourceFiles
        diagnostics = SchemeGrammarRequirements.discover(in: bytes).diagnostics
    }
    fileprivate func read(_ path: String) throws -> Data {
        guard let data = bytes[path] else { throw RecipeInstallError.invalidResource(path) }
        return data
    }

    /// Keep the installation's learning identity when the user explicitly updates it.
    /// A package with its own different identity must instead be imported separately.
    public func updatingInstallation(id: String, name: String) throws -> PreparedSchemeImport {
        if let data = sourceFiles[InstalledPackageLayout.keyboardPackageFile] {
            let declared = try JSONDecoder().decode(SchemePackageDeclaration.self, from: data)
            guard declared.id == id else {
                throw RecipeInstallError.invalidManifest("所选文件属于另一个输入方案，请从「导入方案」添加。")
            }
        }
        let declaration = SchemePackageDeclaration(id: id, name: name, bindings: declaration.bindings)
        var updated = bytes
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        updated[InstalledPackageLayout.keyboardPackageFile] = try encoder.encode(declaration)
        let records = Set(updated.keys).union(fileResources.keys).sorted().map { path in
            if let file = fileResources[path] {
                return RecipeManifest.File(path: path, sha256: file.sha256, size: file.size)
            }
            let data = updated[path]!
            return RecipeManifest.File(path: path, sha256: SchemeSourceCheck.hash(data), size: data.count)
        }
        let revision = String(
            SchemeSourceCheck.hash(Data(records.map { $0.path + $0.sha256 }.joined().utf8)).prefix(40))
        let updatedManifest = RecipeManifest(
            id: id, repository: manifest.repository, revision: revision,
            recipePath: manifest.recipePath, license: manifest.license, schemaID: manifest.schemaID,
            requiredComponents: manifest.requiredComponents, files: records, origin: .userScheme)
        return PreparedSchemeImport(
            declaration: declaration, manifest: updatedManifest,
            schemaIDs: schemaIDs, bytes: updated, sourceFiles: sourceFiles, fileResources: fileResources)
    }
}

public extension RecipePackageManager {
    nonisolated func prepareSchemeArchive(_ url: URL) throws -> PreparedSchemeImport {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("scheme-zip-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let snapshot = workspace.appendingPathComponent("source.zip")
        try BoundedLocalFile(url, maximumBytes: RecipeResourceBudget.archiveFile).copy(to: snapshot)
        let archive = try Archive(url: snapshot, accessMode: .read)
        let staging = workspace.appendingPathComponent("extracted")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        var paths = Set<String>()
        var entries: [(entry: Entry, path: String)] = []
        for entry in archive {
            let path = entry.path.hasSuffix("/") ? String(entry.path.dropLast()) : entry.path
            if SchemeSourceCheck.isFinderMetadata(path) { continue }
            guard SchemeSourceCheck.safe(path), paths.insert(path.lowercased()).inserted,
                entry.type != .symlink, paths.count <= 2000
            else { throw RecipeInstallError.invalidResource("ZIP 文件路径无效或包含符号链接：\(entry.path)") }
            entries.append((entry, path))
        }
        // Detect the single enclosing repository before applying resource budgets.
        // Classification uses the package-relative path; extraction still uses the
        // separately validated physical path and preserves every subdirectory.
        let roots = Set(entries.compactMap { $0.path.split(separator: "/").first.map(String.init) })
        let wrapper =
            roots.count == 1 && entries.allSatisfy({ $0.entry.type == .directory || $0.path.contains("/") })
            ? roots.first : nil
        var sizes: [String: Int] = [:]
        for (entry, path) in entries {
            let logicalPath = wrapper.map { String(path.dropFirst($0.count + 1)) } ?? path
            guard entry.uncompressedSize <= UInt64(RecipeResourceBudget.maximumFileBytes(logicalPath)) else {
                throw RecipeInstallError.invalidResource("ZIP 解压后大小超过限制")
            }
            if entry.type != .directory { sizes[logicalPath] = Int(entry.uncompressedSize) }
            try RecipeResourceBudget.validate(sizes)
            let destination = staging.appendingPathComponent(path)
            if entry.type == .directory {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                    throw RecipeInstallError.invalidResource(path)
                }
                let output = try FileHandle(forWritingTo: destination)
                defer { try? output.close() }
                var count = 0
                let checksum = try archive.extract(entry) { chunk in
                    try Task.checkCancellation()
                    count += chunk.count
                    guard UInt64(count) <= entry.uncompressedSize else {
                        throw RecipeInstallError.invalidResource("ZIP 实际解压大小超出文件声明：\(path)")
                    }
                    try output.write(contentsOf: chunk)
                }
                guard checksum == entry.checksum, UInt64(count) == entry.uncompressedSize else {
                    throw RecipeInstallError.invalidResource("ZIP 文件校验失败：\(path)")
                }
                try output.synchronize()
            }
        }
        let root = wrapper.map { staging.appendingPathComponent($0) } ?? staging
        return try prepareSchemeImport(directory: root)
    }
    /// A complete directory selected by the user. Symlinks and user databases are never imported.
    /// ZIPs must first be extracted by the user; no shell/plum script is executed.
    nonisolated func prepareSchemeImport(directory: URL, declaration: SchemePackageDeclaration? = nil) throws
        -> PreparedSchemeImport
    {
        let fm = FileManager.default
        let info = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard info.isDirectory == true, info.isSymbolicLink != true else {
            throw RecipeInstallError.invalidResource("请选择解压后的完整输入方案目录；ZIP 文件请先在「文件」App 中解压")
        }
        var files: [DictionaryImportFile] = []
        var visited = 0
        func visit(_ url: URL, prefix: String) throws {
            for child in try fm.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            {
                let name = child.lastPathComponent
                if name == ".git" || SchemeSourceCheck.isFinderMetadata(prefix + name) { continue }
                if name == "build" {
                    let info = try child.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                    guard info.isSymbolicLink != true, info.isDirectory == true else {
                        throw RecipeInstallError.invalidResource(child.path)
                    }
                    let placeholder = child.appendingPathComponent(".gitkeep")
                    if fm.fileExists(atPath: placeholder.path) {
                        let value = try placeholder.resourceValues(forKeys: [
                            .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey,
                        ])
                        guard value.isSymbolicLink != true, value.isRegularFile == true, value.fileSize == 0 else {
                            throw RecipeInstallError.invalidResource("build/.gitkeep 必须为空文件")
                        }
                        files.append(DictionaryImportFile(path: prefix + "build/.gitkeep", location: placeholder))
                    }
                    continue
                }
                visited += 1
                guard visited <= 2000, prefix.split(separator: "/").count < 32 else {
                    throw RecipeInstallError.invalidResource("输入方案目录超过 2000 个文件或目录层级超过 32 层")
                }
                let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else {
                    throw RecipeInstallError.invalidResource("不支持符号链接：\(child.path)")
                }
                let path = prefix + name
                guard files.count < 2000 else { throw RecipeInstallError.invalidResource("输入方案文件超过 2000 个") }
                if values.isDirectory == true {
                    try visit(child, prefix: path + "/")
                } else {
                    files.append(DictionaryImportFile(path: path, location: child))
                }
            }
        }
        try visit(directory, prefix: "")
        return try prepareSchemeImport(files: files, declaration: declaration)
    }

    /// Multiple files retain explicit package-relative paths (including lua/, opencc/, dictionaries/).
    nonisolated func prepareSchemeImport(
        files: [DictionaryImportFile], declaration supplied: SchemePackageDeclaration? = nil
    ) throws -> PreparedSchemeImport {
        var bytes: [String: Data] = [:]
        var fileResources: [String: RecipeFileResource] = [:]
        let modelStaging = FileManager.default.temporaryDirectory
        var names = Set<String>()
        var total = 0, modelTotal = 0
        guard !files.isEmpty, files.count <= 2000 else {
            throw RecipeInstallError.invalidResource("导入的输入方案为空或文件数量超过 2000 个")
        }
        for file in files {
            guard SchemeSourceCheck.safe(file.path), names.insert(file.path.lowercased()).inserted,
                file.location.isFileURL, !file.path.contains(".userdb")
            else {
                throw RecipeInstallError.invalidResource("路径不安全、重复或包含不支持的用户数据文件：\(file.path)")
            }
            if RecipeResourceBudget.isModel(file.path) {
                fileResources[file.path] = try RecipeFileResource.snapshot(
                    from: file.location, directory: modelStaging,
                    maximumBytes: min(RecipeResourceBudget.modelFile, RecipeResourceBudget.modelTotal - modelTotal))
                modelTotal += fileResources[file.path]!.size
                try RecipeResourceBudget.validate(fileResources.mapValues(\.size))
                try Prediction.validateDatabases(in: [file.path: fileResources[file.path]!])
                continue
            }
            let data = try BoundedLocalFile.read(
                file.location,
                maximumBytes: min(RecipeResourceBudget.sourceFile, RecipeResourceBudget.sourceTotal - total))
            total += data.count
            bytes[file.path] = data
        }
        return try prepareSchemeImport(bytes: bytes, fileResources: fileResources, declaration: supplied)
    }

    /// The scheme files the app ships in its bundle, installed like an imported scheme so they
    /// share every keyboard and publication path. Only the manifest's entry schemes are taken: the
    /// bundled compact companions belong to the keyboard's offline fallback, and an installed scheme
    /// generates its own when a compact keyboard is added.
    nonisolated func prepareBundledPackage(directory: URL) throws -> PreparedSchemeImport {
        let manifest = try BoundedLocalFile.read(
            directory.appendingPathComponent("manifest.yaml"),
            maximumBytes: RecipeResourceBudget.sourceFile)
        guard let root = try BoundedYAML.load(yaml: String(decoding: manifest, as: UTF8.self)) as? [String: Any],
            let id = root["id"] as? String, let name = root["name"] as? String,
            let entries = (root["entrypoints"] as? [String: Any])?["schemas"] as? [String], !entries.isEmpty
        else {
            throw RecipeInstallError.invalidManifest("内置输入方案的说明文件无效")
        }
        var bytes: [String: Data] = [:]
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let path = file.lastPathComponent
            guard path != "manifest.yaml", path.hasSuffix(".yaml") else { continue }
            if path.hasSuffix(".schema.yaml"), !entries.contains(String(path.dropLast(12))) { continue }
            bytes[path] = try BoundedLocalFile.read(file, maximumBytes: RecipeResourceBudget.sourceFile)
        }
        guard let defaults = bytes["default.yaml"] else {
            throw RecipeInstallError.invalidManifest("内置输入方案缺少 default.yaml")
        }
        let kept = String(decoding: defaults, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let item = line.trimmingCharacters(in: .whitespaces)
                guard item.hasPrefix("- schema:") else { return true }
                return entries.contains(item.dropFirst(9).trimmingCharacters(in: .whitespaces))
            }
        bytes["default.yaml"] = Data(kept.joined(separator: "\n").utf8)
        return try prepareSchemeImport(
            bytes: bytes, fileResources: [:],
            declaration: SchemePackageDeclaration(id: id, name: name, bindings: []))
    }

    nonisolated private func prepareSchemeImport(
        bytes source: [String: Data], fileResources: [String: RecipeFileResource],
        declaration supplied: SchemePackageDeclaration?
    ) throws -> PreparedSchemeImport {
        var bytes = source
        let sourceFiles = bytes
        let declaration: SchemePackageDeclaration
        if let supplied {
            declaration = supplied
        } else if let data = bytes[InstalledPackageLayout.keyboardPackageFile] {
            declaration = try JSONDecoder().decode(SchemePackageDeclaration.self, from: data)
        } else {
            let ids = InstalledPackageLayout.topLevelSchemaFiles(in: bytes.keys).map {
                String($0.dropLast(12))
            }.sorted()
            guard let first = ids.first else {
                throw RecipeInstallError.invalidManifest("导入内容缺少根目录下的 .schema.yaml 方案文件")
            }
            let identities = bytes.mapValues(SchemeSourceCheck.hash).merging(fileResources.mapValues(\.sha256)) {
                _, new in new
            }
            let identity = identities.keys.sorted().map { $0 + identities[$0]! }.joined(separator: "\n")
            // Display name is the first schema in the source's default.yaml enabled list (same rule
            // as entry selection, e.g. rime_ice for Rime-ice), not the first file by name sorting
            // (which would name a whole source after double_pinyin's schema).
            let listed = SchemeSourceCheck.matches(
                "^\\s*-\\s*schema:\\s*[\"']?([A-Za-z0-9_.-]+)",
                String(data: bytes["default.yaml"] ?? Data(), encoding: .utf8) ?? "")
            let primary = listed.first(where: ids.contains) ?? first
            let schemaText = String(data: bytes[InstalledPackageLayout.schemaFile(primary)]!, encoding: .utf8) ?? ""
            let name =
                SchemeSourceCheck.matches("^\\s+name:\\s*[\"']?([^\"'\\r\\n#]+)", schemaText).first?
                .trimmingCharacters(in: .whitespaces) ?? primary
            // Without an explicit stable package ID, different source bytes receive separate
            // learning namespaces. Matching filenames alone cannot prove encoding compatibility.
            declaration = SchemePackageDeclaration(
                id: "scheme-" + String(SchemeSourceCheck.hash(Data(identity.utf8)).prefix(16)), name: name, bindings: []
            )
        }
        guard SchemeSourceCheck.safe(declaration.id), !declaration.id.contains("/"), !declaration.name.isEmpty,
            !declaration.id.contains("..")
        else { throw RecipeInstallError.invalidManifest("输入方案声明为空或标识无效") }
        var layouts = Set<String>()
        for binding in declaration.bindings {
            guard let layout = KeyboardLayoutKind(rawValue: binding.layout),
                layouts.insert(binding.layout).inserted, SchemeSourceCheck.safe(binding.schemaID),
                !binding.schemaID.contains("/"), !binding.code.isEmpty, !binding.candidate.isEmpty,
                binding.code.utf8.allSatisfy({
                    layout.keyFold == .phoneDigits ? (50...57).contains($0) : ((97...122).contains($0) || $0 == 39)
                }),
                bytes["\(binding.schemaID).schema.yaml"] != nil
            else {
                throw RecipeInstallError.invalidManifest("每个键盘布局的输入方式映射必须有效且唯一：\(binding.schemaID)/\(binding.layout)")
            }
            if layout.keyFold == .letterGroups, let fold = layout.compactFold,
                !Set(binding.code).isSubset(of: fold.keysSent.union(["'"]))
            {
                throw RecipeInstallError.invalidManifest("\(layout.userTitle)的验证码只能用这个布局按键实际发送的字母：\(binding.code)")
            }
        }
        let schemas = InstalledPackageLayout.topLevelSchemaFiles(in: bytes.keys).map {
            String($0.dropLast(12))
        }.sorted()
        guard !schemas.isEmpty else { throw RecipeInstallError.invalidManifest("没有可安装的输入方案") }
        try SharedRimePresets.supplement(&bytes, openCCDirectory: sharedOpenCCDirectory)
        try SchemeSourceCheck.dependencies(bytes)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if bytes[InstalledPackageLayout.keyboardPackageFile] == nil || supplied != nil {
            bytes[InstalledPackageLayout.keyboardPackageFile] = try encoder.encode(declaration)
        }
        try RecipeResourceBudget.validate(
            bytes.mapValues(\.count).merging(fileResources.mapValues(\.size)) { _, new in new })
        let records = Set(bytes.keys).union(fileResources.keys).sorted().map { path in
            if let file = fileResources[path] {
                return RecipeManifest.File(path: path, sha256: file.sha256, size: file.size)
            }
            return RecipeManifest.File(
                path: path, sha256: SchemeSourceCheck.hash(bytes[path]!), size: bytes[path]!.count)
        }
        let defaults = String(data: bytes["default.yaml"] ?? Data(), encoding: .utf8) ?? ""
        let listedSchemas = SchemeSourceCheck.matches("^\\s*-\\s*schema:\\s*[\"']?([A-Za-z0-9_.-]+)", defaults)
        let entrySchema =
            declaration.bindings.first?.schemaID ?? listedSchemas.first(where: { schemas.contains($0) }) ?? schemas[0]
        let revision = String(
            SchemeSourceCheck.hash(Data(records.map { $0.path + $0.sha256 }.joined().utf8)).prefix(40))
        let manifest = RecipeManifest(
            id: declaration.id, repository: "user/import", revision: revision,
            recipePath: InstalledPackageLayout.keyboardPackageFile, license: "用户提供的方案文件",
            schemaID: entrySchema, requiredComponents: [], files: records, origin: .userScheme)
        return PreparedSchemeImport(
            declaration: declaration, manifest: manifest, schemaIDs: schemas, bytes: bytes, sourceFiles: sourceFiles,
            fileResources: fileResources)
    }

    /// An update passes the generation it started from; the store compares it under its lock so
    /// an installation that changed meanwhile is reported instead of overwritten. `nil` skips the check.
    @discardableResult
    func installSchemeImport(
        _ prepared: PreparedSchemeImport, expectedGeneration: String? = nil,
        deploy: @escaping Deploy
    ) async throws -> InstalledRecipe {
        // `.some(nil)` would demand an empty store, so nil maps to the unchecked outer nil.
        let expected: String?? = expectedGeneration.map { Optional($0) }
        return try await installResources(
            prepared.manifest, initialUserDataURL: nil,
            deploy: { deployment in
                try InstalledRecipeSources(
                    files: prepared.sourceFiles, fileResources: prepared.sourceFileResources, receipts: []
                )
                .write(to: deployment.resourceURL.deletingLastPathComponent())
                return try await deploy(deployment)
            }, fileResources: prepared.fileResources,
            expectedActiveGeneration: expected
        ) { file in
            try prepared.read(file.path)
        }
    }
}

enum SchemeSourceCheck {
    static func expandingLocalDependencies(_ seeds: [String], inventory: [String: Data]) throws -> [String] {
        var paths = Set(seeds)
        while true {
            let selected = inventory.filter { paths.contains($0.key) }
            let local = try missingDependencies(selected, inventory: inventory).filter {
                inventory[$0] != nil && !paths.contains($0)
            }
            if local.isEmpty { return paths.sorted() }
            paths.formUnion(local)
        }
    }
    static func safe(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/")
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains(":")
                    && $0.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
            }
    }
    /// macOS Finder/Archive Utility artifacts: `__MACOSX/` resource-fork trees,
    /// `._*` AppleDouble files and `.DS_Store`.
    static func isFinderMetadata(_ path: String) -> Bool {
        let components = path.split(separator: "/")
        guard let first = components.first, let last = components.last else { return false }
        return first == "__MACOSX" || last.hasPrefix("._") || last == ".DS_Store"
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func matches(_ pattern: String, _ text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return [] }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }
    static func dependencies(_ files: [String: Data]) throws {
        let missing = try missingDependencies(files)
        guard missing.isEmpty else {
            if missing.allSatisfy({ $0.hasSuffix(".schema.yaml") }) {
                throw RecipeInstallError.missingSchemaFiles(missing)
            }
            throw RecipeInstallError.invalidResource("缺少输入方案依赖项：" + missing.joined(separator: "、"))
        }
    }
    static func missingDependencies(_ files: [String: Data], inventory: [String: Data]? = nil) throws -> [String] {
        var missing = Set<String>()
        // Source inventory can include variants which are not deployment roots.
        // Follow the actual plain schema_list when available; includes/patches
        // and absent defaults conservatively retain the full inventory scan.
        var selected: Set<String>?
        if let data = files["default.yaml"],
            let root = try? BoundedYAML.load(yaml: String(decoding: data, as: UTF8.self)) as? [String: Any]
        {
            var list = root["schema_list"] as? [[String: Any]]
            if let customData = files["default.custom.yaml"] {
                // Recognize only literal replacement patches (including the
                // frontend's archived keyboard-enable recipe). Unknown native
                // patch/include expressions retain conservative inventory checks.
                if let custom = try? BoundedYAML.load(yaml: String(decoding: customData, as: UTF8.self))
                    as? [String: Any],
                    let patch = custom["patch"] as? [String: Any], custom["__patch"] == nil,
                    let replacement = patch["schema_list"] as? [[String: Any]]
                {
                    list = replacement
                } else if let custom = try? BoundedYAML.load(yaml: String(decoding: customData, as: UTF8.self))
                    as? [String: Any],
                    custom["patch"] == nil, let patches = custom["__patch"] as? [[String: Any]],
                    patches.allSatisfy({ $0.count == 1 && $0["patch/+"] is [String: Any] })
                {
                    for item in patches {
                        if let replacement = (item["patch/+"] as? [String: Any])?["schema_list"] as? [[String: Any]] {
                            list = replacement
                        }
                    }
                } else {
                    list = nil
                }
            }
            if let list, list.allSatisfy({ $0["schema"] is String }) {
                let ids = Set(list.compactMap { $0["schema"] as? String })
                let present = ids.filter { files[$0 + InstalledPackageLayout.schemaFileSuffix] != nil }
                missing.formUnion(ids.subtracting(present).map { $0 + InstalledPackageLayout.schemaFileSuffix })
                if !present.isEmpty { selected = present }
            }
        }
        var pending = files.keys.filter {
            if let selected {
                if $0.hasSuffix(".schema.yaml") { return selected.contains(String($0.dropLast(12))) }
                if $0.hasSuffix(".dict.yaml") { return false }
                if $0.hasPrefix("lua/") { return false }
            }
            return ($0.hasSuffix(".yaml") && !$0.contains("/")) || $0 == "rime.lua"
                || ($0.hasPrefix("lua/") && $0.hasSuffix(".lua")) || ($0.hasPrefix("opencc/") && $0.hasSuffix(".json"))
        }
        var visited = Set<String>()
        func require(_ name: String) throws {
            guard safe(name) else { throw RecipeInstallError.invalidResource("依赖项路径非法：\(name)") }
            if files[name] == nil { missing.insert(name) } else if !visited.contains(name) { pending.append(name) }
        }
        func requireModule(_ module: String) throws {
            let base = "lua/" + module.replacingOccurrences(of: ".", with: "/")
            let available = inventory ?? files
            // Match package.path order: ?.lua before ?/init.lua. The actual
            // chosen file must be required AND enqueued, including init modules.
            let path =
                available[base + ".lua"] != nil
                ? base + ".lua"
                : available[base + "/init.lua"] != nil ? base + "/init.lua" : base + ".lua"
            try require(path)
        }
        while let path = pending.popLast() {
            guard visited.insert(path).inserted, let data = files[path] else { continue }
            // Repository documentation, workflows and examples are not deployed Rime configs.
            let yaml = path.hasSuffix(".yaml")
            let lua = path == "rime.lua" || (path.hasPrefix("lua/") && path.hasSuffix(".lua"))
            let opencc = path.hasPrefix("opencc/") && path.hasSuffix(".json")
            guard yaml || lua || opencc else { continue }
            guard let text = String(data: data, encoding: .utf8) else {
                throw RecipeInstallError.invalidResource("文件不是 UTF-8 编码：\(path)")
            }
            if yaml {
                // Dictionary rows following the YAML document terminator are tabular text.
                let end =
                    path.hasSuffix(".dict.yaml")
                    ? text.range(of: "(?m)^\\.\\.\\.[ \\t]*(?:#[^\\r\\n]*)?\\r?$", options: .regularExpression)?
                        .lowerBound : nil
                let source = end.map { String(text[..<$0]) } ?? text
                let root: Node?
                do { root = try BoundedYAML.compose(yaml: source) } catch let error as BoundedYAML.LimitExceeded {
                    throw RecipeInstallError.invalidResource("\(path)：\(error.localizedDescription)")
                } catch is CancellationError { throw CancellationError() } catch {
                    throw RecipeInstallError.invalidResource("YAML 格式无效：\(path)：\(error)")
                }
                // BoundedYAML already caps expansion; keep an independent budget for the walkers below.
                var budget = 2 * BoundedYAML.maximumExpandedNodes  // two walks below
                func spend() throws {
                    budget -= 1
                    guard budget >= 0 else { throw RecipeInstallError.invalidResource("\(path)：YAML 节点数量过多") }
                    if budget & 0xFFF == 0 { try Task.checkCancellation() }
                }
                func scalar(_ node: Node) -> String? { node.tag == Tag(.null) ? nil : node.string }
                func reference(_ node: Node) throws {
                    guard let value = scalar(node), let colon = value.firstIndex(of: ":"), colon != value.startIndex
                    else { return }
                    // librime ConfigCompiler::CreateReference: unqualified and :/ paths
                    // refer to the current resource; '?' marks an optional reference.
                    let name = String(value[..<colon])
                    let file = name.hasSuffix(".yaml") ? name : name + ".yaml"
                    guard safe(file) else { throw RecipeInstallError.invalidResource("依赖项路径非法：\(file)") }
                    if !value.contains("?") || files[file] != nil { try require(file) }
                }
                func visit(_ node: Node) throws {
                    try spend()
                    if let mapping = node.mapping {
                        for (key, value) in mapping {
                            switch key.string {
                            case "__include": try reference(value)
                            case "__patch":
                                if let list = value.sequence {
                                    for item in list { try reference(item) }
                                } else {
                                    try reference(value)
                                }
                            case "dictionary":
                                if let name = scalar(value), !name.isEmpty { try require(name + ".dict.yaml") }
                            case "use_preset_vocabulary":
                                if value.bool == true { try require("essay.txt") }
                            case "import_preset":
                                if let name = scalar(value), !name.isEmpty { try require(name + ".yaml") }
                            case "opencc_config":
                                if let name = scalar(value), !name.isEmpty { try require("opencc/" + name) }
                            case "import_tables", "dependencies":
                                if let list = value.sequence {
                                    for item in list {
                                        if let name = scalar(item), !name.isEmpty {
                                            try require(
                                                name
                                                    + (key.string == "dependencies"
                                                        ? InstalledPackageLayout.schemaFileSuffix : ".dict.yaml"))
                                        }
                                    }
                                }
                            default: break
                            }
                            try visit(value)
                        }
                    } else if let list = node.sequence {
                        for item in list { try visit(item) }
                    }
                }
                if let root { try visit(root) }
                // Inspect parsed scalar values: comments often document the legacy
                // @global syntax even when the actual component uses @*module.
                func luaReferences(_ node: Node) throws {
                    try spend()
                    if let mapping = node.mapping {
                        for (_, value) in mapping { try luaReferences(value) }
                    } else if let list = node.sequence {
                        for value in list { try luaReferences(value) }
                    } else if let value = scalar(node) {
                        for module in matches(
                            "^lua_(?:processor|translator|filter|segmentor)@\\*([A-Za-z0-9_.]+)", value)
                        {
                            try requireModule(module)
                        }
                        if !matches("^lua_(?:processor|translator|filter|segmentor)@(?!\\*)([A-Za-z0-9_]+)", value)
                            .isEmpty
                        {
                            try require("rime.lua")
                        }
                    }
                }
                if let root { try luaReferences(root) }
            } else if path.hasSuffix(".lua") {
                for module in matches("require\\s*\\(?\\s*[\"']([A-Za-z0-9_./-]+)[\"']", text)
                where !["math", "string", "table", "utf8", "rime"].contains(module) {
                    try requireModule(module)
                }
            } else if path.hasPrefix("opencc/") {
                let object = try JSONSerialization.jsonObject(with: data)
                func visit(_ value: Any) throws {
                    if let dict = value as? [String: Any] {
                        if let file = dict["file"] as? String { try require("opencc/" + file) }
                        for child in dict.values { try visit(child) }
                    } else if let array = value as? [Any] {
                        for child in array { try visit(child) }
                    }
                }
                try visit(object)
            }
        }
        return missing.sorted()
    }
}

/// Frontend-selected enablement for schemas the live engine can actually run. The
/// source YAML remains in resources/sourceFiles; only this transaction's private
/// user configuration receives the schema_list override.
public enum SupportedSchemaSelection {
    /// Identity of our managed block, in the same `# Rx:` form plum's recipe.sh uses.
    static let rx = "songyan:supported_schemas:"

    /// The user's or package's `default.custom.yaml` (often written by plum, with `__patch`,
    /// `__include` and comments) is kept byte for byte; our selection is one more `__patch`
    /// entry, applied last, so it overrides `schema_list` the way a later Rime patch does.
    public static func stage(_ schemaIDs: [String], deployment: RecipeDeployment) throws {
        guard !schemaIDs.isEmpty, Set(schemaIDs).count == schemaIDs.count,
            schemaIDs.allSatisfy({ !$0.contains("/") && SchemeSourceCheck.safe($0) })
        else {
            throw RecipeInstallError.invalidResource("没有可启用的输入方案")
        }
        let name = "default.custom.yaml"
        let user = deployment.userDataURL.appendingPathComponent(name)
        let resource = deployment.resourceURL.appendingPathComponent(name)
        let existing = FileManager.default.fileExists(atPath: user.path) ? user : resource
        var original = ""
        if FileManager.default.fileExists(atPath: existing.path) {
            guard let text = String(data: try Data(contentsOf: existing), encoding: .utf8) else {
                throw RecipeInstallError.invalidResource("default.custom.yaml 不是 UTF-8 文本，请改成 UTF-8 编码后重试。")
            }
            original = text.isEmpty || text.hasSuffix("\n") ? text : text + "\n"
        }
        // JSON string literals are valid YAML double-quoted scalars, so any safe ID stays a string.
        let items = try schemaIDs.map { id in
            "        - schema: " + String(decoding: try JSONEncoder().encode(id), as: UTF8.self) + "\n"
        }
        let body = "  - patch/+:\n      schema_list:\n" + items.joined()
        let merged: String
        do { merged = try RecipePlanSupport.patch(original, body: body, rx: rx) } catch {
            throw RecipeInstallError.invalidResource("default.custom.yaml 的写法无法自动加入输入方案选择，请检查这个文件后重试。")
        }
        try Data(merged.utf8).write(to: user, options: .atomic)
    }
}
