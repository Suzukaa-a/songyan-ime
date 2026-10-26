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
}
