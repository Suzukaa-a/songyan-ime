import Foundation
import KeyboardCore
import Yams

/// Installation-time discovery only; it never disables source grammar or claims
/// that a file is compatible. Deployed config and live GramDb are checked later.
public enum SchemeGrammarRequirements {
    public static func paths(in files: [String: Data]) -> [String] {
        discover(in: files).paths
    }

    public struct Discovery: Sendable {
        public let paths: [String]
        public let diagnostics: [String]
    }

    /// Resolve only installation configuration, never recipe source declarations.
    /// A selected recipe participates through its generated *.custom.yaml output.
    /// This is a bounded grammar/entry projection, not a replacement ConfigCompiler:
    /// indeterminate relevant expressions become diagnostics, not mandatory downloads.
    public static func discover(in files: [String: Data]) -> Discovery {
        var paths = Set<String>(), diagnostics: [String] = [], resolving = Set<String>(),
            resolvingScalars = Set<String>()
        enum Unknown: Error { case configuration }
        func merge(_ lhs: [String: Any], _ rhs: [String: Any]) -> [String: Any] {
            var result = lhs
            for (key, value) in rhs {
                if let a = result[key] as? [String: Any], let b = value as? [String: Any] {
                    result[key] = merge(a, b)
                } else {
                    result[key] = value
                }
            }
            return result
        }
        func referenceValue(_ text: String) throws -> Any {
            guard let colon = text.firstIndex(of: ":") else { throw Unknown.configuration }
            let name = String(text[..<colon])
            let file = name.hasSuffix(".yaml") ? name : name + ".yaml"
            // Recipes are executable inputs to the planner, never config includes.
            guard !file.hasSuffix(".recipe.yaml"), SchemeSourceCheck.safe(file),
                !resolving.contains(text), resolving.count < 128
            else { throw Unknown.configuration }
            guard let data = files[file] else {
                if text.hasSuffix("?") { return [:] }
                throw Unknown.configuration
            }
            resolving.insert(text)
            defer { resolving.remove(text) }
            guard let raw = try BoundedYAML.load(yaml: String(decoding: data, as: UTF8.self)) else {
                throw Unknown.configuration
            }
            var value: Any = raw
            if let map = raw as? [String: Any] {
                var effective = try evaluate(map)
                // ConfigCompiler references a schema's effective configuration,
                // including that schema's own custom, before selecting a subtree.
                // Do not enumerate other schemas/custom files from the inventory.
                if file.hasSuffix(".schema.yaml") || file == "default.yaml" {
                    let customName = file.hasSuffix(".schema.yaml") ? String(file.dropLast(12)) : "default"
                    if files[customName + ".custom.yaml"] != nil {
                        let custom = try reference(customName + ".custom:/")
                        if let patchValue = custom["patch"] { try patch(patchValue, into: &effective) }
                        try patch(
                            custom.filter {
                                ["grammar", "grammar/language", "schema_list", "schema"].contains($0.key)
                            }, into: &effective)
                    }
                }
                value = effective
            }
            let path = text[text.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: "/?"))
            for key in path.split(separator: "/") {
                guard let child = (value as? [String: Any])?[String(key)] else {
                    if text.hasSuffix("?") { return [:] }
                    throw Unknown.configuration
                }
                value = child
            }
            if !path.isEmpty, let node = value as? [String: Any] {
                // Resolve the selected node while the reference is still on the
                // stack. This also permits chains ending in a scalar and detects
                // map/subtree cycles before unwinding the reference guard.
                if node.count == 1, let include = node["__include"] as? String { return try referenceValue(include) }
                return try evaluate(node)
            }
            return value
        }
        func reference(_ text: String) throws -> [String: Any] {
            guard let map = try referenceValue(text) as? [String: Any] else { throw Unknown.configuration }
            return map
        }
        func scalar(_ value: Any) throws -> String? {
            if value is NSNull { return nil }
            if let text = value as? String { return text }
            if let node = value as? [String: Any], node.count == 1,
                let include = node["__include"] as? String
            {
                guard resolvingScalars.count < 128, resolvingScalars.insert(include).inserted else {
                    throw Unknown.configuration
                }
                defer { resolvingScalars.remove(include) }
                return try scalar(referenceValue(include))
            }
            // A present non-scalar language is not evidence of 'no grammar'.
            throw Unknown.configuration
        }
        func patch(_ value: Any, into result: inout [String: Any]) throws {
            if let text = value as? String {
                try patch(reference(text), into: &result)
            } else if let list = value as? [Any] {
                for item in list { try patch(item, into: &result) }
            } else if let map = value as? [String: Any] {
                for key in map.keys.sorted() {
                    let value = map[key]!
                    if key == "patch/+" || key == "patch" {
                        try patch(value, into: &result)
                    } else if ["grammar", "schema_list", "schema", "language"].contains(key) {
                        result[key] = value
                    } else if key == "grammar/language" {
                        var grammar = result["grammar"] as? [String: Any] ?? [:]
                        grammar["language"] = value
                        result["grammar"] = grammar
                    } else if key == "schema/dependencies" {
                        var schema = result["schema"] as? [String: Any] ?? [:]
                        schema["dependencies"] = value
                        result["schema"] = schema
                    } else if key.hasPrefix("grammar") || key.hasPrefix("language") || key.hasPrefix("schema_list")
                        || key.hasPrefix("schema/dependencies") || key == "__patch" || key == "__include"
                    {
                        throw Unknown.configuration
                    }
                }
            } else {
                throw Unknown.configuration
            }
        }
        func evaluate(_ map: [String: Any]) throws -> [String: Any] {
            var result: [String: Any] = [:]
            if let include = map["__include"] {
                guard let text = include as? String else { throw Unknown.configuration }
                result = try reference(text)
            }
            result = merge(result, map.filter { !$0.key.hasPrefix("__") })
            if let patches = map["__patch"] { try patch(patches, into: &result) }
            return result
        }
        func configuration(_ name: String) throws -> [String: Any] {
            try reference(name + ":/")
        }
        var entries: [String] = []
        do {
            if files["default.yaml"] != nil {
                let config = try configuration("default")
                guard let list = config["schema_list"] as? [[String: Any]], list.allSatisfy({ $0["schema"] is String })
                else { throw Unknown.configuration }
                entries = list.compactMap { $0["schema"] as? String }
            } else {
                // Same fallback as SharedRimePresets when no source default exists.
                entries = InstalledPackageLayout.topLevelSchemaFiles(in: files.keys).map {
                    String($0.dropLast(12))
                }
            }
        } catch { diagnostics.append("启用哪些输入方式要到安装时才能确定。") }
        var visited = Set<String>()
        func visit(_ id: String) {
            guard visited.insert(id).inserted, visited.count <= 256 else { return }
            do {
                let config = try configuration(id + ".schema")
                if let grammar = config["grammar"] as? [String: Any],
                    let value = try evaluate(grammar)["language"],
                    let language = try scalar(value), !language.isEmpty
                {
                    let path = language + ".gram"
                    guard GrammarModelPath.isValid(path) else { throw Unknown.configuration }
                    paths.insert(path)
                }
                if let schema = config["schema"] as? [String: Any] {
                    for dependency in try evaluate(schema)["dependencies"] as? [String] ?? [] { visit(dependency) }
                }
            } catch { diagnostics.append("\(id) 需要哪些模型要到安装时才能确定。") }
        }
        for entry in entries.sorted() { visit(entry) }
        return Discovery(paths: paths.sorted(), diagnostics: diagnostics)
    }

    /// Curated upstream location, offered explicitly; never an automatic download.
    public static func suggestedURL(for path: String) -> URL? {
        guard ["wanxiang-lts-zh-hans.gram", "wanxiang-lts-zh-hant.gram"].contains(path) else { return nil }
        return URL(string: "https://github.com/amzxyz/RIME-LMDG/releases/download/LTS/" + path)
    }
}
