import Darwin
import Foundation
import Yams

/// One manager per App Group store. Downloads and deployment belong in the host App.
/// Caller must stop/flush ALL engine writers before install/update until completion, including
/// the keyboard extension, because a consistent user dictionary snapshot requires quiescence.
public actor RecipePackageManager {
    public typealias FetchResource = @Sendable (URL) async throws -> Data
    public typealias Deploy = @Sendable (RecipeDeployment) async throws -> RecipeDeploymentReceipt

    /// Budget of the default recipe fetch (`fetchHTTP` and the injected default closure).
    public static let defaultFetchMaximumBytes = 64 * 1024 * 1024

    private let root: URL
    nonisolated let sharedOpenCCDirectory: URL?
    /// One ephemeral transport per manager, so a prefetch/install batch reuses one
    /// session. Never a global singleton and never invalidated while a caller may
    /// still be reading: ARC releases it with the manager.
    nonisolated let transport: HTTPSResourceTransport
    let fetch: FetchResource
    private let fm = FileManager.default
    private var installing = false

    /// `fetch` stays injectable for offline tests. When it is omitted, the default
    /// closure reads through this manager's own transport (batch reuse); an injected
    /// closure remains fully in control and is never bypassed.
    public init(rootURL: URL, sharedOpenCCDirectory: URL? = nil, fetch: FetchResource? = nil) {
        self.init(
            rootURL: rootURL, sharedOpenCCDirectory: sharedOpenCCDirectory, fetch: fetch, configuration: .ephemeral)
    }

    /// Designated initializer. Internal so offline tests can inject a `URLProtocol`
    /// fixture session; production always uses `.ephemeral`.
    init(
        rootURL: URL, sharedOpenCCDirectory: URL? = nil, fetch: FetchResource? = nil,
        configuration: URLSessionConfiguration
    ) {
        root = rootURL.standardizedFileURL
        self.sharedOpenCCDirectory = sharedOpenCCDirectory
        let transport = HTTPSResourceTransport(configuration: configuration)
        self.transport = transport
        self.fetch =
            fetch ?? { url in try await transport.read(url, maximumBytes: RecipePackageManager.defaultFetchMaximumBytes)
            }
    }

    public static func fetchHTTP(_ url: URL) async throws -> Data {
        try await HTTPSResourceReader.read(url, maximumBytes: defaultFetchMaximumBytes)
    }

    /// Batch-scoped bounded HTTPS read that shares this manager's transport, for
    /// callers that fetch many files outside the actor (source/dependency acquisition)
    /// instead of creating one ephemeral session per file. The cap is clamped to the
    /// ordinary single-file budget: model-size payloads use the disk-backed
    /// `RecipeFileResource.download` path, never this in-memory reader.
    nonisolated func readBatchResource(_ url: URL, maximumBytes: Int) async throws -> Data {
        try await transport.read(url, maximumBytes: min(max(maximumBytes, 0), RecipeResourceBudget.sourceFile))
    }

    /// Host helper for ordinary (non-model) declared downloads: HTTPS bytes with the
    /// caller's per-path budget instead of the fixed 64 MiB dictionary cap.
    public static func fetchHTTPBytes(_ url: URL, maximumBytes: Int) async throws -> Data {
        try await HTTPSResourceReader.read(
            url, maximumBytes: min(max(maximumBytes, 0), RecipeResourceBudget.sourceFile))
    }

    /// Fetch and freeze pinned bytes before acquiring the engine exclusive lease.
    /// No active generation or live user directory is read during this phase.
    public func prefetch(_ manifest: RecipeManifest) async throws -> PrefetchedRecipe {
        guard manifest.origin == nil else {
            throw RecipeInstallError.invalidManifest("Prepared imports already own their bytes")
        }
        try validate(manifest)
        var bytes: [String: Data] = [:]
        for file in manifest.files {
            try Task.checkCancellation()
            let url = URL(
                string: "https://raw.githubusercontent.com/\(manifest.repository)/\(manifest.revision)/\(file.path)")!
            let data = try await fetch(url)
            try Task.checkCancellation()
            guard data.count == file.size, sha256Hex(data) == file.sha256 else {
                throw RecipeInstallError.invalidResource(file.path)
            }
            bytes[file.path] = data
        }
        return PrefetchedRecipe(manifest: manifest, bytes: bytes)
    }

    /// Caller holds the engine lease from before this call through completion. Source selection,
    /// user snapshot, deployment and commit happen here; there is no network access.
    public func installPrefetched(
        _ prepared: PrefetchedRecipe, initialUserDataURL: URL? = nil,
        deploy: @escaping Deploy
    ) async throws -> InstalledRecipe {
        try Task.checkCancellation()
        return try await installResources(
            prepared.manifest, initialUserDataURL: initialUserDataURL,
            deploy: deploy
        ) { file in
            guard let bytes = prepared.bytes[file.path] else { throw RecipeInstallError.invalidResource(file.path) }
            return bytes
        }
    }

    /// Host UI dispatches the synchronous package readers off the main thread.
    /// These readers touch no actor state (staging lives in the system temp directory);
    /// `nonisolated` keeps the actor hop out of the heavy path.
    nonisolated public func prepareSync(_ urls: [URL]) throws -> PreparedSchemeImport {
        guard urls.count == 1, let url = urls.first else {
            return try prepareSchemeImport(
                files: urls.map { DictionaryImportFile(path: $0.lastPathComponent, location: $0) })
        }
        if url.pathExtension.lowercased() == "zip" {
            return try prepareSchemeArchive(url)
        }
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            return try prepareSchemeImport(directory: url)
        }
        return try prepareSchemeImport(files: [DictionaryImportFile(path: url.lastPathComponent, location: url)])
    }

    public func status() throws -> RecipeStatus {
        RecipeStatus(active: try load(InstalledPackageLayout.activeMarker))
    }

    public func activeUserDataURL() throws -> URL? {
        try activeDirectory()?.appendingPathComponent("user", isDirectory: true)
    }

    public func activeInstallation() throws -> ActiveRecipe? {
        guard let active: InstalledRecipe = try load(InstalledPackageLayout.activeMarker) else { return nil }
        guard safePath(active.generation), !active.generation.contains("/") else {
            throw RecipeInstallError.invalidResource("active generation")
        }
        let directory = generationDirectory(active.generation)
        return ActiveRecipe(
            installation: active, resourceURL: directory.appendingPathComponent("resources"),
            userDataURL: directory.appendingPathComponent("user"))
    }

    /// `initialUserDataURL` is used only on first install, and is never modified.
    /// Every successful install creates a fresh generation; errors retain the previous active.json.
    @discardableResult
    public func install(
        _ manifest: RecipeManifest, initialUserDataURL: URL? = nil,
        deploy: @escaping Deploy
    ) async throws -> InstalledRecipe {
        guard manifest.origin == nil else {
            throw RecipeInstallError.invalidManifest("User dictionary imports require prepared source bytes")
        }
        return try await installResources(
            manifest, initialUserDataURL: initialUserDataURL,
            deploy: deploy
        ) { file in
            let url = URL(
                string: "https://raw.githubusercontent.com/\(manifest.repository)/\(manifest.revision)/\(file.path)")!
            return try await self.fetch(url)
        }
    }

    /// Shares the pinned recipe transaction: staging, integrity checks, user snapshot and atomic commit.
    func installResources(
        _ manifest: RecipeManifest, initialUserDataURL: URL?, deploy: @escaping Deploy,
        fileResources: [String: RecipeFileResource] = [:],
        expectedActiveGeneration: String?? = nil,
        read: @escaping @Sendable (RecipeManifest.File) async throws -> Data
    ) async throws -> InstalledRecipe {
        guard !installing else { throw RecipeInstallError.busy }
        try validate(manifest)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let lock = try StoreLock(root.appendingPathComponent("install.lock"))
        installing = true
        defer {
            installing = false
            lock.unlock()
        }
        // Outer nil means an unchecked call; .some(nil) requires an empty store. This is the only
        // generation check: it runs under the lock, so nothing can commit between it and our commit.
        let active = try activeInstallation()?.installation.generation
        if let expected = expectedActiveGeneration {
            guard active == expected else { throw RecipeInstallError.invalidResource("安装期间配置状态已改变，请重试。") }
        }
        // Every engine is stopped while the lock is held, so anything but the active generation
        // (leftovers of failed or superseded installs) can go.
        removeGenerations(except: active)
        let generation = "\(manifest.id)-\(manifest.revision)-\(UUID().uuidString)"
        let directory = generationDirectory(generation)
        let resources = directory.appendingPathComponent("resources", isDirectory: true)
        let user = directory.appendingPathComponent("user", isDirectory: true)
        do {
            try fm.createDirectory(at: resources, withIntermediateDirectories: true)
            for file in manifest.files {
                try Task.checkCancellation()
                if let resource = fileResources[file.path] {
                    guard resource.sha256 == file.sha256, resource.size == file.size else {
                        throw RecipeInstallError.invalidResource(file.path)
                    }
                    try resource.copy(
                        to: resources.appendingPathComponent(file.path),
                        maximumBytes: RecipeResourceBudget.maximumFileBytes(file.path))
                    continue
                }
                let data = try await read(file)
                guard data.count == file.size, sha256Hex(data) == file.sha256 else {
                    throw RecipeInstallError.invalidResource(file.path)
                }
                let target = resources.appendingPathComponent(file.path)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target, options: .atomic)
            }
            // Imported Lua runs inside librime-lua with the full standard library. The
            // engine loads <shared>/rime.lua before any lua_* module, so every generation
            // carrying Lua gets the generated sandbox entry (prelude + package rime.lua).
            if LuaSandbox.requiresSandbox(paths: manifest.files.map(\.path)) {
                let entry = resources.appendingPathComponent(LuaSandbox.entryPath)
                let original = fm.fileExists(atPath: entry.path) ? try Data(contentsOf: entry) : nil
                try LuaSandbox.wrap(original).write(to: entry, options: .atomic)
            }
            // Snapshot AFTER networking to minimize the interval between copying and activation.
            let source = try activeUserDataURL() ?? initialUserDataURL
            try fm.createDirectory(at: user, withIntermediateDirectories: true)
            if let source {
                let sourcePath = source.resolvingSymlinksInPath().standardizedFileURL.path
                guard !directory.path.hasPrefix(sourcePath + "/") else {
                    throw RecipeInstallError.invalidResource("User snapshot source contains staging directory")
                }
                // Do not copy shadows of this generation's authoritative model resources.
                // Only the new snapshot changes; old generations and learning files stay intact.
                let models = Set(
                    manifest.files.filter { RecipeResourceBudget.isModel($0.path) }.map { $0.path.lowercased() })
                try copyUserDirectory(source, to: user, topLevel: true, excludedModels: models)
            }
            try JSONEncoder().encode(manifest).write(
                to: directory.appendingPathComponent(InstalledPackageLayout.sourceFile), options: .atomic)
            let receipt = try await deploy(
                RecipeDeployment(manifest: manifest, resourceURL: resources, userDataURL: user))
            let missing = Set(manifest.requiredComponents).subtracting(receipt.availableComponents).sorted()
            guard missing.isEmpty else { throw RecipeInstallError.missingComponents(missing) }
            let entry = receipt.validatedSchemaID
            if let validated = receipt.validatedEnabledSchemaIDs {
                let config = try String(contentsOf: user.appendingPathComponent("build/default.yaml"), encoding: .utf8)
                let yaml = try BoundedYAML.load(yaml: config) as? [String: Any]
                let rows = yaml?["schema_list"] as? [[String: Any]] ?? []
                let enabled = rows.compactMap { $0["schema"] as? String }
                guard !enabled.isEmpty, Set(enabled).count == enabled.count, Set(enabled) == Set(validated),
                    enabled.contains(entry),
                    entry == manifest.schemaID || manifest.origin == .userRecipe || manifest.origin == .userScheme
                else {
                    throw RecipeInstallError.deployment("Enabled schema receipt does not match deployed schema_list")
                }
            } else {
                guard entry == manifest.schemaID else { throw RecipeInstallError.deployment("Unexpected schema entry") }
            }
            guard safePath(entry), !entry.contains("/"),
                fm.fileExists(atPath: user.appendingPathComponent("build/\(entry).schema.yaml").path)
            else {
                throw RecipeInstallError.deployment("No validated compiled \(entry) schema")
            }
            try RecipeDeployment(manifest: manifest, resourceURL: resources, userDataURL: user)
                .validateResolvedModelIdentities(enabledSchemaIDs: receipt.validatedEnabledSchemaIDs ?? [entry])
            try Task.checkCancellation()
            let installed = InstalledRecipe(
                id: manifest.id, revision: manifest.revision, generation: generation,
                schemaID: entry, activatedAt: Date())
            // The commit point. Resources/user paths stay fixed, including Lua's lazily opened files.
            try save(installed, InstalledPackageLayout.activeMarker)
            return installed
        } catch {
            // The previous generation stays active; the half-written new one is discarded.
            try? fm.removeItem(at: directory)
            throw error
        }
    }

    private func generationDirectory(_ generation: String) -> URL {
        root.appendingPathComponent(InstalledPackageLayout.versionsDirectory, isDirectory: true)
            .appendingPathComponent(generation, isDirectory: true)
    }

    private func removeGenerations(except active: String?) {
        let versions = root.appendingPathComponent(InstalledPackageLayout.versionsDirectory, isDirectory: true)
        for directory in (try? fm.contentsOfDirectory(at: versions, includingPropertiesForKeys: nil)) ?? []
        where directory.lastPathComponent != active {
            try? fm.removeItem(at: directory)
        }
    }

    /// Updates always use an explicitly reviewed/pinned manifest, never an unpinned branch head.
    @discardableResult
    public func update(_ manifest: RecipeManifest, deploy: @escaping Deploy) async throws -> InstalledRecipe {
        try await install(manifest, deploy: deploy)
    }

    private func activeDirectory() throws -> URL? {
        guard let active: InstalledRecipe = try load(InstalledPackageLayout.activeMarker) else { return nil }
        guard safePath(active.generation), !active.generation.contains("/") else {
            throw RecipeInstallError.invalidResource("active generation")
        }
        return generationDirectory(active.generation)
    }

    private func load<T: Decodable>(_ name: String) throws -> T? {
        let url = root.appendingPathComponent(name)
        guard fm.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    private func save<T: Encodable>(_ value: T, _ name: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]  // canonical bytes for content-hash stamps
        try encoder.encode(value).write(to: root.appendingPathComponent(name), options: .atomic)
    }

    private func safePath(_ path: String) -> Bool {
        SchemeSourceCheck.safe(path)
    }

    private func validate(_ manifest: RecipeManifest) throws {
        guard safePath(manifest.id), !manifest.id.contains("/"),
            safePath(manifest.repository), manifest.repository.split(separator: "/").count == 2,
            manifest.revision.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil,
            safePath(manifest.schemaID), !manifest.schemaID.contains("/"),
            !manifest.files.isEmpty, manifest.files.count <= 2000
        else {
            throw RecipeInstallError.invalidManifest("identity/revision")
        }
        var paths = Set<String>()
        for file in manifest.files {
            guard safePath(file.path), paths.insert(file.path.lowercased()).inserted,
                file.size >= 0, file.size <= RecipeResourceBudget.maximumFileBytes(file.path),
                file.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                (manifest.origin == .userScheme || manifest.origin == .userRecipe
                    || !file.path.hasSuffix(".custom.yaml")), !file.path.contains(".userdb")
            else {
                throw RecipeInstallError.invalidManifest(file.path)
            }
        }
        try RecipeResourceBudget.validate(Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.path, $0.size) }))
        guard (manifest.origin == .userRecipe || paths.contains(manifest.recipePath.lowercased())),
            (manifest.origin == .userScheme || manifest.origin == .userRecipe || paths.contains("license")),
            paths.contains("\(manifest.schemaID).schema.yaml".lowercased())
        else {
            throw RecipeInstallError.invalidManifest("recipe/license/schema missing")
        }
    }

    private func copyUserDirectory(
        _ source: URL, to target: URL, topLevel: Bool,
        excludedModels: Set<String> = [], prefix: String = ""
    ) throws {
        let sourceInfo = try source.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard sourceInfo.isSymbolicLink != true, sourceInfo.isDirectory == true else {
            throw RecipeInstallError.invalidResource(source.path)
        }
        for child in try fm.contentsOfDirectory(
            at: source, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
        {
            try Task.checkCancellation()
            if topLevel && child.lastPathComponent == "build" { continue }
            let relativePath = prefix + child.lastPathComponent
            if excludedModels.contains(relativePath.lowercased()) { continue }
            let info = try child.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
            guard info.isSymbolicLink != true else { throw RecipeInstallError.invalidResource(child.path) }
            let destination = target.appendingPathComponent(child.lastPathComponent)
            if info.isDirectory == true {
                try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                try copyUserDirectory(
                    child, to: destination, topLevel: false, excludedModels: excludedModels, prefix: relativePath + "/")
            } else if info.isRegularFile == true {
                try fm.copyItem(at: child, to: destination)
            } else {
                throw RecipeInstallError.invalidResource(child.path)
            }
        }
    }
}

private final class StoreLock {
    private var fd: Int32
    init(_ url: URL) throws {
        fd = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            fd = -1
            throw RecipeInstallError.busy
        }
    }
    func unlock() {
        if fd >= 0 {
            flock(fd, LOCK_UN)
            close(fd)
            fd = -1
        }
    }
    deinit { unlock() }
}
