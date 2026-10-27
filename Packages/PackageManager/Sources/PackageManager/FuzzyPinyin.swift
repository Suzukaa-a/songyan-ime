import Foundation
import Yams

/// Fuzzy pinyin. The feature is a patch of the schema's own `speller/algebra`, applied
/// through Rime's native `fuzz/<pattern>/<replacement>/` calculus: librime derives an extra
/// spelling, tags it `kFuzzySpelling` and only then applies a log(0.5) credibility penalty,
/// so the original normal spelling is produced first and survives. Nothing here rewrites a
/// keystroke, and nothing here talks to the engine.
///
/// Our rules go BEFORE the schema's own, one list insertion per rule
/// (`speller/algebra/@before 00`, `@before 01`, ...). The schema's rules are never restated:
/// the engine keeps its list byte for byte (including `$1` back-references and rules from
/// `__include`/`__patch`, which a recipe body cannot carry). Placing the rules first means
/// they act on the dictionary's full-pinyin spellings, so they also work for schemas whose
/// own rules later convert pinyin into 双拼 key codes. Removing our managed block restores
/// the original behaviour exactly. Blocks written by older versions appended with
/// `speller/algebra/+` (after the conversion); they are still read, and the next save
/// rewrites them in the new form.
///
/// Pure logic, no source or scheme names:
///   * `eligibility`: decides from the **compiled** schema whether the feature can be
///     offered (sole script_translator primary producer with a dictionary, full a-z
///     alphabet, not a generated 14/9-key companion);
///   * `make`: one managed Rx block per schema in `<schema>.custom.yaml`;
///   * `userOwnsSetting`: a user who writes `algebra` outside our managed blocks keeps the
///     setting; we never overwrite it.
public enum FuzzyPinyin {
    /// Recipe identity (`Rx`) of the managed block. Not tied to any source.
    public static let recipeName = "fuzzy-pinyin"
    /// Schema-level key we patch, into whose list the derivations are inserted.
    public static let configLeaf = "algebra"
    static let algebraKey = "speller/" + configLeaf
    /// Rime's list insertion path. Keys are zero-padded so that the engine, which applies
    /// patch keys in sorted order, inserts rule N at index N and keeps our order.
    static let insertKeyPrefix = algebraKey + "/@before "
    static func insertKey(_ index: Int) -> String {
        insertKeyPrefix + (index < 10 ? "0" : "") + String(index)
    }

    /// One bounded, commonly confused pair. `id` is the stable identifier preferences are
    /// stored with; `label` is the natural Chinese-facing pairing.
    public struct Pair: Equatable, Hashable, Sendable, Identifiable, CaseIterable {
        public static let zZh = Pair(
            id: "z-zh", label: "z／zh",
            rules: ["fuzz/^zh/z/", "fuzz/^z(?!h)/zh/"])
        public static let cCh = Pair(
            id: "c-ch", label: "c／ch",
            rules: ["fuzz/^ch/c/", "fuzz/^c(?!h)/ch/"])
        public static let sSh = Pair(
            id: "s-sh", label: "s／sh",
            rules: ["fuzz/^sh/s/", "fuzz/^s(?!h)/sh/"])
        public static let anAng = Pair(
            id: "an-ang", label: "an／ang",
            rules: ["fuzz/an(?!g)/ang/", "fuzz/ang/an/"])
        public static let enEng = Pair(
            id: "en-eng", label: "en／eng",
            rules: ["fuzz/en(?!g)/eng/", "fuzz/eng/en/"])
        public static let inIng = Pair(
            id: "in-ing", label: "in／ing",
            rules: ["fuzz/in(?!g)/ing/", "fuzz/ing/in/"])
        public static let nL = Pair(
            id: "n-l", label: "n／l",
            rules: ["fuzz/^n/l/", "fuzz/^l/n/"])
        public static let fH = Pair(
            id: "f-h", label: "f／h",
            rules: ["fuzz/^f/h/", "fuzz/^h/f/"])

        public let id: String
        public let label: String
        /// Both directions of the pair. Lookahead stands in for `$`, which a recipe patch body
        /// cannot carry (Rime assigns patch variables with it): `^z(?!h)` keeps `zhong` from
        /// becoming `zhhong`, and `an(?!g)` reaches `ban` without mangling `nang`.
        /// Rule text must not contain `$`, backslashes, backticks or double quotes.
        public let rules: [String]

        /// Stable order for every consumer of the pair list.
        public static var allCases: [Pair] { [.zZh, .cCh, .sSh, .anAng, .enEng, .inIng, .nL, .fH] }
    }

    /// Every selectable pair, in a stable order.
    public static let allPairs: [Pair] = Pair.allCases

    /// The pair with this stored identifier.
    public static func pair(id: String) -> Pair? {
        allPairs.first { $0.id == id }
    }

    /// The derivations for these pair identifiers, in `allPairs` order so the generated
    /// recipe is deterministic for any set. `nil` when an identifier is unknown.
    public static func rules(pairIDs: Set<String>) -> [String]? {
        var known = Set<String>()
        for pair in allPairs where pairIDs.contains(pair.id) { known.insert(pair.id) }
        guard known == pairIDs else { return nil }
        return allPairs.filter { pairIDs.contains($0.id) }.flatMap(\.rules)
    }

    /// The pairs a rule list covers, for reading our own block back. `nil` when the list is
    /// not exactly what we generate, so an edited block is never read as a state we can act on.
    public static func pairIDs(rules: [String]) -> Set<String>? {
        if rules.isEmpty { return [] }
        return pairIDs(covering: rules[...])
    }

    /// Our rules are generated as one contiguous run in `allPairs` order, so a list is ours
    /// exactly when it can be consumed pair by pair in that order.
    private static func pairIDs(covering rules: ArraySlice<String>) -> Set<String>? {
        var cursor = rules.startIndex
        var found = Set<String>()
        for pair in allPairs {
            guard cursor < rules.endIndex else { break }
            let needed = pair.rules
            guard rules.distance(from: cursor, to: rules.endIndex) >= needed.count else { continue }
            let end = rules.index(cursor, offsetBy: needed.count)
            guard Array(rules[cursor..<end]) == needed else { continue }
            cursor = end
            found.insert(pair.id)
        }
        return cursor == rules.endIndex && !found.isEmpty ? found : nil
    }

    /// One schema whose algebra the fuzzy layer can patch.
    public struct Target: Equatable, Hashable, Sendable {
        public let schemaID: String
        /// Primary producer namespace. Diagnostics only: the patched key is schema-level.
        public let namespace: String
        public init(schemaID: String, namespace: String) {
            self.schemaID = schemaID
            self.namespace = namespace
        }
        public var configKey: String { algebraKey }
    }

    public enum Eligibility: Equatable, Sendable {
        case eligible(Target)
        case ineligible(String)

        public var target: Target? {
            if case .eligible(let target) = self { return target }
            return nil
        }
    }

    static let defaultSpellerAlphabet = "zyxwvutsrqponmlkjihgfedcba"
    static let fullAlphabet = Set("abcdefghijklmnopqrstuvwxyz")

    /// Structural eligibility from a compiled schema (`build/<id>.schema.yaml`). Never
    /// throws: anything that cannot be proven eligible is `.ineligible` (fail closed).
    /// Whether the schema really is full pinyin is not decided here; the host checks the
    /// engine's native projection, not a name or shape guess.
    public static func eligibility(compiled: Data, schemaID: String) -> Eligibility {
        guard TypoCorrection.validIdentifier(schemaID) else { return .ineligible("输入方式标识无效") }
        guard !CompactSchemaAdapter.isGeneratedCompanionID(schemaID) else {
            return .ineligible("这个输入方式由其他输入方式自动生成，请在原来的输入方式里设置模糊音。")
        }
        guard compiled.count <= RecipeResourceBudget.sourceFile,
            let text = String(data: compiled, encoding: .utf8),
            let loaded = try? BoundedYAML.load(yaml: text),
            let root = loaded as? [String: Any]
        else {
            return .ineligible("输入方案配置无法读取")
        }
        guard let schema = root["schema"] as? [String: Any], schema["schema_id"] as? String == schemaID else {
            return .ineligible("这个输入方式的设置文件不完整，请重新导入输入方案。")
        }
        guard root["keyboard_rewrite"] == nil, root["keyboard_adapter"] == nil else {
            return .ineligible("这个输入方式专供 9 键或 14 键键盘使用，暂不支持模糊音。")
        }
        guard let engine = root["engine"] as? [String: Any],
            let translators = engine["translators"] as? [String],
            let producer = CompactSchemaAdapter.primaryProducer(translators: translators)
        else {
            return .ineligible("这个输入方式不是拼音输入，暂不支持模糊音。")
        }
        guard producer.klass == .script else { return .ineligible("这个输入方式不是拼音输入，暂不支持模糊音。") }
        guard producer.namespace.range(of: "^[A-Za-z0-9_]+$", options: .regularExpression) != nil,
            let section = root[producer.namespace] as? [String: Any],
            let dictionary = section["dictionary"] as? String, !dictionary.isEmpty
        else {
            return .ineligible("输入方式没有可用的词典")
        }
        let speller = root["speller"] as? [String: Any]
        // An unquoted numeric alphabet loads as a number, not a string; any present-but
        // non-string value is taken literally, never as the default alphabet.
        let alphabet: String
        switch speller?["alphabet"] {
        case nil: alphabet = defaultSpellerAlphabet
        case let value as String: alphabet = value
        case let value?: alphabet = String(describing: value)
        }
        guard fullAlphabet.isSubset(of: Set(alphabet)) else {
            return .ineligible("当前输入方式的拼写设置暂不支持模糊音")
        }
        return .eligible(Target(schemaID: schemaID, namespace: producer.namespace))
    }

    // MARK: - Schema algebra

    /// The compiled schema's `speller/algebra` list: `nil` when unreadable, mismatched, or
    /// present but not a list of scalars. `[]` when the schema declares none.
    public static func compiledAlgebra(compiled: Data, schemaID: String) -> [String]? {
        guard TypoCorrection.validIdentifier(schemaID), compiled.count <= RecipeResourceBudget.sourceFile,
            let text = String(data: compiled, encoding: .utf8),
            let root = (try? BoundedYAML.load(yaml: text)) as? [String: Any],
            (root["schema"] as? [String: Any])?["schema_id"] as? String == schemaID
        else { return nil }
        guard let speller = root["speller"] as? [String: Any], speller[configLeaf] != nil else { return [] }
        return speller[configLeaf] as? [String]
    }

    /// The human-readable `schema/name` of a compiled schema, for messages; `nil` when absent.
    public static func schemaName(compiled: Data) -> String? {
        guard compiled.count <= RecipeResourceBudget.sourceFile,
            let text = String(data: compiled, encoding: .utf8),
            let root = (try? BoundedYAML.load(yaml: text)) as? [String: Any],
            let name = (root["schema"] as? [String: Any])?["name"] as? String,
            !name.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        return name
    }

    /// The Rx identity `DeclarativeRecipePlan` assigns to this recipe for `packageReference`.
    public static func rx(packageReference: String) -> String {
        packageReference + ":" + recipeName + ":"
    }

    // MARK: - Current managed state

    /// The derivations our managed block currently inserts, or `nil` when this schema is
    /// not managed by this invocation (no block, unreadable block, or an edited one).
    /// `[]` means the block is ours and adds nothing, i.e. the feature is off and the
    /// schema behaves exactly as it does without us.
    public static func managedAlgebra(customYAML: Data?, packageReference: String) -> [String]? {
        guard let customYAML, let text = String(data: customYAML, encoding: .utf8) else { return nil }
        let marker = "# Rx: \(rx(packageReference: packageReference)) {"
        var body: [String]?
        var inManaged = false
        var lines: [String] = []
        for line in text.components(separatedBy: "\n") {
            if !inManaged {
                if line == marker {
                    inManaged = true
                    lines = []
                }
                continue
            }
            if line == "# }" {
                body = lines
                inManaged = false
                break
            }
            lines.append(line)
        }
        guard let body,
            let root = (try? BoundedYAML.load(yaml: "__patch:\n" + body.joined(separator: "\n"))) as? [String: Any],
            let list = root["__patch"] as? [[String: Any]], list.count == 1,
            let map = list[0]["patch/+"] as? [String: Any]
        else { return nil }
        // Exactly the keys we generate, in order; anything else is an edited block.
        let keys = map.keys.sorted()
        guard keys == (0..<keys.count).map(insertKey) else { return nil }
        var rules: [String] = []
        for key in keys {
            guard let rule = map[key] as? String else { return nil }
            rules.append(rule)
        }
        return rules
    }

    /// True when anything outside OUR managed block edits the algebra: the user's own
    /// `patch`, or another invocation's block, which owns its rules just as the user does.
    /// Only our exact marker is skipped, so a different recipe that patches the same key is
    /// never treated as ours and never silently overwritten.
    public static func userOwnsSetting(customYAML: Data?, packageReference: String) -> Bool {
        guard let customYAML, let text = String(data: customYAML, encoding: .utf8) else { return false }
        let marker = "# Rx: \(rx(packageReference: packageReference)) {"
        var inOurs = false
        for line in text.components(separatedBy: "\n") {
            if inOurs {
                if line == "# }" { inOurs = false }
                continue
            }
            if line == marker {
                inOurs = true
                continue
            }
            let content = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            if touchesAlgebraKey(content) { return true }
        }
        return false
    }

    /// Whether one line of content assigns the algebra **key**. Matching the key rather than
    /// the bare word keeps an unrelated value (a schema named `algebra`, prose in a comment)
    /// from being read as a setting.
    static func touchesAlgebraKey(_ content: some StringProtocol) -> Bool {
        var trimmed = content.trimmingCharacters(in: .whitespaces)
        // A `__patch` list entry (`- speller/algebra:`) names the key just like a map line.
        while trimmed.hasPrefix("- ") { trimmed = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces) }
        guard !trimmed.isEmpty else { return false }
        let keys = [algebraKey, configLeaf]
        // YAML allows the key quoted: `"speller/algebra":`, `'speller/algebra/+':`.
        if let quote = trimmed.first, quote == "\"" || quote == "'" {
            let body = trimmed.dropFirst()
            guard let close = body.firstIndex(of: quote) else { return false }
            let key = body[..<close]
            let rest = body[body.index(after: close)...].trimmingCharacters(in: .whitespaces)
            return rest.hasPrefix(":") && keys.contains { key == $0 || key.hasPrefix($0 + "/") }
        }
        // `speller/algebra:`, and the append/assign operators `speller/algebra/+:`.
        for key in keys where trimmed.hasPrefix(key) {
            let rest = trimmed.dropFirst(key.count)
            if rest.hasPrefix(":") || rest.hasPrefix("/") { return true }
        }
        // Flow style: `speller: {algebra: [...]}`, with the inner key bare or quoted.
        return trimmed.contains("speller") && ["", "\"", "'"].contains { trimmed.contains(configLeaf + $0 + ":") }
    }

    // MARK: - Save planning

    /// What one save of the settings page amounts to. Refusal and "nothing to do" are kept
    /// apart so the caller never records a choice that was not applied.
    public enum SavePlan: Equatable {
        /// The input method already appends exactly the requested pairs.
        case noChange
        /// The save cannot be applied; the reason is ready to show to the user.
        case refused(String)
        case planned(Planned)
    }

    /// ALL managed targets (the map keys — the recipe requires exactly these), the changed one,
    /// and the full per-schema pair map.
    public struct Planned: Equatable {
        public let targets: [Target]
        public let changed: Target
        public let pairIDsBySchema: [String: Set<String>]
    }

    /// Plans a save for the ONE input method the settings page displayed — never every enabled
    /// schema. Every other eligible input method keeps its own managed pairs: they are
    /// re-stated in the same Rx (byte-identical when unchanged) instead of being silently reset.
    /// `build` is the installation's compiled directory (`default.yaml`, `<id>.schema.yaml`).
    public static func plan(
        schemaID: String, enabledPairIDs: Set<String>, build: URL,
        customFiles: [String: Data], packageReference: String
    ) -> SavePlan {
        guard let defaults = try? Data(contentsOf: build.appendingPathComponent("default.yaml")),
            TypoCorrection.enabledSchemaIDs(compiledDefault: defaults).contains(schemaID)
        else {
            return .refused("这个输入方式还没有启用，请在「我的键盘」中重新选择后再试。")
        }
        guard
            let compiled = try? Data(contentsOf: InstalledPackageLayout.compiledSchemaURL(build: build, id: schemaID)),
            let changed = eligibility(compiled: compiled, schemaID: schemaID).target
        else {
            return .refused("这个输入方式暂不支持模糊音，请选择其他输入方式。")
        }
        let changedCustom = customFiles[schemaID + ".custom.yaml"]
        guard !userOwnsSetting(customYAML: changedCustom, packageReference: packageReference) else {
            return .refused("模糊音已由你的自定义设置决定，请在自定义设置里修改。")
        }
        let changedAppended = managedAlgebra(customYAML: changedCustom, packageReference: packageReference)
        guard changedAppended.flatMap(pairIDs(rules:)) != enabledPairIDs else {
            return .noChange
        }
        var targets: [Target] = [changed]
        // Every other eligible input method keeps its currently saved value (an absent block
        // keeps meaning off, expressed as an empty append that touches nothing).
        var pairsBySchema: [String: Set<String>] = [schemaID: enabledPairIDs]
        for id in TypoCorrection.enabledSchemaIDs(compiledDefault: defaults) where id != schemaID {
            guard let other = try? Data(contentsOf: InstalledPackageLayout.compiledSchemaURL(build: build, id: id)),
                let target = eligibility(compiled: other, schemaID: id).target
            else { continue }
            let custom = customFiles[id + ".custom.yaml"]
            // A user-managed or foreign-managed input method never enters our Rx map.
            guard !userOwnsSetting(customYAML: custom, packageReference: packageReference) else { continue }
            let appended = managedAlgebra(customYAML: custom, packageReference: packageReference)
            guard let current = appended.flatMap(pairIDs(rules:)) else { continue }
            pairsBySchema[id] = current
            targets.append(target)
        }
        return .planned(Planned(targets: targets, changed: changed, pairIDsBySchema: pairsBySchema))
    }

    // MARK: - Recipe generation

    /// One declarative recipe, same shape as `TypoCorrection.make`, with the same pair set
    /// for every target.
    public static func make(enabledPairIDs: Set<String>, targets: [Target]) throws -> DeclarativeRecipe {
        var bySchema: [String: Set<String>] = [:]
        for target in targets { bySchema[target.schemaID] = enabledPairIDs }
        return try make(enabledPairIDsBySchema: bySchema, targets: targets)
    }

    /// Per-input-method pairs: one managed block per schema under the same Rx, inserting that
    /// schema's derivations at the start of its own `speller/algebra`.
    ///
    /// `enabledPairIDsBySchema` must name exactly the target schemas, because a missing one
    /// would be written as switched off. Callers changing one method pass the others' current
    /// pairs so their blocks are rewritten byte-for-byte unchanged.
    public static func make(
        enabledPairIDsBySchema: [String: Set<String>],
        targets: [Target]
    ) throws -> DeclarativeRecipe {
        let schemas = Set(targets.map(\.schemaID)).sorted()
        guard !schemas.isEmpty else { throw RecipeInstallError.invalidResource("没有需要调整模糊音的输入方式") }
        guard Set(enabledPairIDsBySchema.keys) == Set(schemas) else {
            throw RecipeInstallError.invalidResource("模糊音设置与输入方式不一致，请重新打开设置")
        }
        var appendedBySchema: [String: [String]] = [:]
        for schemaID in schemas {
            guard let appended = rules(pairIDs: enabledPairIDsBySchema[schemaID] ?? []) else {
                throw RecipeInstallError.invalidResource("无法识别的模糊音设置")
            }
            appendedBySchema[schemaID] = appended
        }
        for schemaID in schemas {
            guard TypoCorrection.validIdentifier(schemaID),
                !CompactSchemaAdapter.isGeneratedCompanionID(schemaID)
            else {
                throw RecipeInstallError.invalidResource("输入方式标识无效：\(schemaID)")
            }
        }
        var lines = [
            "recipe:",
            "  Rx: \(recipeName)",
            "  description: 模糊音",
            "patch_files:",
        ]
        for schemaID in schemas {
            let appended = appendedBySchema[schemaID] ?? []
            lines.append("  \(schemaID).custom.yaml:")
            if appended.isEmpty {
                lines.append("    - patch/+: {}")
                continue
            }
            lines.append("    - patch/+:")
            for (index, rule) in appended.enumerated() {
                lines.append("        \(quoted(insertKey(index))): \(quoted(rule))")
            }
        }
        return try DeclarativeRecipe(
            path: recipeName + ".recipe.yaml",
            source: Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    /// JSON string literal: valid YAML flow scalar for any rule. Same as
    /// `LuaComponents.quoted`; kept local so the two features stay independent.
    static func quoted(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
