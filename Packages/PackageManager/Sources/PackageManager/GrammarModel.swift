import CryptoKit
import Foundation
import KeyboardCore
import Yams

/// Reads deployed configuration, never infers a binding from a model filename or source schema.
public struct GrammarBinding: Identifiable, Sendable {
    public var id: String { schemaID }
    public let schemaID: String
    public let language: String?
    public let contextualSuggestions: Bool
    public enum Support: Equatable, Sendable { case supported, unsupported, unknown }
    public let support: Support

    private static func support(in root: [String: Any]?) -> Support {
        guard let translators = (root?["engine"] as? [String: Any])?["translators"] as? [String], !translators.isEmpty
        else { return .unknown }
        var unknown = false
        for translator in translators {
            let parts = translator.split(separator: "@", maxSplits: 1).map(String.init)
            let name = parts.first ?? ""
            if name == "script_translator" { return .supported }
            if name == "table_translator" {
                let namespace = parts.count == 2 ? parts[1] : "translator"
                let options = root?[namespace] as? [String: Any] ?? [:]
                if ["enable_sentence", "sentence_over_completion", "contextual_suggestions"].contains(where: {
                    options[$0] as? Bool == true
                }) {
                    return .supported
                }
            } else if !["punct_translator", "echo_translator", "reverse_lookup_translator"].contains(name) {
                unknown = true
            }
        }
        return unknown ? .unknown : .unsupported
    }

    public static func read(schemaID: String, buildDirectory: URL) throws -> Self {
        guard schemaID.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            throw RecipeInstallError.invalidResource("输入方式标识无效")
        }
        let url = InstalledPackageLayout.compiledSchemaURL(build: buildDirectory, id: schemaID)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= RecipeResourceBudget.sourceFile else { throw RecipeInstallError.invalidResource("编译配置文件超过大小限制") }
        let text = try String(contentsOf: url, encoding: .utf8)
        let root = try BoundedYAML.load(yaml: text) as? [String: Any]
        let node = try BoundedYAML.compose(yaml: text)
        return Self(
            schemaID: schemaID,
            language: node?["grammar"]?["language"]?.scalar?.string,
            contextualSuggestions: (root?["translator"] as? [String: Any])?["contextual_suggestions"] as? Bool ?? false,
            support: support(in: root))
    }

    /// Whether this input method actually references `modelPath` in its deployed configuration.
    /// The relation is model → input-method set, read from the real `grammar.language` — never
    /// inferred from a filename, source recipe, brand or schema ID.
    public func binds(modelPath: String) -> Bool {
        language == GrammarModelRecipe.modelName(for: modelPath)
    }
}

public enum GrammarModelRecipe {
    public static func displayName(for modelPath: String, sources: [String: Data]?) -> String? {
        guard validModelPath(modelPath),
            let source = sources?["songyan-models/" + managedName(for: modelPath) + ".recipe.yaml"]
                ?? sources?[managedName(for: modelPath) + ".recipe.yaml"],
            let firstLine = String(data: source, encoding: .utf8)?.components(separatedBy: "\n").first,
            firstLine.hasPrefix("# model-display: "),
            let bytes = Data(base64Encoded: String(firstLine.dropFirst("# model-display: ".count))),
            let name = String(data: bytes, encoding: .utf8), !name.isEmpty, name.count <= 160,
            name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else {
            return nil
        }
        return name
    }

    /// Imported filenames are user data, not recipe/glob syntax. Preserve already-compatible
    /// names; map every other .gram name to a stable internal path without asking for a rename.
    public static func installPath(for filename: String) -> String? {
        guard filename.lowercased().hasSuffix(".gram"), filename.count > 5 else { return nil }
        if literalModelPath(filename), !filename.contains("/") { return filename }
        let digest = SHA256.hash(data: Data(filename.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "model-" + String(digest.prefix(20)) + ".gram"
    }

    public static func validModelPath(_ path: String) -> Bool {
        GrammarModelPath.isValid(path)
    }

    private static func literalModelPath(_ path: String) -> Bool {
        validModelPath(path)
            && !path.unicodeScalars.contains {
                CharacterSet.whitespacesAndNewlines.contains($0) || "\"'$`*?[]{}#".unicodeScalars.contains($0)
            }
    }

    static func managedName(for modelPath: String) -> String {
        let language = modelName(for: modelPath)
        if language.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil {
            return "model-" + language
        }
        let digest = sha256Hex(Data(modelPath.utf8))
        return "model-" + String(digest.prefix(20))
    }

    /// A model's binding identity is its file name stem, independent of any input method. One
    /// model is bound to zero, one or many input methods (schemas); every named schema shares
    /// this identity but gets its own managed patch target, so replacing or clearing one
    /// schema's binding never rewrites another schema's block.
    public static func modelName(for modelPath: String) -> String { String(modelPath.dropLast(5)) }

    /// One `.gram` file, zero/one/many input methods. The model is installed exactly once
    /// (`install_files`), never duplicated per binding. `bindingSchemaIDs` receive this model;
    /// `clearingSchemaIDs` are unbound. Each named schema gets its own `__patch` block under
    /// the same Rx, so one schema's binding never rewrites another's. A call with only
    /// `clearingSchemaIDs` leaves the model installed and clears exactly those bindings.
    /// An empty change set installs/replaces the file without binding an input method.
    public static func make(
        modelPath: String, bindingSchemaIDs: [String],
        clearingSchemaIDs: [String] = [], sourceURL: URL? = nil,
        displayName: String? = nil
    ) throws -> DeclarativeRecipe {
        guard literalModelPath(modelPath) else {
            throw RecipeInstallError.invalidResource("此模型路径格式不受支持，无法直接配置；请保留方案原配置并补充模型文件")
        }
        let binding = Array(Set(bindingSchemaIDs)).sorted()
        let clearing = Array(Set(clearingSchemaIDs).subtracting(binding)).sorted()
        for schemaID in binding + clearing {
            guard schemaID.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
                throw RecipeInstallError.invalidResource("输入方式标识无效：\(schemaID)")
            }
        }
        let language = modelName(for: modelPath)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let languageValue = String(data: try encoder.encode(language), encoding: .utf8)!
        let name = managedName(for: modelPath)
        let declaredName = "songyan-models/" + name
        var lines: [String] = []
        if let displayName, !displayName.isEmpty, displayName.count <= 160,
            displayName.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        {
            lines.append("# model-display: " + Data(displayName.utf8).base64EncodedString())
        }
        lines += [
            "recipe:",
            "  Rx: \(declaredName)",
            "  description: 语法模型绑定",
        ]
        if let sourceURL {
            lines.append("download_files:")
            lines.append("  - \(modelPath)::\(sourceURL.absoluteString)")
        }
        // The model file is installed exactly once, regardless of how many input methods bind it.
        lines.append("install_files:")
        lines.append("  - \(modelPath)")
        lines.append("patch_files:")
        for schemaID in binding {
            lines.append("  \(schemaID).custom.yaml:")
            lines.append("    - patch/+:")
            lines.append("        grammar/language: \(languageValue)")
        }
        for schemaID in clearing {
            lines.append("  \(schemaID).custom.yaml:")
            lines.append("    - patch/+:")
            lines.append("        grammar/language: \"\"")
        }
        return try DeclarativeRecipe(
            path: declaredName + ".recipe.yaml", source: Data((lines.joined(separator: "\n") + "\n").utf8))
    }
}
