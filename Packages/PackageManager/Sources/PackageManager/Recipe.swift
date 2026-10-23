import Foundation

/// Immutable file list for a reviewed upstream recipe or a checked user dictionary import.
public struct RecipeManifest: Codable, Sendable {
    public enum Origin: String, Codable, Sendable { case userDictionary, userScheme, userRecipe }
    public struct File: Codable, Sendable {
        public let path: String
        public let sha256: String
        public let size: Int
    }
    public let id: String
    public let repository: String
    public let revision: String
    public let recipePath: String
    public let license: String
    public let schemaID: String
    public let requiredComponents: [String]
    public let files: [File]
    /// Absent for legacy reviewed GitHub manifests. User imports record actual URLs in import.json.
    public let origin: Origin?

    public init(
        id: String, repository: String, revision: String, recipePath: String,
        license: String, schemaID: String, requiredComponents: [String], files: [File],
        origin: Origin? = nil
    ) {
        self.id = id
        self.repository = repository
        self.revision = revision
        self.recipePath = recipePath
        self.license = license
        self.schemaID = schemaID
        self.requiredComponents = requiredComponents
        self.files = files
        self.origin = origin
    }
}

public enum RecipeInstallError: Error, LocalizedError {
    case invalidManifest(String)
    case invalidResource(String)
    case missingSchemaFiles([String])
    case http(Int)
    case busy
    case missingComponents([String])
    /// The scheme needs grammar models that were not supplied with it; the paths are the files to add.
    case missingGrammarModels([String])
    case deployment(String)

    public var errorDescription: String? {
        switch self {
        case .invalidManifest(let value): return "安装信息无效：\(value)"
        case .invalidResource(let value): return "方案文件检查失败：\(value)"
        case .missingSchemaFiles(let values): return "缺少启用或依赖的输入方案文件：\(values.joined(separator: "、"))"
        case .http(let code): return "下载失败（HTTP \(code)）"
        case .busy: return "正在安装，请稍后再试。"
        case .missingComponents(let values): return "缺少所需功能组件：\(values.joined(separator: "、"))"
        case .missingGrammarModels(let values): return "缺少语法模型：\(values.joined(separator: "、"))"
        case .deployment(let value): return "安装配置失败：\(value)"
        }
    }

    /// Short description for ordinary UI (no paths, IDs or engine details); technical detail
    /// lives in `errorDescription`, for diagnostic logs or developer options only.
    public var userFacingDescription: String {
        switch self {
        case .invalidManifest, .invalidResource, .missingSchemaFiles: return "文件不完整或格式不正确。"
        case .http: return "下载失败，请检查网络后重试。"
        case .busy: return "正在安装，请稍后再试。"
        case .missingComponents: return "此输入方案需要「松烟」暂不支持的功能。"
        case .missingGrammarModels: return "这个方案还需要语法模型文件。请在「语法模型」里添加后重试。"
        case .deployment: return "无法完成安装，请重试。"
        }
    }
}

public struct InstalledRecipe: Codable, Sendable {
    public let id: String
    public let revision: String
    public let generation: String
    public let schemaID: String
    public let activatedAt: Date
}

public struct RecipeStatus: Sendable {
    public let active: InstalledRecipe?
}

/// Both paths from one atomic marker read, so readers never mix generations during an update.
public struct ActiveRecipe: Sendable {
    public let installation: InstalledRecipe
    public let resourceURL: URL
    public let userDataURL: URL
}

public struct RecipeDeployment: Sendable {
    public let manifest: RecipeManifest
    public let resourceURL: URL
    /// Private snapshot, including user dictionaries/customizations, excluding stale build output.
    /// This becomes the live user directory after activation. Do not keep using the old directory.
    public let userDataURL: URL

    public func declaredEntry(in enabledSchemaIDs: [String]) throws -> String {
        if enabledSchemaIDs.contains(manifest.schemaID) { return manifest.schemaID }
        if (manifest.origin == .userRecipe || manifest.origin == .userScheme),
            let surviving = enabledSchemaIDs.first
        {
            return surviving
        }
        throw RecipeInstallError.deployment("所声明的输入方式未实际启用：\(manifest.schemaID)")
    }
}

/// The bridge must report registered components and perform real deploy + schema/input validation.
public struct RecipeDeploymentReceipt: Sendable {
    public let availableComponents: Set<String>
    public let validatedSchemaID: String
    /// Every enabled schema, after dependency/component/select/grammar validation.
    /// Core checks this set against the deployed build/default.yaml before committing.
    public let validatedEnabledSchemaIDs: [String]?
    public init(availableComponents: Set<String>, validatedSchemaID: String, validatedEnabledSchemaIDs: [String]? = nil)
    {
        self.availableComponents = availableComponents
        self.validatedSchemaID = validatedSchemaID
        self.validatedEnabledSchemaIDs = validatedEnabledSchemaIDs
    }
}
