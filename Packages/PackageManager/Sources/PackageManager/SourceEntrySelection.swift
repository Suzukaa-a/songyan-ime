import Foundation

public extension DeclarativeRecipePlan {
    /// Frontend selection is an explicit archived recipe step, not a rewrite of
    /// upstream resources. An automatically acquired distribution prelude must
    /// not enable packages the user did not acquire.
    func selectingSourceEntry(
        _ entrySchemaID: String, sources: [AcquiredRimeSource],
        isNewInstallation: Bool
    ) throws -> DeclarativeRecipePlan {
        var ids = entrySchemaID.isEmpty ? [] : [entrySchemaID]
        if ids.isEmpty, isNewInstallation,
            sources.contains(where: { $0.isDependency && $0.files["default.yaml"] != nil }),
            !sources.contains(where: { !$0.isDependency && $0.files["default.yaml"] != nil })
        {
            ids = sources.filter { !$0.isDependency }.flatMap { source in
                InstalledPackageLayout.topLevelSchemaFiles(in: source.files.keys)
                    .map { String($0.dropLast(12)) }
            }.sorted()
        }
        guard !ids.isEmpty else { return self }
        guard
            ids.allSatisfy({
                files[$0 + InstalledPackageLayout.schemaFileSuffix] != nil
                    && $0.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
            })
        else {
            throw RecipeInstallError.invalidResource("所选输入方式不在最终安装文件中")
        }
        let needsDefault = files["default.yaml"] == nil
        let text =
            "recipe:\n  Rx: keyboard-enable\n"
            + (needsDefault ? "install_files:\n  - default.yaml\n" : "")
            + "patch_files:\n  default.custom.yaml:\n    - patch/+:\n        schema_list:\n"
            + ids.map { "          - schema: \($0)\n" }.joined()
        let recipe = try DeclarativeRecipe(path: "keyboard-enable.recipe.yaml", source: Data(text.utf8))
        let generated: [String: Data] = needsDefault ? ["default.yaml": Data("config_version: '1'\n".utf8)] : [:]
        return try appending(
            recipe: recipe, packageReference: "keyboard/frontend", selectedRecipe: "keyboard-enable",
            arguments: [], packageFiles: generated, sourceArchivePrefix: "frontend-generated/")
    }
}
