import Foundation
import Yams

/// Typo correction: librime `script_translator` reads `<name_space>/enable_correction`
/// (default false); when on, it tolerates single-key substitutions by physical-key neighbors
/// (NearSearchCorrector, no extra compiled artifact needed).
///
/// Pure logic; independent of any source or schema name:
///   * `eligibility`: decides from the **compiled** schema whether it can be enabled. The
///     sole primary producer must be `script_translator` (same contract as
///     `CompactSchemaAdapter.primaryProducer`), the speller alphabet must cover the full
///     a–z (26 keys), and the schema must not be a generated 14/9-key companion;
///   * `make`: builds a declarative patch like `GrammarModelRecipe`'s, written as a separate
///     Rx-managed block in `<schema>.custom.yaml` (a rerun replaces only that block; other
///     blocks and user content are kept);
///   * `userOwnsSetting`: if the user's own custom already sets `enable_correction`, it is
///     user-managed and not overridden.
///
/// The caller proves it took effect by reading back from the engine after deploy
/// (`RimeEngine.schemaValue`); otherwise it counts as unavailable (fail closed), with no
/// "looks enabled" inference here.
public enum TypoCorrection {
    /// Recipe identity (`Rx`) of the managed block. Not tied to any source.
    public static let recipeName = "typo-correction"
    /// librime config leaf under the primary producer namespace.
    public static let configLeaf = "enable_correction"
    /// librime's default speller alphabet when a schema omits `speller/alphabet`.
    static let defaultSpellerAlphabet = "zyxwvutsrqponmlkjihgfedcba"
    static let fullAlphabet = Set("abcdefghijklmnopqrstuvwxyz")

    /// One schema whose primary producer can take the correction switch.
    public struct Target: Equatable, Hashable, Sendable {
        public let schemaID: String
        /// Primary producer namespace (`translator` for a default entry, else `@name`).
        public let namespace: String
        public init(schemaID: String, namespace: String) {
            self.schemaID = schemaID
            self.namespace = namespace
        }
        /// Full config key, e.g. `translator/enable_correction`.
        public var configKey: String { namespace + "/" + TypoCorrection.configLeaf }
    }

    public enum Eligibility: Equatable, Sendable {
        case eligible(Target)
        case ineligible(String)

        public var target: Target? {
            if case .eligible(let target) = self { return target }
            return nil
        }
    }

    /// Structural eligibility from a compiled schema (`build/<id>.schema.yaml`). Never throws:
    /// anything that cannot be proven eligible is `.ineligible` (fail closed).
    public static func eligibility(compiled: Data, schemaID: String) -> Eligibility {
        guard validIdentifier(schemaID) else { return .ineligible("invalid schema id") }
        guard !CompactSchemaAdapter.isGeneratedCompanionID(schemaID) else {
            return .ineligible("generated compact companion")
        }
        guard compiled.count <= RecipeResourceBudget.sourceFile,
            let text = String(data: compiled, encoding: .utf8),
            let loaded = try? BoundedYAML.load(yaml: text),
            let root = loaded as? [String: Any]
        else {
            return .ineligible("compiled schema unreadable")
        }
        guard let schema = root["schema"] as? [String: Any],
            schema["schema_id"] as? String == schemaID
        else {
            return .ineligible("schema identity mismatch")
        }
        // Compact companions (and in-place compact templates) carry capability blocks.
        guard root["keyboard_rewrite"] == nil, root["keyboard_adapter"] == nil else {
            return .ineligible("compact keyboard adapter")
        }
        guard let engine = root["engine"] as? [String: Any],
            let translators = engine["translators"] as? [String],
            let producer = CompactSchemaAdapter.primaryProducer(translators: translators)
        else {
            return .ineligible("no single primary producer")
        }
        guard producer.klass == .script else { return .ineligible("primary producer is not script_translator") }
        guard producer.namespace.range(of: "^[A-Za-z0-9_]+$", options: .regularExpression) != nil,
            let section = root[producer.namespace] as? [String: Any],
            let dictionary = section["dictionary"] as? String, !dictionary.isEmpty
        else {
            return .ineligible("primary producer has no dictionary")
        }
        let speller = root["speller"] as? [String: Any]
        // An unquoted numeric alphabet (`23456789`) loads as a number, not a string; any
        // present-but-non-string value is taken literally, never as the default alphabet.
        let alphabet: String
        switch speller?["alphabet"] {
        case nil: alphabet = defaultSpellerAlphabet
        case let value as String: alphabet = value
        case let value?: alphabet = String(describing: value)
        }
        guard fullAlphabet.isSubset(of: Set(alphabet)) else {
            return .ineligible("speller alphabet is not a full a-z (26-key) alphabet")
        }
        return .eligible(Target(schemaID: schemaID, namespace: producer.namespace))
    }

    /// The compiled value of the switch (`nil` when absent, i.e. librime default off).
    public static func compiledValue(compiled: Data, target: Target) -> Bool? {
        guard let text = String(data: compiled, encoding: .utf8),
            let root = (try? BoundedYAML.load(yaml: text)) as? [String: Any],
            let section = root[target.namespace] as? [String: Any]
        else { return nil }
        return section[configLeaf] as? Bool
    }

    /// Enabled schema IDs from a compiled `build/default.yaml` (`schema_list`), in order.
    public static func enabledSchemaIDs(compiledDefault: Data) -> [String] {
        guard let text = String(data: compiledDefault, encoding: .utf8),
            let root = (try? BoundedYAML.load(yaml: text)) as? [String: Any],
            let list = root["schema_list"] as? [[String: Any]]
        else { return [] }
        var seen = Set<String>()
        return list.compactMap { $0["schema"] as? String }.filter { seen.insert($0).inserted }
    }

    /// Compiled `build/<id>.schema.yaml` bytes of the enabled schemas in `build/default.yaml`, in
    /// order; schemas without a compiled file (or rejected by `include`) are skipped.
    public static func enabledCompiledSchemas(
        build: URL, include: (String) -> Bool = { _ in true }
    ) -> [(id: String, compiled: Data)] {
        guard let defaults = try? Data(contentsOf: build.appendingPathComponent("default.yaml")) else { return [] }
        return enabledSchemaIDs(compiledDefault: defaults).compactMap { id in
            guard include(id),
                let compiled = try? Data(contentsOf: InstalledPackageLayout.compiledSchemaURL(build: build, id: id))
            else { return nil }
            return (id, compiled)
        }
    }

    /// The Rx identity `DeclarativeRecipePlan` assigns to this recipe for `packageReference`.
    public static func rx(packageReference: String) -> String {
        packageReference + ":" + recipeName + ":"
    }

    /// True when the user's own custom content (outside this recipe's managed block)
    /// mentions the switch. Such a schema is user-managed and is never patched.
    public static func userOwnsSetting(customYAML: Data?, packageReference: String) -> Bool {
        guard let customYAML, let text = String(data: customYAML, encoding: .utf8) else { return false }
        let marker = "# Rx: \(rx(packageReference: packageReference)) {"
        var inManaged = false
        for line in text.components(separatedBy: "\n") {
            if line == marker {
                inManaged = true
                continue
            }
            if inManaged {
                if line == "# }" { inManaged = false }
                continue
            }
            let content = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            if content.contains(configLeaf) { return true }
        }
        return false
    }

    /// Targets whose compiled state differs from `desired` and that the user does not manage.
    /// `current[schemaID] == nil` means the key is absent (librime default: off).
    public static func changes(
        desired: Bool, targets: [Target], current: [String: Bool],
        userManaged: Set<String>
    ) -> [Target] {
        targets.filter { !userManaged.contains($0.schemaID) && (current[$0.schemaID] ?? false) != desired }
            .sorted { $0.schemaID < $1.schemaID }
    }

    /// One declarative recipe, same shape as `GrammarModelRecipe`: one managed block per
    /// schema under the same Rx. `enabling` → `true`, `disabling` → explicit `false`.
    public static func make(enabling: [Target], disabling: [Target] = []) throws -> DeclarativeRecipe {
        let on = Array(Set(enabling)).sorted { $0.schemaID < $1.schemaID }
        let onIDs = Set(on.map(\.schemaID))
        let off = Array(Set(disabling)).filter { !onIDs.contains($0.schemaID) }.sorted { $0.schemaID < $1.schemaID }
        guard !(on.isEmpty && off.isEmpty) else {
            throw RecipeInstallError.invalidResource("没有需要调整错键纠正的输入方式")
        }
        for target in on + off {
            guard validIdentifier(target.schemaID),
                !CompactSchemaAdapter.isGeneratedCompanionID(target.schemaID),
                target.namespace.range(of: "^[A-Za-z0-9_]+$", options: .regularExpression) != nil
            else {
                throw RecipeInstallError.invalidResource("输入方式标识无效：\(target.schemaID)")
            }
        }
        var lines = [
            "recipe:",
            "  Rx: \(recipeName)",
            "  description: 错键纠正",
            "patch_files:",
        ]
        for (target, value) in on.map({ ($0, "true") }) + off.map({ ($0, "false") }) {
            lines.append("  \(target.schemaID).custom.yaml:")
            lines.append("    - patch/+:")
            lines.append("        \(target.configKey): \(value)")
        }
        return try DeclarativeRecipe(
            path: recipeName + ".recipe.yaml",
            source: Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    static func validIdentifier(_ id: String) -> Bool {
        id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
    }
}

public extension CompactSchemaAdapter {
    /// True for IDs minted by `identifier(sourceID:fold:)` (generated compact companions).
    static func isGeneratedCompanionID(_ id: String) -> Bool {
        id.range(of: "^keyboard_[0-9a-f]{20}_[0-9]+$", options: .regularExpression) != nil
    }
}
