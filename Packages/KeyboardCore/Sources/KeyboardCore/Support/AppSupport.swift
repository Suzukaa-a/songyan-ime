import Foundation

// MARK: - Engine integration status and built-in resource lookup (constants shared by UI/docs)

public enum EngineIntegration {
    /// Whether the real RimeBridge is linked. The RimeBridge Swift package is linked by the app
    /// and extension (production engine path = RimeBackend in Apps/SharedKeyboard). KeyboardCore
    /// itself does not depend on the bridge module; this flag only drives UI text and status.
    public static let isRimeBridgeAvailable = true

    /// One-line description of the current engine source for the UI.
    public static var currentEngineDescription: String {
        isRimeBridgeAvailable
            ? "引擎：RimeBridge（真实 librime 1.17.0）"
            : "引擎：本地演示（未接入 RimeBridge；候选为演示数据）"
    }
}

public enum BuiltinResources {
    /// The built-in package directory. The project embeds Resources/BuiltinPackages as a folder
    /// reference, so the package is <bundle>/BuiltinPackages/Basic.
    /// Returns nil when not found (e.g. unit tests running the package directly).
    public static func packageDirectory(in bundle: Bundle = .main) -> URL? {
        guard
            let url = bundle.url(
                forResource: "Basic", withExtension: nil,
                subdirectory: "BuiltinPackages")
        else {
            return nil
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
            isDir.boolValue
        else { return nil }
        return url
    }

    /// Files the built-in package must carry (for the "built-in resource check" page).
    public static var requiredFiles: [String] {
        ["manifest.yaml", "default.yaml", "songyan_basic.dict.yaml"]
            + (BuiltinTemplateSchemas.sourceSchemaIDs + BuiltinTemplateSchemas.adapters.map(\.schemaID))
            .map { $0 + ".schema.yaml" }
    }
}

public enum AppSettings {
    public static let selectedLayoutKey = "app.songyan.settings.selectedLayout"
    public static let onboardingCompletedKey = "app.songyan.settings.onboardingCompleted"
}
