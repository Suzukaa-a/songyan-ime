import Darwin
import Foundation
import Yams

public struct RecipeArgument: Codable, Equatable, Sendable {
    public let name: String
    public let value: String
    public init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }
}

public struct RecipeExternalResource: Codable, Equatable, Sendable {
    public let path: String
    public let url: URL
    public init(path: String, url: URL) {
        self.path = path
        self.url = url
    }
}

/// Declarative subset of plum b1be1969 scripts/recipe.sh. Patches remain Rime __patch
/// operations, not a front-end approximation of Rime's YAML merge semantics.
public struct DeclarativeRecipe: Sendable {
    public let path: String
    public let declaredName: String?
    public let declaredArguments: [String]
    public let displayDescription: String?
    public let downloads: [RecipeExternalResource]
    public let installPatterns: [String]
    public let patchTargets: [String]
    fileprivate let patches: [(target: String, body: String)]
    public let source: Data

    public init(path: String, source: Data) throws {
        try RecipePlanSupport.checkPath(path)
        guard let text = String(data: source, encoding: .utf8), !text.contains("\r"), !text.contains("\t"),
            !text.contains("\0")
        else {
            throw RecipeInstallError.invalidManifest("配置文件格式必须为 UTF-8 编码，且使用换行符与空格缩进")
        }
        try RecipePlanSupport.validateYAML(text, label: path)
        let document = try BoundedYAML.load(yaml: text) as? [String: Any]
        displayDescription = (document?["recipe"] as? [String: Any])?["description"] as? String
        var sections: [String: [String]] = [:]
        var foldedSections = Set<String>()
        var section: String?
        var sourceLines = text.components(separatedBy: "\n")
        if sourceLines.last == "" { sourceLines.removeLast() }
        for line in sourceLines {
            if line.isEmpty || line.hasPrefix("#") || line == "---" {
                if let section { sections[section, default: []].append(line) }
                continue
            }
            if !line.hasPrefix(" ") {
                let folded = line == "install_files: >-" || line == "download_files: >-"
                let header = folded ? String(line.dropLast(3)) : line
                guard ["recipe:", "download_files:", "install_files:", "patch_files:"].contains(header),
                    sections[String(header.dropLast())] == nil
                else {
                    throw RecipeInstallError.invalidManifest("不支持的配置顶层语句：\(line)")
                }
                section = String(header.dropLast())
                sections[section!] = []
                if folded { foldedSections.insert(section!) }
            } else {
                guard let section else { throw RecipeInstallError.invalidManifest("配置文件缺少顶层声明") }
                sections[section, default: []].append(line)
            }
        }
        guard let metadata = sections["recipe"] else { throw RecipeInstallError.invalidManifest("配置文件缺少元信息声明") }
        var name: String?
        var args: [String] = []
        var readingArgs = false
        var readingDescription = false
        for line in metadata {
            let clean = line.trimmingCharacters(in: .whitespaces)
            if clean.isEmpty || clean.hasPrefix("#") { continue }
            if line.hasPrefix("  Rx: ") {
                name = String(line.dropFirst(6)).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                readingArgs = false
                readingDescription = false
            } else if line == "  args:" {
                readingArgs = true
                readingDescription = false
            } else if line.hasPrefix("  description:") {
                readingDescription = true
                readingArgs = false
            } else if line.hasPrefix("    "), readingDescription {
                continue
            } else if line.hasPrefix("    - "), readingArgs {
                args.append(String(line.dropFirst(6)))
            } else {
                throw RecipeInstallError.invalidManifest("不支持的配置元信息语句：\(line)")
            }
        }
        func list(_ key: String) throws -> [String] {
            try (sections[key] ?? []).compactMap { line in
                let clean = line.trimmingCharacters(in: .whitespaces)
                if clean.isEmpty || clean.hasPrefix("#") { return nil }
                guard line.hasPrefix(foldedSections.contains(key) ? "  " : "  - ") else {
                    throw RecipeInstallError.invalidManifest("\(key) 仅支持列表或每行一项的文本")
                }
                let value = String(line.dropFirst(foldedSections.contains(key) ? 2 : 4))
                guard !value.isEmpty, !value.contains(where: { $0.isWhitespace }), !value.contains("$"),
                    !value.contains("`"), !value.contains("\""), !value.contains("'")
                else {
                    throw RecipeInstallError.invalidManifest("\(key) 不支持引号或变量插值：\(value)")
                }
                return value
            }
        }
        var downloads: [RecipeExternalResource] = []
        var downloadPaths = Set<String>()
        for value in try list("download_files") {
            let parts = value.components(separatedBy: "::")
            guard parts.count <= 2, let url = URL(string: parts.last!), url.scheme == "https", url.host != nil else {
                throw RecipeInstallError.invalidManifest("外部下载仅支持 HTTPS 链接：\(value)")
            }
            let filename =
                parts.count == 2
                ? parts[0] : String(value.split(separator: "/", omittingEmptySubsequences: false).last ?? "")
            try RecipePlanSupport.checkPath(filename)
            guard downloadPaths.insert(filename).inserted else {
                throw RecipeInstallError.invalidManifest("暂不支持重复的下载目标：\(filename)")
            }
            downloads.append(.init(path: filename, url: url))
        }
        let patterns = try list("install_files")
        for pattern in patterns { try RecipePlanSupport.checkPath(pattern, glob: true) }
        var patches: [(target: String, body: String)] = []
        var target: String?
        var lines: [String] = []
        func finish() throws {
            guard let target else { return }
            guard lines.contains(where: { $0.hasPrefix("  - ") }) else {
                throw RecipeInstallError.invalidManifest("patch_files 目标必须包含补丁列表：\(target)")
            }
            patches.append((target, lines.joined(separator: "\n") + "\n"))
        }
        for line in sections["patch_files"] ?? [] {
            if line.hasPrefix("  "), !line.hasPrefix("   "), line.hasSuffix(":"), !line.hasPrefix("  #") {
                try finish()
                target = String(line.dropFirst(2).dropLast())
                lines = []
            } else if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("  #") {
                if target != nil { lines.append(line.hasPrefix("  ") ? String(line.dropFirst(2)) : line) }
            } else {
                guard target != nil, line.hasPrefix("    ") else {
                    throw RecipeInstallError.invalidManifest("patch_files 缩进格式不正确：\(line)")
                }
                lines.append(String(line.dropFirst(2)))
            }
        }
        try finish()
        self.path = path
        self.source = source
        declaredName = name
        declaredArguments = args
        self.downloads = downloads
        installPatterns = patterns
        self.patches = patches
        patchTargets = patches.map(\.target)
    }
}

public struct DeclarativeRecipePlan: Sendable {
    public let recipeSource: Data
    public let expectedGeneration: String?
    /// Stable package reference used for this plan's Rx identity. Retained so later
    /// compatibility stages (e.g. the standard T9 companion) append under the same
    /// invocation identity instead of inventing a new one.
    public let packageReference: String
    public let recipePath: String
    public let rx: String
    public let arguments: [RecipeArgument]
    public let externalResources: [RecipeExternalResource]
    public let changedPaths: [String]
    public let replacedManagedBlocks: [String]
    public let retainedDifferentInvocations: [String]
    /// Complete effective output tree. Unchanged bytes and user comments are retained.
    public let files: [String: Data]
    public let fileResources: [String: RecipeFileResource]
    public let receipt: RecipePlanReceipt
    public let stageReceipts: [RecipePlanReceipt]
    public let sourceFiles: [String: Data]
    public let sourceFileResources: [String: RecipeFileResource]
    public let grammarOverrides: [GrammarManagedOverride]
    public let managesGrammar: Bool
    public let restoredGrammarOverrides: [GrammarManagedOverride]
    let previousFiles: [String: Data]
    fileprivate let previousFileResources: [String: RecipeFileResource]
    fileprivate let userCustomBaseline: [String: Data]
    fileprivate let beforeHashes: [String: String]
    fileprivate let afterHashes: [String: String]
    private let sharedOpenCCDirectory: URL?

    /// `packageFiles` is the reviewed/fixed resource snapshot. `existingFiles` is the current
    /// effective workspace, with user *.custom.yaml overlaid by the caller after stopping writers.
    /// Declared downloads are listed by DeclarativeRecipe first; this method requires explicitly
    /// provided bytes. It does not fetch them or interpret their presence as model compatibility.
    public init(
        recipe: DeclarativeRecipe, packageReference: String, selectedRecipe: String,
        arguments: [RecipeArgument], packageFiles: [String: Data], existingFiles: [String: Data],
        providedDownloads: [String: Data] = [:], expectedDownloadSHA256: [String: String] = [:],
        sourceRevision: String? = nil,
        expectedGeneration: String? = nil,
        packageFileResources: [String: RecipeFileResource] = [:],
        existingFileResources: [String: RecipeFileResource] = [:],
        providedDownloadFiles: [String: RecipeFileResource] = [:],
        userCustomBaseline: [String: Data] = [:], sharedOpenCCDirectory: URL? = nil,
        managedGrammar: Bool = false,
        restoringGrammarOverrides: [GrammarManagedOverride] = []
    ) throws {
        try self.init(
            recipe: recipe, packageReference: packageReference, selectedRecipe: selectedRecipe,
            arguments: arguments, packageFiles: packageFiles, existingFiles: existingFiles,
            providedDownloads: providedDownloads, expectedDownloadSHA256: expectedDownloadSHA256,
            sourceRevision: sourceRevision, expectedGeneration: expectedGeneration,
            packageFileResources: packageFileResources, existingFileResources: existingFileResources,
            providedDownloadFiles: providedDownloadFiles, userCustomBaseline: userCustomBaseline,
            cachedExistingHashes: nil, sharedOpenCCDirectory: sharedOpenCCDirectory,
            managedGrammar: managedGrammar, restoringGrammarOverrides: restoringGrammarOverrides)
    }

    private init(
        recipe: DeclarativeRecipe, packageReference: String, selectedRecipe: String,
        arguments: [RecipeArgument], packageFiles: [String: Data], existingFiles: [String: Data],
        providedDownloads: [String: Data], expectedDownloadSHA256: [String: String], sourceRevision: String?,
        expectedGeneration: String?, packageFileResources: [String: RecipeFileResource],
        existingFileResources: [String: RecipeFileResource], providedDownloadFiles: [String: RecipeFileResource],
        userCustomBaseline: [String: Data], cachedExistingHashes: [String: String]?, sharedOpenCCDirectory: URL?,
        managedGrammar: Bool = false,
        restoringGrammarOverrides: [GrammarManagedOverride] = []
    ) throws {
        self.sharedOpenCCDirectory = sharedOpenCCDirectory
        if let original = packageFiles[recipe.path], original != recipe.source {
            throw RecipeInstallError.invalidResource("所选配置文件与同路径原始文件冲突：\(recipe.path)")
        }
        sourceFiles = packageFiles.merging([recipe.path: recipe.source]) { _, new in new }
        sourceFileResources = packageFileResources
        self.userCustomBaseline = userCustomBaseline
        for input in [packageFiles, existingFiles, providedDownloads] {
            for (path, data) in input
            where RecipeResourceBudget.isModel(path) && data.count > RecipeResourceBudget.bufferBytes {
                throw RecipeInstallError.invalidResource("大型模型文件超出内存限制，请使用外部文件引用：\(path)")
            }
        }
        for input in [packageFileResources, existingFileResources, providedDownloadFiles] {
            for path in input.keys {
                try RecipePlanSupport.checkPath(path)
                guard RecipeResourceBudget.isModel(path) else {
                    throw RecipeInstallError.invalidResource("当前外部文件仅支持 .gram 语法模型与联想词库：\(path)")
                }
            }
        }
        // Newly supplied prediction databases must be real librime-predict files; the existing
        // installation's resources were checked when they were installed.
        try Prediction.validateDatabases(in: packageFileResources)
        try Prediction.validateDatabases(in: providedDownloadFiles)
        guard Set(packageFiles.keys).isDisjoint(with: packageFileResources.keys),
            Set(existingFiles.keys).isDisjoint(with: existingFileResources.keys),
            Set(providedDownloads.keys).isDisjoint(with: providedDownloadFiles.keys)
        else { throw RecipeInstallError.invalidResource("同一路径同时提供了内存数据和外部文件引用") }
        guard packageReference.range(of: "^[A-Za-z0-9_./-]+$", options: .regularExpression) != nil else {
            throw RecipeInstallError.invalidManifest("package reference")
        }
        if !selectedRecipe.isEmpty {
            try RecipePlanSupport.checkPath(selectedRecipe)
            guard recipe.declaredName == selectedRecipe else {
                throw RecipeInstallError.invalidManifest("安装规则与所选配置文件路径不一致")
            }
        }
        var environment: [String: String] = [:]
        for argument in arguments {
            guard argument.name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil,
                argument.value.range(of: "^[A-Za-z0-9_./-]*$", options: .regularExpression) != nil
            else {
                throw RecipeInstallError.invalidManifest("参数仅支持 name=value 格式")
            }
            environment[argument.name] = argument.value
        }
        let rx =
            packageReference + ":" + selectedRecipe + ":"
            + arguments.map { $0.name + "=" + $0.value }.joined(separator: ",")
        guard !rx.contains(".") else { throw RecipeInstallError.invalidManifest("暂不支持包含正则元字符的旧版更新规则") }
        var available = packageFiles
        var availableFiles = packageFileResources
        for download in recipe.downloads {
            if let file = providedDownloadFiles[download.path] {
                guard
                    expectedDownloadSHA256[download.path] == nil || expectedDownloadSHA256[download.path] == file.sha256
                else { throw RecipeInstallError.invalidResource("外部文件校验不符：\(download.path)") }
                availableFiles[download.path] = file
                available[download.path] = nil
                continue
            }
            guard let bytes = providedDownloads[download.path] else {
                throw RecipeInstallError.invalidResource("缺少配置所需的外部文件：\(download.path)（\(download.url.absoluteString)）")
            }
            if let expected = expectedDownloadSHA256[download.path], sha256Hex(bytes) != expected {
                throw RecipeInstallError.invalidResource("外部文件校验不符：\(download.path)")
            }
            available[download.path] = bytes
            availableFiles[download.path] = nil
        }
        for path in available.keys { try RecipePlanSupport.checkPath(path) }
        for path in existingFiles.keys { try RecipePlanSupport.checkPath(path) }
        var output = existingFiles
        var outputFiles = existingFileResources
        let availablePaths = Set(available.keys).union(availableFiles.keys)
        var directories = Set<String>()
        for path in availablePaths {
            var parts = path.split(separator: "/").map(String.init)
            while parts.count > 1 {
                parts.removeLast()
                directories.insert(parts.joined(separator: "/"))
            }
        }
        for pattern in recipe.installPatterns {
            guard
                !directories.contains(where: { path in
                    pattern.withCString { p in path.withCString { fnmatch(p, $0, FNM_PATHNAME | FNM_PERIOD) == 0 } }
                })
            else {
                throw RecipeInstallError.invalidManifest("暂不支持匹配目录的展开规则：\(pattern)")
            }
            let matches = availablePaths.filter { path in
                pattern.withCString { p in path.withCString { fnmatch(p, $0, FNM_PATHNAME | FNM_PERIOD) == 0 } }
            }.sorted()
            guard !matches.isEmpty else { throw RecipeInstallError.invalidResource("未找到符合安装规则的文件：\(pattern)") }
            for path in matches {
                output[path] = available[path]
                outputFiles[path] = availableFiles[path]
            }
        }
        // Supplement only the effective workspace, never the install_files source candidates.
        if output.keys.contains(where: { $0.hasSuffix(".schema.yaml") }) {
            try SharedRimePresets.supplement(&output, openCCDirectory: sharedOpenCCDirectory)
        }
        guard Set(restoringGrammarOverrides.map(\.key)).count == restoringGrammarOverrides.count else {
            throw RecipeInstallError.invalidResource("存在重复的模型配置记录")
        }
        for override in restoringGrammarOverrides {
            guard let original = output[override.target] else {
                throw RecipeInstallError.invalidResource("要修改的模型目标文件不存在")
            }
            let restored = try override.removing(from: original)
            try RecipePlanSupport.validateYAML(String(decoding: restored, as: UTF8.self), label: "恢复默认配置")
            output[override.target] = restored
        }
        restoredGrammarOverrides = restoringGrammarOverrides
        managesGrammar = managedGrammar || !restoringGrammarOverrides.isEmpty
        grammarOverrides = managedGrammar ? try GrammarModelRecipe.generatedOverrides(recipe: recipe, rx: rx) : []
        var replaced: [String] = [], retained: [String] = []
        for patch in recipe.patches {
            let target = try RecipePlanSupport.expand(patch.target, variables: environment)
            try RecipePlanSupport.checkPath(target)
            guard target.hasSuffix(".yaml") else { throw RecipeInstallError.invalidManifest("补丁目标仅支持 YAML 文件") }
            let body = try RecipePlanSupport.expand(patch.body, variables: environment)
            let prior = output[target] ?? Data()
            guard let text = String(data: prior, encoding: .utf8) else {
                throw RecipeInstallError.invalidResource("补丁目标文件不是 UTF-8 编码：\(target)")
            }
            if text.contains("# Rx: \(rx)\n") || text.contains("# Rx: \(rx) {") { replaced.append(target) }
            if text.components(separatedBy: "\n").contains(where: { $0.hasPrefix("# Rx: ") && $0 != "# Rx: \(rx) {" }) {
                retained.append(target)
            }
            do { output[target] = Data(try RecipePlanSupport.patch(text, body: body, rx: rx).utf8) } catch {
                throw RecipeInstallError.invalidResource("patch_files \(target): \(error)")
            }
        }
        try RecipeResourceBudget.validate(
            output.mapValues(\.count).merging(outputFiles.mapValues(\.size)) { _, new in new })
        recipeSource = recipe.source
        self.expectedGeneration = expectedGeneration
        self.packageReference = packageReference
        recipePath = recipe.path
        self.rx = rx
        self.arguments = arguments
        externalResources = recipe.downloads
        files = output
        previousFiles = existingFiles
        fileResources = outputFiles
        previousFileResources = existingFileResources
        let beforeHashes =
            cachedExistingHashes
            ?? existingFiles.mapValues(sha256Hex).merging(existingFileResources.mapValues(\.sha256)) { _, new in new }
        let afterHashes = output.map { path, data in
            (path, data == existingFiles[path] ? beforeHashes[path]! : sha256Hex(data))
        }.reduce(into: outputFiles.mapValues(\.sha256)) { $0[$1.0] = $1.1 }
        self.beforeHashes = beforeHashes
        self.afterHashes = afterHashes
        changedPaths = afterHashes.keys.filter { beforeHashes[$0] != afterHashes[$0] }.sorted()
        replacedManagedBlocks = replaced
        retainedDifferentInvocations = retained
        receipt = RecipePlanReceipt(
            recipePath: recipe.path, recipeSHA256: sha256Hex(recipe.source), sourceRevision: sourceRevision, rx: rx,
            arguments: arguments, externalResources: recipe.downloads,
            providedResourceSHA256: Dictionary(
                uniqueKeysWithValues: recipe.downloads.map {
                    ($0.path, availableFiles[$0.path]?.sha256 ?? sha256Hex(available[$0.path]!))
                }),
            changes: changedPaths.map { .init(path: $0, beforeSHA256: beforeHashes[$0], afterSHA256: afterHashes[$0]!) }
        )
        stageReceipts = [receipt]
    }

    /// Compose resource installation and one or more configuration recipes before committing once.
    /// Retains the ORIGINAL user-custom baseline; passing intermediate files as a new baseline
    /// would incorrectly reject an intentional install_files overwrite during the final transaction.
    public func appending(
        recipe: DeclarativeRecipe, packageReference: String, selectedRecipe: String,
        arguments: [RecipeArgument], packageFiles: [String: Data],
        providedDownloads: [String: Data] = [:], expectedDownloadSHA256: [String: String] = [:],
        sourceRevision: String? = nil, packageFileResources: [String: RecipeFileResource] = [:],
        providedDownloadFiles: [String: RecipeFileResource] = [:],
        sourceArchivePrefix: String? = nil
    ) throws -> DeclarativeRecipePlan {
        let next = try DeclarativeRecipePlan(
            recipe: recipe, packageReference: packageReference,
            selectedRecipe: selectedRecipe, arguments: arguments, packageFiles: packageFiles,
            existingFiles: files, providedDownloads: providedDownloads, expectedDownloadSHA256: expectedDownloadSHA256,
            sourceRevision: sourceRevision, expectedGeneration: expectedGeneration,
            packageFileResources: packageFileResources, existingFileResources: fileResources,
            providedDownloadFiles: providedDownloadFiles,
            userCustomBaseline: userCustomBaseline, cachedExistingHashes: afterHashes,
            sharedOpenCCDirectory: sharedOpenCCDirectory)
        return DeclarativeRecipePlan(
            earlier: self, later: try sourceArchivePrefix.map { try next.archivingSources(prefix: $0) } ?? next)
    }

    /// Repository-relative install pools remain independent; original inputs are archived
    /// with a repository namespace so colliding recipe.yaml/dictionary paths cannot erase
    /// another package's provenance in an ordered multi-package transaction.
    public func archivingSources(prefix: String) throws -> Self {
        guard prefix.hasSuffix("/"), SchemeSourceCheck.safe(String(prefix.dropLast())) else {
            throw RecipeInstallError.invalidResource("安装源归档前缀无效")
        }
        return Self(original: self, archivePrefix: prefix)
    }

    private init(original: Self, archivePrefix: String) {
        sharedOpenCCDirectory = original.sharedOpenCCDirectory
        packageReference = original.packageReference
        sourceFiles = Dictionary(uniqueKeysWithValues: original.sourceFiles.map { (archivePrefix + $0.key, $0.value) })
        sourceFileResources = Dictionary(
            uniqueKeysWithValues: original.sourceFileResources.map { (archivePrefix + $0.key, $0.value) })
        grammarOverrides = original.grammarOverrides
        restoredGrammarOverrides = original.restoredGrammarOverrides
        managesGrammar = original.managesGrammar
        recipeSource = original.recipeSource
        recipePath = archivePrefix + original.recipePath
        rx = original.rx
        arguments = original.arguments
        expectedGeneration = original.expectedGeneration
        externalResources = original.externalResources
        changedPaths = original.changedPaths
        replacedManagedBlocks = original.replacedManagedBlocks
        retainedDifferentInvocations = original.retainedDifferentInvocations
        files = original.files
        fileResources = original.fileResources
        previousFiles = original.previousFiles
        previousFileResources = original.previousFileResources
        userCustomBaseline = original.userCustomBaseline
        beforeHashes = original.beforeHashes
        afterHashes = original.afterHashes
        func archive(_ receipt: RecipePlanReceipt) -> RecipePlanReceipt {
            RecipePlanReceipt(
                recipePath: archivePrefix + receipt.recipePath, recipeSHA256: receipt.recipeSHA256,
                sourceRevision: receipt.sourceRevision,
                rx: receipt.rx, arguments: receipt.arguments, externalResources: receipt.externalResources,
                providedResourceSHA256: receipt.providedResourceSHA256, changes: receipt.changes)
        }
        receipt = archive(original.receipt)
        stageReceipts = original.stageReceipts.map(archive)
    }

    private init(earlier: DeclarativeRecipePlan, later: DeclarativeRecipePlan) {
        sharedOpenCCDirectory = later.sharedOpenCCDirectory
        packageReference = later.packageReference
        sourceFiles = earlier.sourceFiles.merging(later.sourceFiles) { _, new in new }
        sourceFileResources = earlier.sourceFileResources.merging(later.sourceFileResources) { _, new in new }
        grammarOverrides = earlier.grammarOverrides + later.grammarOverrides
        managesGrammar = earlier.managesGrammar || later.managesGrammar
        restoredGrammarOverrides = earlier.restoredGrammarOverrides + later.restoredGrammarOverrides
        recipeSource = later.recipeSource
        recipePath = later.recipePath
        rx = later.rx
        arguments = later.arguments
        expectedGeneration = earlier.expectedGeneration
        userCustomBaseline = earlier.userCustomBaseline
        externalResources = earlier.externalResources + later.externalResources
        files = later.files
        previousFiles = earlier.previousFiles
        fileResources = later.fileResources
        previousFileResources = earlier.previousFileResources
        let beforeHashes = earlier.beforeHashes
        let afterHashes = later.afterHashes
        self.beforeHashes = beforeHashes
        self.afterHashes = afterHashes
        changedPaths = afterHashes.keys.filter { afterHashes[$0] != beforeHashes[$0] }.sorted()
        replacedManagedBlocks = Array(Set(earlier.replacedManagedBlocks + later.replacedManagedBlocks)).sorted()
        retainedDifferentInvocations = Array(
            Set(earlier.retainedDifferentInvocations + later.retainedDifferentInvocations)
        ).sorted()
        receipt = later.receipt
        stageReceipts = earlier.stageReceipts + later.stageReceipts
    }
}

extension GrammarModelRecipe {
    static func generatedOverrides(recipe: DeclarativeRecipe, rx: String) throws -> [GrammarManagedOverride] {
        let invocation = rx.split(separator: ":", omittingEmptySubsequences: false)
        if recipe.declaredName == "songyan-models/disable" {
            let schemaIDs = recipe.patchTargets.map { String($0.dropLast(12)) }
            let canonical = try disabling(schemaIDs: schemaIDs)
            guard canonical.source == recipe.source, canonical.path == recipe.path,
                invocation.count == 3, invocation[1] == "songyan-models/disable", invocation[2].isEmpty
            else {
                throw RecipeInstallError.invalidResource("关闭语法模型的配置来源无法核实")
            }
            return recipe.patches.map { .init(schemaID: String($0.target.dropLast(12)), rx: rx, body: $0.body) }
        }
        guard let modelPath = recipe.installPatterns.first else {
            throw RecipeInstallError.invalidResource("模型配置文件缺少文件引用")
        }
        let name = managedName(for: modelPath)
        let declaredName = "songyan-models/" + name
        guard invocation.count == 3, invocation[1] == declaredName, invocation[2].isEmpty,
            recipe.declaredName == declaredName, recipe.installPatterns == [modelPath],
            recipe.downloads.count <= 1
        else { throw RecipeInstallError.invalidResource("语法模型配置来源无法核实") }
        var binding: [String] = [], clearing: [String] = []
        let language = modelName(for: modelPath)
        for patch in recipe.patches {
            guard patch.target.hasSuffix(".custom.yaml"),
                let root = try BoundedYAML.load(yaml: "__patch:\n" + patch.body) as? [String: Any],
                let list = root["__patch"] as? [[String: Any]], list.count == 1,
                let map = list[0]["patch/+"] as? [String: Any], map.count == 1,
                let value = map["grammar/language"] as? String, value == language || value.isEmpty
            else {
                throw RecipeInstallError.invalidResource("语法模型配置格式无法核实")
            }
            let schema = String(patch.target.dropLast(12))
            if value.isEmpty { clearing.append(schema) } else { binding.append(schema) }
        }
        let canonical = try make(
            modelPath: modelPath, bindingSchemaIDs: binding, clearingSchemaIDs: clearing,
            sourceURL: recipe.downloads.first?.url,
            displayName: displayName(for: modelPath, sources: [recipe.path: recipe.source]))
        guard canonical.source == recipe.source, canonical.path == recipe.path else {
            throw RecipeInstallError.invalidResource("语法模型配置不是已知有效操作")
        }
        return recipe.patches.map { .init(schemaID: String($0.target.dropLast(12)), rx: rx, body: $0.body) }
    }
}

public struct RecipePlanReceipt: Codable, Sendable {
    public struct Change: Codable, Sendable {
        public let path: String
        public let beforeSHA256: String?
        public let afterSHA256: String
    }
    public let recipePath: String
    public let recipeSHA256: String
    public let sourceRevision: String?
    public let rx: String
    public let arguments: [RecipeArgument]
    public let externalResources: [RecipeExternalResource]
    public let providedResourceSHA256: [String: String]
    public let changes: [Change]
}

enum RecipePlanSupport {
    static func validateYAML(_ text: String, label: String) throws {
        do { _ = try BoundedYAML.compose(yaml: text) } catch {
            throw RecipeInstallError.invalidResource("\(label) YAML 格式无效：\(error)")
        }
    }
    static func checkPath(_ path: String, glob: Bool = false) throws {
        if !glob {
            guard SchemeSourceCheck.safe(path), !path.contains(".userdb"),
                (!path.hasPrefix("build/") || path == "build/.gitkeep")
            else { throw RecipeInstallError.invalidResource("配置文件路径不受支持：\(path)") }
            return
        }
        let pattern = glob ? "^[\\p{L}\\p{N}\\p{S}_.*?\\[\\]!-]+$" : "^[A-Za-z0-9_.-]+$"
        guard !path.isEmpty,
            path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ part in
                !part.isEmpty && part != "." && part != ".."
                    && part.range(of: pattern, options: .regularExpression) != nil
            }), !path.contains(".userdb"), (!path.hasPrefix("build/") || path == "build/.gitkeep")
        else { throw RecipeInstallError.invalidResource("配置文件路径不受支持：\(path)") }
    }

    static func expand(_ text: String, variables: [String: String]) throws -> String {
        var output = "", index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "`" || character == "\\" {
                throw RecipeInstallError.invalidManifest("不支持 heredoc 求值或反斜线转义")
            }
            guard character == "$" else {
                output.append(character)
                index = text.index(after: index)
                continue
            }
            let next = text.index(after: index)
            guard next < text.endIndex else { throw RecipeInstallError.invalidManifest("不支持此 $ 变量格式") }
            let name: String
            let fallback: String?
            if text[next] == "{" {
                guard let end = text[next...].firstIndex(of: "}") else {
                    throw RecipeInstallError.invalidManifest("变量表达式未闭合（缺少 }）")
                }
                let value = String(text[text.index(after: next)..<end])
                let parts = value.components(separatedBy: ":-")
                guard parts.count <= 2 else { throw RecipeInstallError.invalidManifest("不支持此变量展开格式") }
                name = parts[0]
                fallback = parts.count == 2 ? parts[1] : nil
                index = text.index(after: end)
            } else {
                var end = next
                while end < text.endIndex,
                    text[end].isASCII && (text[end].isLetter || text[end].isNumber || text[end] == "_")
                { end = text.index(after: end) }
                name = String(text[next..<end])
                fallback = nil
                index = end
            }
            guard name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil,
                fallback?.range(of: "^[A-Za-z0-9_./-]*$", options: .regularExpression) != nil || fallback == nil
            else {
                throw RecipeInstallError.invalidManifest("变量格式仅支持 $name、${name} 与 ${name:-literal}")
            }
            let value = variables[name] ?? ""
            output += value.isEmpty ? (fallback ?? "") : value
        }
        return output
    }

    static func patch(_ original: String, body: String, rx: String) throws -> String {
        guard !original.contains("\r"), original.isEmpty || original.hasSuffix("\n") else {
            throw RecipeInstallError.invalidResource("补丁目标文件必须使用换行符（LF）结尾")
        }
        try validateYAML(original, label: "现有自定义配置")
        try validateYAML("__patch:\n" + body, label: "补丁内容")
        var lines = original.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let marker = "# Rx: \(rx) {"
        while let start = lines.firstIndex(of: marker) {
            guard let end = lines[(start + 1)...].firstIndex(of: "# }") else {
                throw RecipeInstallError.invalidResource("已有配置管理块未闭合")
            }
            lines.removeSubrange(start...end)
        }
        if !lines.contains("__patch:") { lines.append("__patch:") }
        guard lines.filter({ $0 == "__patch:" }).count == 1,
            let begin = lines.firstIndex(of: "__patch:")
        else { throw RecipeInstallError.invalidResource("不支持包含多个 __patch 顶层键") }
        // Inline __patch maps/scalars cannot be safely combined with a new block-list key.
        guard !lines.contains(where: { $0.hasPrefix("__patch:") && $0 != "__patch:" }) else {
            throw RecipeInstallError.invalidResource("已有 __patch 格式不是列表结构")
        }
        let end =
            lines.indices.dropFirst(begin + 1).first { i in
                !lines[i].isEmpty && !lines[i].hasPrefix(" ") && !lines[i].hasPrefix("#")
            } ?? lines.count
        let block =
            [marker] + body.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init) + [
                "# }"
            ]
        lines.insert(contentsOf: block, at: end)
        let result = lines.joined(separator: "\n") + "\n"
        try validateYAML(result, label: "合并后的自定义配置")
        return result
    }
}

public extension RecipePackageManager {
    /// Read a quiescent workspace for planning. User custom files override shared copies;
    /// live databases and compiled build output never enter a recipe resource plan.
    static func readRecipeWorkspace(resources: URL, userConfiguration: URL? = nil) throws -> [String: Data] {
        let snapshot = try readRecipeWorkspaceSnapshot(resources: resources, userConfiguration: userConfiguration)
        guard snapshot.fileResources.isEmpty else { throw RecipeInstallError.invalidResource("包含模型文件的工作区需保留文件引用，请重试。") }
        return snapshot.files
    }

    static func readRecipeWorkspaceSnapshot(resources: URL, userConfiguration: URL? = nil) throws
        -> RecipeWorkspaceSnapshot
    {
        try readRecipeWorkspaceSnapshot(
            resources: resources, userConfiguration: userConfiguration, sourceArchive: false)
    }

    internal static func readRecipeWorkspaceSnapshot(resources: URL, userConfiguration: URL?, sourceArchive: Bool)
        throws -> RecipeWorkspaceSnapshot
    {
        let logicalPath: (String) -> String = { sourceArchive ? RecipeResourceBudget.sourceArchiveLogicalPath($0) : $0 }
        var files: [String: Data] = [:]
        var fileResources: [String: RecipeFileResource] = [:]
        var userCustomFiles: [String: Data] = [:]
        var bytes = 0
        func read(_ directory: URL, prefix: String, customOnly: Bool) throws {
            let info = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard info.isDirectory == true, info.isSymbolicLink != true else {
                throw RecipeInstallError.invalidResource(directory.path)
            }
            for url in try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            {
                if [".git", ".DS_Store"].contains(url.lastPathComponent) || url.lastPathComponent.contains(".userdb") {
                    continue
                }
                if url.lastPathComponent == "build" {
                    let placeholder = url.appendingPathComponent(".gitkeep")
                    if !customOnly, FileManager.default.fileExists(atPath: placeholder.path) {
                        let value = try placeholder.resourceValues(forKeys: [
                            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                        ])
                        guard value.isRegularFile == true, value.isSymbolicLink != true, value.fileSize == 0 else {
                            throw RecipeInstallError.invalidResource("build 目录只允许包含空的 .gitkeep 占位文件")
                        }
                        files[prefix + "build/.gitkeep"] = Data()
                    }
                    continue
                }
                let path = prefix + url.lastPathComponent
                let info = try url.resourceValues(forKeys: [
                    .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                ])
                guard info.isSymbolicLink != true else { throw RecipeInstallError.invalidResource("不支持符号链接：\(path)") }
                if info.isDirectory == true {
                    guard prefix.split(separator: "/").count < 32 else {
                        throw RecipeInstallError.invalidResource("目录层级过深（超过 32 层）")
                    }
                    try read(url, prefix: path + "/", customOnly: customOnly)
                } else if !customOnly || path.hasSuffix(".custom.yaml")
                    || RecipeResourceBudget.isModel(logicalPath(path))
                {
                    try RecipePlanSupport.checkPath(path)
                    if RecipeResourceBudget.isModel(logicalPath(path)) {
                        fileResources[path] = try RecipeFileResource.reference(at: url)
                        continue
                    }
                    guard files.count < 2000 else { throw RecipeInstallError.invalidResource("工作区文件数量超过限制：\(path)") }
                    let remaining = RecipeResourceBudget.sourceTotal - bytes + (files[path]?.count ?? 0)
                    var data = try BoundedLocalFile.read(
                        url, maximumBytes: min(RecipeResourceBudget.sourceFile, remaining))
                    // The workspace reads back the package's own rime.lua so re-planning never
                    // treats the generated prelude as source. A source archive keeps its raw
                    // bytes, which are hashed as written; wrapping is idempotent on use.
                    if !customOnly, !sourceArchive, path == LuaSandbox.entryPath {
                        guard let original = LuaSandbox.restoreOriginal(data) else { continue }
                        data = original
                    }
                    bytes += data.count - (files[path]?.count ?? 0)
                    files[path] = data
                    if customOnly && path.hasSuffix(".custom.yaml") { userCustomFiles[path] = data }
                }
            }
        }
        try read(resources, prefix: "", customOnly: false)
        if let userConfiguration { try read(userConfiguration, prefix: "", customOnly: true) }
        try RecipeResourceBudget.validate(
            files.mapValues(\.count).merging(fileResources.mapValues(\.size)) { _, new in new },
            logicalPath: logicalPath)
        return RecipeWorkspaceSnapshot(files: files, fileResources: fileResources, userCustomFiles: userCustomFiles)
    }

    /// Use the same coordinator lease from reading existing user custom through this transaction.
    /// Files overwrite only where plum install_files/managed blocks do; deployment failure retains active.
    @discardableResult
    func installRecipePlan(
        _ plan: DeclarativeRecipePlan, packageID: String, schemaID: String,
        initialUserDataURL: URL? = nil, deploy: @escaping Deploy
    ) async throws -> InstalledRecipe {
        // Composed recipes may supply dependencies in later stages; validate the final tree.
        try SchemeSourceCheck.dependencies(plan.files)
        let records = Set(plan.files.keys).union(plan.fileResources.keys).sorted().map { path in
            if let file = plan.fileResources[path] {
                return RecipeManifest.File(path: path, sha256: file.sha256, size: file.size)
            }
            let data = plan.files[path]!
            return RecipeManifest.File(path: path, sha256: plan.afterHashes[path]!, size: data.count)
        }
        let identity = records.map { $0.path + $0.sha256 }.joined() + plan.rx
        let priorCatalog = try activeInstallation().map {
            try Self.readInstalledRecipeSources(resources: $0.resourceURL)
        }
        let catalog = InstalledRecipeSources.merging(priorCatalog, plan: plan)
        let revision = String(sha256Hex(Data(identity.utf8)).prefix(40))
        let manifest = RecipeManifest(
            id: packageID, repository: "user/recipe", revision: revision,
            recipePath: plan.recipePath, license: "原包声明", schemaID: schemaID,
            requiredComponents: [], files: records, origin: .userRecipe)
        return try await installResources(
            manifest, initialUserDataURL: initialUserDataURL,
            deploy: { deployment in
                let actual = try Self.readUserCustomFiles(at: deployment.userDataURL)
                guard actual == plan.userCustomBaseline else {
                    throw RecipeInstallError.invalidResource("安装准备期间自定义配置发生改变，请重新尝试安装。")
                }
                try catalog.write(to: deployment.userDataURL.deletingLastPathComponent())
                for (path, data) in plan.files where path.hasSuffix(".custom.yaml") {
                    let target = deployment.userDataURL.appendingPathComponent(path)
                    try FileManager.default.createDirectory(
                        at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: target, options: .atomic)
                }
                return try await deploy(deployment)
            }, fileResources: plan.fileResources,
            expectedActiveGeneration: .some(plan.expectedGeneration),
            read: { file in
                guard let data = plan.files[file.path] else { throw RecipeInstallError.invalidResource(file.path) }
                return data
            })
    }

    static func readUserCustomFiles(at directory: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        func walk(_ url: URL, _ prefix: String) throws {
            for child in try FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            {
                if child.lastPathComponent == "build" || child.lastPathComponent.contains(".userdb") { continue }
                let info = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard info.isSymbolicLink != true else { throw RecipeInstallError.invalidResource(child.path) }
                let path = prefix + child.lastPathComponent
                if info.isDirectory == true {
                    try walk(child, path + "/")
                } else if path.hasSuffix(".custom.yaml") {
                    result[path] = try Data(contentsOf: child)
                }
            }
        }
        try walk(directory, "")
        return result
    }
}
