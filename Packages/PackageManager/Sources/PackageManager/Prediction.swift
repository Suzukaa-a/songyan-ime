import Foundation
import Yams

/// Predictive text after commit (librime-predict): the `predictor` processor plus
/// `predict_translator`, reading a `Rime::Predict/1.0` database (`predictor/db`, resolved
/// from the user directory first, then the shared directory).
///
/// Pure logic; independent of any source or schema name, and ships no database:
///   * `validateDatabase`: reads only the header and the two internal table bounds
///     (never loads the whole database into memory);
///   * `eligibility`: decides from the **compiled** schema whether prediction can be wired.
///     Requires a single primary producer (`script_translator` / `table_translator`,
///     independent of the speller alphabet), a schema that is not a generated 14/9-key
///     companion, and one that does not already declare predictor / predict_translator
///     (those are left to the source). Companion schemas are generated from the source's
///     compiled config and inherit the predictor components as-is (prediction only sees
///     committed text, not spelling);
///   * `make`: builds a declarative patch like `TypoCorrection`'s, written as a separate
///     Rx-managed block in `<schema>.custom.yaml` (a rerun replaces only that block), and
///     optionally installs a user-imported database.
///
/// The caller proves it took effect with the real engine after deploy (components
/// registered, compiled config read back); otherwise it counts as unavailable (fail closed).
public enum Prediction {
    /// Recipe identity (`Rx`) of the managed block. Not tied to any source.
    public static let recipeName = "prediction"
    /// Install path of the user-imported database inside the installation's resources.
    public static let databasePath = "songyan-predict.db"
    /// Managed marker read back from the compiled schema (`true` = our block is active).
    public static let markerKey = "songyan_prediction"
    /// librime option consulted by `Predictor::OnContextUpdate`.
    public static let optionName = "prediction"
    public static let processor = "predictor"
    public static let translator = "predict_translator"
    /// Candidates offered after each commit (the candidate bar shows a single row).
    public static let maxCandidates = 8
    static let formatPrefix = Data("Rime::Predict/".utf8)
    static let metadataSize = 52

    public struct Target: Equatable, Hashable, Sendable {
        public let schemaID: String
        public init(schemaID: String) { self.schemaID = schemaID }
    }

    public enum Eligibility: Equatable, Sendable {
        case eligible(Target)
        /// The schema (or its source) already declares prediction itself.
        case sourceManaged
        case ineligible(String)

        public var target: Target? {
            if case .eligible(let target) = self { return target }
            return nil
        }
    }

    // MARK: - Database

    /// A root-level `*.db` resource: where librime-predict resolves `predictor/db`. Such files
    /// (ours, or one a source ships for its own `predictor`) travel as file resources and must
    /// pass `validateDatabase` before an installation takes them.
    public static func isDatabasePath(_ path: String) -> Bool {
        path.hasSuffix(".db") && path.count > 3 && !path.contains("/") && !path.hasPrefix(".")
    }

    /// Validates every prediction database among newly supplied file resources (fail closed).
    public static func validateDatabases(in resources: [String: RecipeFileResource]) throws {
        for (path, resource) in resources where isDatabasePath(path) {
            do { try validateDatabase(at: resource.url) } catch {
                throw RecipeInstallError.invalidResource("\(path) 不是有效的联想词库文件")
            }
        }
    }

    /// Structural check of a `Rime::Predict/*` file: header prefix, and both the key
    /// double-array and the value string table lie inside the file. Reads 52 bytes.
    public static func validateDatabase(at url: URL) throws {
        let file = try BoundedLocalFile(url, maximumBytes: RecipeResourceBudget.modelFile)
        try validateHeader(file.readPrefix(metadataSize), fileSize: file.size)
    }

    static func validateHeader(_ header: Data, fileSize: Int) throws {
        let bytes = [UInt8](header)
        guard bytes.count == metadataSize, header.starts(with: formatPrefix),
            bytes[0..<32].contains(0)
        else {
            throw RecipeInstallError.invalidResource("不是有效的联想词库文件（需为 Rime::Predict 格式）")
        }
        func u32(_ at: Int) -> UInt32 {
            UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
        }
        // OffsetPtr<char> is an int32 offset relative to the field itself.
        func region(pointer: Int, size: Int) -> Bool {
            let offset = Int(Int32(bitPattern: u32(pointer)))
            guard offset != 0, size > 0 else { return false }
            let start = pointer + offset
            return start >= metadataSize && start <= fileSize && size <= fileSize - start
        }
        guard region(pointer: 36, size: Int(u32(40)) * 4),  // Darts units are 4 bytes
            region(pointer: 44, size: Int(u32(48)))
        else {
            throw RecipeInstallError.invalidResource("联想词库结构不完整或已损坏")
        }
    }

    // MARK: - Eligibility

    public static func eligibility(compiled: Data, schemaID: String) -> Eligibility {
        guard TypoCorrection.validIdentifier(schemaID) else { return .ineligible("invalid schema id") }
        guard !CompactSchemaAdapter.isGeneratedCompanionID(schemaID) else {
            return .ineligible("generated compact companion")
        }
        guard compiled.count <= RecipeResourceBudget.sourceFile,
            let text = String(data: compiled, encoding: .utf8),
            let root = (try? BoundedYAML.load(yaml: text)) as? [String: Any]
        else {
            return .ineligible("compiled schema unreadable")
        }
        guard let schema = root["schema"] as? [String: Any],
            schema["schema_id"] as? String == schemaID
        else {
            return .ineligible("schema identity mismatch")
        }
        guard root["keyboard_rewrite"] == nil, root["keyboard_adapter"] == nil else {
            return .ineligible("compact keyboard adapter")
        }
        guard let engine = root["engine"] as? [String: Any],
            let processors = engine["processors"] as? [String],
            let translators = engine["translators"] as? [String]
        else {
            return .ineligible("engine lists unreadable")
        }
        let ours = (root[markerKey] as? Bool) != nil
        if !ours
            && (processors.contains(where: { component($0) == processor })
                || translators.contains(where: { component($0) == translator }))
        {
            return .sourceManaged
        }
        guard let producer = CompactSchemaAdapter.primaryProducer(translators: translators),
            producer.namespace.range(of: "^[A-Za-z0-9_]+$", options: .regularExpression) != nil,
            let section = root[producer.namespace] as? [String: Any],
            let dictionary = section["dictionary"] as? String, !dictionary.isEmpty
        else {
            return .ineligible("no single primary producer with a dictionary")
        }
        // No spelling requirement: prediction keys on commits, so native 9-key (digit) schemes
        // and 14/9-key companions predict like 26-key ones.
        return .eligible(Target(schemaID: schemaID))
    }

    /// True only when the compiled schema runs our managed block: marker, both components
    /// and the managed database name.
    public static func compiledEnabled(compiled: Data) -> Bool {
        guard let text = String(data: compiled, encoding: .utf8),
            let root = (try? BoundedYAML.load(yaml: text)) as? [String: Any],
            root[markerKey] as? Bool == true,
            let engine = root["engine"] as? [String: Any],
            let processors = engine["processors"] as? [String],
            let translators = engine["translators"] as? [String],
            (root["predictor"] as? [String: Any])?["db"] as? String == databasePath
        else { return false }
        return processors.contains(processor) && translators.contains(translator)
    }

    /// Both component lists carry the same prediction components (or both carry none).
    public static func sameWiring(_ lhs: [String], _ rhs: [String]) -> Bool {
        [processor, translator].allSatisfy { name in
            lhs.contains { component($0) == name } == rhs.contains { component($0) == name }
        }
    }

    static func component(_ prescription: String) -> String {
        String(prescription.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
    }

    /// The Rx identity `DeclarativeRecipePlan` assigns to this recipe for `packageReference`.
    public static func rx(packageReference: String) -> String {
        packageReference + ":" + recipeName + ":"
    }

    /// True when the user's own custom content (outside this recipe's managed block) touches
    /// prediction. Such a schema is user-managed and is never patched.
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
            if content.contains(processor) || content.contains(translator) || content.contains(markerKey) {
                return true
            }
        }
        return false
    }

    /// Targets whose compiled state differs from `desired` and that the user does not manage.
    public static func changes(
        desired: Bool, targets: [Target], current: [String: Bool],
        userManaged: Set<String>
    ) -> [Target] {
        targets.filter { !userManaged.contains($0.schemaID) && (current[$0.schemaID] ?? false) != desired }
            .sorted { $0.schemaID < $1.schemaID }
    }

    /// One declarative recipe: `installDatabase` installs the imported database once;
    /// `enabling` gets the full wiring, `disabling` gets a block that only records the
    /// managed marker as `false` (the earlier block is replaced, so nothing is inserted).
    public static func make(
        enabling: [Target], disabling: [Target] = [],
        installDatabase: Bool = false
    ) throws -> DeclarativeRecipe {
        let on = Array(Set(enabling)).sorted { $0.schemaID < $1.schemaID }
        let onIDs = Set(on.map(\.schemaID))
        let off = Array(Set(disabling)).filter { !onIDs.contains($0.schemaID) }.sorted { $0.schemaID < $1.schemaID }
        guard installDatabase || !(on.isEmpty && off.isEmpty) else {
            throw RecipeInstallError.invalidResource("没有需要调整上屏联想的输入方式")
        }
        for target in on + off {
            guard TypoCorrection.validIdentifier(target.schemaID),
                !CompactSchemaAdapter.isGeneratedCompanionID(target.schemaID)
            else {
                throw RecipeInstallError.invalidResource("输入方式标识无效：\(target.schemaID)")
            }
        }
        var lines = [
            "recipe:",
            "  Rx: \(recipeName)",
            "  description: 上屏联想",
        ]
        if installDatabase {
            lines.append("install_files:")
            lines.append("  - \(databasePath)")
        }
        lines.append("patch_files:")
        for target in on {
            lines += [
                "  \(target.schemaID).custom.yaml:",
                "    - patch/+:",
                "        engine/processors/@before 0: \(processor)",
                "        engine/translators/@before 0: \(translator)",
                "        switches/@next: {name: \(optionName), reset: 1}",
                "        predictor/db: \(databasePath)",
                "        predictor/max_candidates: \(maxCandidates)",
                "        predictor/max_iterations: 0",
                "        \(markerKey): true",
            ]
        }
        for target in off {
            lines += [
                "  \(target.schemaID).custom.yaml:",
                "    - patch/+:",
                "        \(markerKey): false",
            ]
        }
        return try DeclarativeRecipe(
            path: recipeName + ".recipe.yaml",
            source: Data((lines.joined(separator: "\n") + "\n").utf8))
    }
}
