import Foundation

/// Original recipe inputs, stored beside the resources and never in the deployed file pool.
public struct InstalledRecipeSources: Sendable {
    public let files: [String: Data]
    public let fileResources: [String: RecipeFileResource]
    public let receipts: [RecipePlanReceipt]
    public let grammarOverrides: [GrammarManagedOverride]

    public init(
        files: [String: Data], fileResources: [String: RecipeFileResource], receipts: [RecipePlanReceipt],
        grammarOverrides: [GrammarManagedOverride] = []
    ) {
        self.files = files
        self.fileResources = fileResources
        self.receipts = receipts
        self.grammarOverrides = grammarOverrides
    }

    /// The single on-disk record: data files live under `recipe-inputs/`, models are referenced
    /// with the identity captured when they were imported.
    private struct Catalog: Codable {
        let files: [String]
        let models: [RecipeManifest.File]
        let receipts: [RecipePlanReceipt]
        let grammarOverrides: [GrammarManagedOverride]
    }

    static func merging(_ prior: Self?, plan: DeclarativeRecipePlan) -> Self {
        // Explicit source bytes win. Previous arguments apply only to identical bytes.
        let archivedPaths = Set((prior?.receipts ?? []).map(\.recipePath))
        func scope(_ path: String) -> String? {
            guard path.hasPrefix("source-repositories/") else { return nil }
            let parts = path.split(separator: "/")
            guard parts.count >= 4 else { return nil }
            return parts.prefix(3).joined(separator: "/") + "/"
        }
        let refreshedScopes = Set(plan.sourceFiles.keys.compactMap(scope))
        let priorRecipes = (prior?.files ?? [:]).filter {
            if let scope = scope($0.key) { return !refreshedScopes.contains(scope) }
            return $0.key == "recipe.yaml" || $0.key.hasSuffix(".recipe.yaml") || archivedPaths.contains($0.key)
        }
        let files = priorRecipes.merging(plan.sourceFiles) { _, new in new }
        let retainedModels = (prior?.fileResources ?? [:]).filter { item in
            scope(item.key).map { !refreshedScopes.contains($0) } ?? true
        }
        let models = retainedModels.merging(plan.sourceFileResources) { _, new in new }
        let executed = Set(plan.stageReceipts.map(\.rx))
        let retained = (prior?.receipts ?? []).filter {
            !executed.contains($0.rx) && files[$0.recipePath].map(sha256Hex) == $0.recipeSHA256
        }
        var overrides = GrammarModelRecipe.overrides(in: prior, files: plan.previousFiles)
            .reduce(into: [String: GrammarManagedOverride]()) { $0[$1.key] = $1 }
        for record in plan.restoredGrammarOverrides { overrides[record.key] = nil }
        for record in plan.grammarOverrides { overrides[record.key] = record }
        let retainedOverrides = overrides.values.filter {
            plan.files[$0.target].flatMap { String(data: $0, encoding: .utf8) }?.contains("# Rx: \($0.rx) {\n") == true
        }.sorted { $0.key < $1.key }
        return Self(
            files: files, fileResources: models, receipts: retained + plan.stageReceipts,
            grammarOverrides: retainedOverrides)
    }
    func write(to generation: URL) throws {
        let directory = generation.appendingPathComponent("recipe-inputs")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try RecipeResourceBudget.validate(
            files.mapValues(\.count).merging(fileResources.mapValues(\.size)) { _, new in new },
            logicalPath: RecipeResourceBudget.sourceArchiveLogicalPath)
        var dataPaths: [String] = [], models: [RecipeManifest.File] = []
        for path in Set(files.keys).union(fileResources.keys).sorted() {
            try Task.checkCancellation()
            guard SchemeSourceCheck.safe(path) else { throw RecipeInstallError.invalidResource(path) }
            let target = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let file = fileResources[path] {
                let logical = RecipeResourceBudget.sourceArchiveLogicalPath(path)
                guard RecipeResourceBudget.isModel(logical) else {
                    throw RecipeInstallError.invalidResource("不是有效的模型文件引用：\(path)")
                }
                try Prediction.validateDatabases(in: [logical: file])
                try file.copy(to: target, maximumBytes: RecipeResourceBudget.maximumFileBytes(logical))
                models.append(.init(path: path, sha256: file.sha256, size: file.size))
            } else if let data = files[path] {
                try data.write(to: target, options: .atomic)
                dataPaths.append(path)
            }
        }
        try JSONEncoder().encode(
            Catalog(files: dataPaths, models: models, receipts: receipts, grammarOverrides: grammarOverrides)
        )
        .write(to: generation.appendingPathComponent("recipe-catalog.json"), options: .atomic)
    }

    /// Reads the catalog written at install time. Generations without one (pinned packages) only
    /// contribute their `*.recipe.yaml` files.
    static func read(resources: URL) throws -> Self {
        let generation = resources.deletingLastPathComponent()
        let catalogURL = generation.appendingPathComponent("recipe-catalog.json")
        guard FileManager.default.fileExists(atPath: catalogURL.path) else { return try scanRecipes(in: resources) }
        let data = try BoundedLocalFile.read(catalogURL, maximumBytes: RecipeResourceBudget.sourceFile)
        let catalog = try JSONDecoder().decode(Catalog.self, from: data)
        let inputs = generation.appendingPathComponent("recipe-inputs")
        var files: [String: Data] = [:], models: [String: RecipeFileResource] = [:]
        for path in catalog.files {
            guard SchemeSourceCheck.safe(path) else { throw RecipeInstallError.invalidResource(path) }
            files[path] = try BoundedLocalFile.read(
                inputs.appendingPathComponent(path), maximumBytes: RecipeResourceBudget.sourceFile)
        }
        for model in catalog.models {
            guard SchemeSourceCheck.safe(model.path) else { throw RecipeInstallError.invalidResource(model.path) }
            models[model.path] = RecipeFileResource(
                url: inputs.appendingPathComponent(model.path), size: model.size, sha256: model.sha256)
        }
        return Self(
            files: files, fileResources: models, receipts: catalog.receipts, grammarOverrides: catalog.grammarOverrides)
    }

    private static func scanRecipes(in resources: URL) throws -> Self {
        var files: [String: Data] = [:]
        if let walker = FileManager.default.enumerator(at: resources, includingPropertiesForKeys: nil) {
            for case let url as URL in walker {
                let path = String(url.path.dropFirst(resources.path.count + 1))
                guard path == "recipe.yaml" || path.hasSuffix(".recipe.yaml") else { continue }
                files[path] = try BoundedLocalFile.read(url, maximumBytes: RecipeResourceBudget.sourceFile)
            }
        }
        return Self(files: files, fileResources: [:], receipts: [])
    }
}

public extension RecipePackageManager {
    static func readInstalledRecipeSources(resources: URL) throws -> InstalledRecipeSources {
        try InstalledRecipeSources.read(resources: resources)
    }
}
