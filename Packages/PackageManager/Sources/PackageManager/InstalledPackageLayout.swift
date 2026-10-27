import Foundation

/// File and directory names inside an install slot (`SchemePackages/<id>`), shared by the code
/// that writes them and the code that re-reads them.
public enum InstalledPackageLayout {
    /// The live-generation marker at the slot root.
    public static let activeMarker = "active.json"
    public static let versionsDirectory = "versions"
    public static let resourcesDirectory = "resources"
    public static let userDirectory = "user"
    public static let buildDirectory = "build"
    /// Resources-level lists: enabled input methods, and source methods present but not enabled.
    public static let keyboardSchemas = "keyboard-schemas.json"
    public static let keyboardSourceSchemas = "keyboard-source-schemas.json"
    public static let schemaFileSuffix = ".schema.yaml"
    /// Optional author declaration of keyboards inside a source package.
    public static let keyboardPackageFile = "keyboard-package.json"
    /// Source identity file at the slot root.
    public static let sourceFile = "source.json"

    /// `<id>.schema.yaml`.
    public static func schemaFile(_ id: String) -> String { id + schemaFileSuffix }

    /// Compiled `build/<id>.schema.yaml`.
    public static func compiledSchemaURL(build: URL, id: String) -> URL {
        build.appendingPathComponent(schemaFile(id))
    }

    /// Whether `path` is a schema file at the top level of a file map.
    public static func isTopLevelSchemaFile(_ path: String) -> Bool {
        path.hasSuffix(schemaFileSuffix) && !path.contains("/")
    }

    /// Top-level `*.schema.yaml` keys of a file map (unsorted).
    public static func topLevelSchemaFiles<Keys: Sequence<String>>(in keys: Keys) -> [String] {
        keys.filter(isTopLevelSchemaFile)
    }
}
