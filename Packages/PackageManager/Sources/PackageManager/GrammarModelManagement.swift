import Foundation

/// Per-target provenance survives later edits of the same model recipe.
public struct GrammarManagedOverride: Codable, Equatable, Sendable {
    public let schemaID: String
    public let rx: String
    public let body: String
    public var target: String { schemaID + ".custom.yaml" }
    public var key: String { target + "|" + rx }
    var block: String { "# Rx: \(rx) {\n" + body + "# }\n" }

    func removing(from data: Data) throws -> Data {
        guard let text = String(data: data, encoding: .utf8), !text.contains("\r"), text.hasSuffix("\n"),
            text.components(separatedBy: "# Rx: \(rx) {\n").count == 2,
            text.components(separatedBy: block).count == 2
        else {
            throw RecipeInstallError.invalidResource("模型设置已被修改或无法核实；未恢复输入方案的默认设置")
        }
        var lines = text.replacingOccurrences(of: block, with: "").components(separatedBy: "\n")
        if let begin = lines.firstIndex(of: "__patch:") {
            let end =
                lines.indices.dropFirst(begin + 1).first {
                    !lines[$0].isEmpty && !lines[$0].hasPrefix(" ") && !lines[$0].hasPrefix("#")
                } ?? lines.count
            let remaining = lines[(begin + 1)..<end].contains {
                !$0.trimmingCharacters(in: .whitespaces).isEmpty
                    && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#")
            }
            if !remaining { lines.remove(at: begin) }
        }
        // Keep a neutral file: omitting it would resurrect the copied user custom.
        let result = lines.joined(separator: "\n")
        let hasContent = lines.contains {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#")
        }
        return Data((hasContent ? result : result + "{}\n").utf8)
    }
}

public extension GrammarModelRecipe {
    static func overrides(in sources: InstalledRecipeSources?, files: [String: Data]) -> [GrammarManagedOverride] {
        guard let sources else { return [] }
        return sources.grammarOverrides.filter { record in
            files[record.target].flatMap { String(data: $0, encoding: .utf8) }?.contains("# Rx: \(record.rx) {\n")
                == true
        }.sorted { $0.key < $1.key }
    }

    static func restorationOverrides(
        schemaIDs: [String], sources: InstalledRecipeSources?,
        files: [String: Data], packageReference: String
    ) throws -> [GrammarManagedOverride] {
        let selected = Set(schemaIDs)
        let records = overrides(in: sources, files: files).filter { selected.contains($0.schemaID) }
        guard selected == Set(records.map(\.schemaID)) else {
            throw RecipeInstallError.invalidResource("所选输入方式没有手动设置的模型，无需恢复")
        }
        for record in records {
            guard let data = files[record.target] else { throw RecipeInstallError.invalidResource("要修改的模型目标文件不存在") }
            _ = try record.removing(from: data)
        }
        for schema in selected {
            let text = String(decoding: files[schema + ".custom.yaml"] ?? Data(), as: UTF8.self)
            let lines = text.components(separatedBy: "\n")
            for (index, line) in lines.enumerated()
            where line.hasPrefix("# Rx: \(packageReference):") && line.hasSuffix(" {") {
                let rx = String(line.dropFirst(6).dropLast(2))
                guard rx.hasPrefix(packageReference + ":model-") || rx.hasPrefix(packageReference + ":songyan-models/")
                else { continue }
                let end = lines.indices.dropFirst(index + 1).first { lines[$0] == "# }" } ?? lines.count
                if lines[(index + 1)..<end].contains(where: { $0.contains("grammar/language:") }),
                    !records.contains(where: { $0.schemaID == schema && $0.rx == rx })
                {
                    throw RecipeInstallError.invalidResource("有无法识别的旧模型设置，未恢复默认设置")
                }
            }
        }
        return records
    }

    static func disabling(schemaIDs: [String]) throws -> DeclarativeRecipe {
        let ids = Array(Set(schemaIDs)).sorted()
        guard !ids.isEmpty, ids.allSatisfy({ $0.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil })
        else {
            throw RecipeInstallError.invalidResource("要关闭语法模型的输入方式无效")
        }
        var lines = ["recipe:", "  Rx: songyan-models/disable", "  description: 关闭所选输入方式的语法模型", "patch_files:"]
        for schema in ids {
            lines += ["  \(schema).custom.yaml:", "    - patch/+:", "        grammar/language: \"\""]
        }
        return try DeclarativeRecipe(
            path: "songyan-models/disable.recipe.yaml", source: Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    static func restorationRecipe(schemaIDs: [String]) throws -> DeclarativeRecipe {
        let ids = Array(Set(schemaIDs)).sorted()
        guard !ids.isEmpty, ids.allSatisfy({ $0.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil })
        else {
            throw RecipeInstallError.invalidResource("要恢复默认设置的输入方式无效")
        }
        let text =
            "# restore-grammar: " + ids.joined(separator: ",")
            + "\nrecipe:\n  Rx: songyan-models/restore-defaults\n  description: 恢复输入方案默认语法模型\n"
        return try DeclarativeRecipe(path: "songyan-models/restore-defaults.recipe.yaml", source: Data(text.utf8))
    }
}
