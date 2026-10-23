// Test-only double for the librime config C API. The real `rime_get_api` lives in the
// RimeKit XCFramework (iOS-only), so the offline state-machine probe implements the few
// `config_*` entry points the store's `resolvedSchemas`/`deployedSchemas` use. This is a
// fixture, not a copy of any production implementation.
final class RimeConfigBox {
    var list: [String] = []  // schema_list order
    var values: [String: String] = [:]  // flattened key -> value
}

struct RimeConfig {
    var box: RimeConfigBox?
}

struct RimeApi {
    let config_close: (inout RimeConfig) -> Bool
    let config_load_string: (inout RimeConfig, UnsafePointer<CChar>) -> Int32
    let config_list_size: (inout RimeConfig, UnsafePointer<CChar>) -> Int32
    let config_get_cstring: (inout RimeConfig, UnsafePointer<CChar>) -> UnsafePointer<CChar>?
}

/// Parse the minimal YAML subset the store reads: `schema_list:` items, and flat
/// `section: / key: value` pairs (`schema/name`, `speller/alphabet`).
func _rbParseConfig(_ yaml: String) -> RimeConfigBox {
    let box = RimeConfigBox()
    var section: String? = nil
    var inSchemaList = false
    func clean(_ s: Substring) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\"'"))
    }
    for raw in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }
        if line.hasPrefix("- schema:") {
            if inSchemaList { box.list.append(clean(line.dropFirst("- schema:".count))) }
            continue
        }
        if line.hasPrefix("- ") { continue }
        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard let head = parts.first else { continue }
        let key = clean(head)
        let value = parts.count > 1 ? clean(parts[1]) : ""
        if value.isEmpty {
            section = key
            inSchemaList = (key == "schema_list")
            continue
        }
        inSchemaList = false
        if let section { box.values["\(section)/\(key)"] = value }
        box.values[key] = value
    }
    return box
}

private let _rbRimeApi: UnsafeMutablePointer<RimeApi> = {
    let pointer = UnsafeMutablePointer<RimeApi>.allocate(capacity: 1)
    pointer.initialize(
        to: RimeApi(
            config_close: { config in
                config.box = nil
                return true
            },
            config_load_string: { config, cString in
                config.box = _rbParseConfig(String(cString: cString))
                return 1
            },
            config_list_size: { config, key in
                guard let box = config.box else { return 0 }
                let name = String(cString: key)
                if name == "schema_list" { return Int32(box.list.count) }
                return Int32(box.values[name] == nil ? 0 : 1)
            },
            config_get_cstring: { config, key in
                guard let box = config.box else { return nil }
                let name = String(cString: key)
                if name.hasPrefix("schema_list/@"), name.hasSuffix("/schema") {
                    let index = Int(name.dropFirst("schema_list/@".count).dropLast("/schema".count)) ?? -1
                    guard box.list.indices.contains(index) else { return nil }
                    return UnsafePointer(strdup(box.list[index]))
                }
                guard let value = box.values[name] else { return nil }
                return UnsafePointer(strdup(value))
            }))
    return pointer
}()

func rime_get_api() -> UnsafeMutablePointer<RimeApi>? { _rbRimeApi }

// Only the `RimePaths` member the store's runtime helpers reference.
enum RimePaths {
    static func recipeUserDirectory(
        kind: KeyboardRecipeStore.ResourceKind,
        packageID: String? = nil
    ) -> URL? {
        guard kind == .userScheme, let packageID, !packageID.isEmpty else {
            return URL(fileURLWithPath: "/tmp/rime-user")
        }
        return URL(fileURLWithPath: "/tmp/rime-user/" + packageID)
    }
}
