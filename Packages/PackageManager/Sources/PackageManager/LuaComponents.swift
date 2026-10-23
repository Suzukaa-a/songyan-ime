import Foundation
import Yams

/// Per-schema on/off switches for the Lua components (`lua_processor@…`, `lua_segmentor@…`,
/// `lua_translator@…`, `lua_filter@…`) a source mounts in its compiled engine config.
///
/// Pure logic, no source or scheme names. Every Lua component stays enabled unless the user
/// turns it off. librime's patch syntax cannot delete a list item, so a switched-off
/// component is removed by assigning the affected `engine/<list>` in a managed Rx block of
/// `<schema>.custom.yaml`, computed from a recorded **baseline** (the source's own lists,
/// without our managed prediction components). Keys of a custom `patch` map are applied in
/// key order, so `engine/processors` is assigned before `engine/processors/@before 0` from the
/// prediction block: the two managed blocks compose in either order. With nothing switched
/// off the block records only `songyan_lua_managed: false`, which pins no list.
public enum LuaComponents {
    public static let recipeName = "lua_components"
    /// Source lists at the time the first component was switched off (read back from the
    /// compiled schema; restoring a component puts it back at its original position).
    public static let baselineKey = "songyan_lua_baseline"
    public static let managedKey = "songyan_lua_managed"
    public static let lists = ["processors", "segmentors", "translators", "filters"]

    public struct Component: Hashable, Sendable, Identifiable {
        public let list: String
        public let prescription: String
        public let enabled: Bool
        public var id: String { list + "/" + prescription }
        /// Processors see every key before the rest of the engine; turning one off can
        /// change how basic typing behaves.
        public var mayAffectBasicInput: Bool { list == "processors" }
        /// `lua_filter@*module*name` → `module*name`, the part users recognise.
        public var displayName: String {
            guard let at = prescription.firstIndex(of: "@") else { return prescription }
            let rest = prescription[prescription.index(after: at)...]
            return String(rest.hasPrefix("*") ? rest.dropFirst() : rest)
        }
    }

    public struct SchemaState: Equatable, Sendable {
        public let schemaID: String
        /// `schema/name`, or the ID when absent.
        public let name: String
        public let components: [Component]
        public let baseline: [String: [String]]
        public var disabled: Set<String> { Set(components.filter { !$0.enabled }.map(\.prescription)) }
    }

    public static func isLua(_ prescription: String) -> Bool {
        let kind = Prediction.component(prescription)
        return ["lua_processor", "lua_segmentor", "lua_translator", "lua_filter"].contains(kind)
    }

    /// Reads the compiled schema. `nil` when unreadable or not the schema asked for (fail closed).
    public static func state(compiled: Data, schemaID: String) -> SchemaState? {
        guard TypoCorrection.validIdentifier(schemaID), compiled.count <= RecipeResourceBudget.sourceFile,
            let text = String(data: compiled, encoding: .utf8),
            let root = (try? BoundedYAML.load(yaml: text)) as? [String: Any],
            (root["schema"] as? [String: Any])?["schema_id"] as? String == schemaID,
            let engine = root["engine"] as? [String: Any]
        else { return nil }
        var current: [String: [String]] = [:]
        for list in lists {
            guard let value = engine[list] else { continue }
            guard let items = value as? [String] else { return nil }
            current[list] = items
        }
        let baseline: [String: [String]]
        if let recorded = root[baselineKey] as? [String: Any] {
            var lists: [String: [String]] = [:]
            for (key, value) in recorded {
                guard Self.lists.contains(key), let items = value as? [String] else { return nil }
                lists[key] = items
            }
            baseline = lists
        } else {
            baseline = withoutManagedPrediction(current, root: root)
        }
        var components: [Component] = []
        for list in lists {
            for item in baseline[list] ?? [] where isLua(item) {
                components.append(
                    Component(
                        list: list, prescription: item,
                        enabled: (current[list] ?? []).contains(item)))
            }
        }
        let name = ((root["schema"] as? [String: Any])?["name"]).map { String(describing: $0) } ?? schemaID
        return SchemaState(schemaID: schemaID, name: name, components: components, baseline: baseline)
    }

    /// Our prediction block inserts its components on top of whatever lists are assigned, so
    /// they never belong to a Lua baseline.
    static func withoutManagedPrediction(_ lists: [String: [String]], root: [String: Any]) -> [String: [String]] {
        guard root[Prediction.markerKey] as? Bool == true else { return lists }
        var result = lists
        result["processors"] = lists["processors"]?.filter { Prediction.component($0) != Prediction.processor }
        result["translators"] = lists["translators"]?.filter { Prediction.component($0) != Prediction.translator }
        return result
    }

    /// Lists the managed block assigns: the baseline minus `disabled`, only for lists that
    /// actually lose something.
    public static func assignedLists(baseline: [String: [String]], disabled: Set<String>) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for list in lists {
            guard let items = baseline[list], items.contains(where: disabled.contains) else { continue }
            result[list] = items.filter { !disabled.contains($0) }
        }
        return result
    }

    public static func rx(packageReference: String) -> String {
        packageReference + ":" + recipeName + ":"
    }

    /// True when the user's own custom content (outside this recipe's block and our other
    /// managed blocks) edits engine lists; such a schema is left to the user.
    public static func userOwnsSetting(customYAML: Data?) -> Bool {
        guard let customYAML, let text = String(data: customYAML, encoding: .utf8) else { return false }
        var inManaged = false
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("# Rx: "), line.hasSuffix(" {") {
                inManaged = true
                continue
            }
            if inManaged {
                if line == "# }" { inManaged = false }
                continue
            }
            let content = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            if content.contains("engine/") || content.contains(baselineKey) { return true }
            if content.trimmingCharacters(in: .whitespaces).hasPrefix("engine:") { return true }
        }
        return false
    }

    /// One recipe for one input method. Every prescription in `disabled` must be a Lua
    /// component of `baseline`; an empty set writes the marker-only block.
    public static func make(schemaID: String, baseline: [String: [String]], disabled: Set<String>) throws
        -> DeclarativeRecipe
    {
        guard TypoCorrection.validIdentifier(schemaID), !CompactSchemaAdapter.isGeneratedCompanionID(schemaID) else {
            throw RecipeInstallError.invalidResource("输入方式标识无效：\(schemaID)")
        }
        let known = Set(lists.flatMap { baseline[$0] ?? [] }.filter(isLua))
        guard disabled.isSubset(of: known) else { throw RecipeInstallError.invalidResource("不是属于此输入方式的 Lua 组件") }
        var lines = [
            "recipe:",
            "  Rx: \(recipeName)",
            "  description: Lua 组件开关",
            "patch_files:",
            "  \(schemaID).custom.yaml:",
            "    - patch/+:",
        ]
        if disabled.isEmpty {
            lines.append("        \(managedKey): false")
        } else {
            let assigned = assignedLists(baseline: baseline, disabled: disabled)
            for list in lists {
                guard let items = assigned[list] else { continue }
                lines.append("        engine/\(list): [\(items.map(quoted).joined(separator: ", "))]")
            }
            lines.append("        \(managedKey): true")
            let recorded = lists.compactMap { list in
                baseline[list].map { "\(list): [\($0.map(quoted).joined(separator: ", "))]" }
            }
            lines.append("        \(baselineKey): {\(recorded.joined(separator: ", "))}")
        }
        return try DeclarativeRecipe(
            path: recipeName + ".recipe.yaml",
            source: Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    /// JSON string literal: valid YAML flow scalar for any prescription.
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

    /// Checks a deployed compiled schema against the intended state: each list equals the
    /// baseline minus `disabled` (our managed prediction components aside).
    public static func matches(compiled: Data, schemaID: String, baseline: [String: [String]], disabled: Set<String>)
        -> Bool
    {
        guard let text = String(data: compiled, encoding: .utf8),
            let root = (try? BoundedYAML.load(yaml: text)) as? [String: Any],
            (root["schema"] as? [String: Any])?["schema_id"] as? String == schemaID,
            let engine = root["engine"] as? [String: Any]
        else { return false }
        var current: [String: [String]] = [:]
        for list in lists { if let items = engine[list] as? [String] { current[list] = items } }
        let effective = withoutManagedPrediction(current, root: root)
        for list in lists {
            let expected = (baseline[list] ?? []).filter { !disabled.contains($0) }
            guard (effective[list] ?? []) == expected else { return false }
        }
        return true
    }
}
