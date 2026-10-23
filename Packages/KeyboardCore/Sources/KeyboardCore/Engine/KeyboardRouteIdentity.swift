import Foundation

/// Publication-level identity of an engine route.
///
/// Equal ⇔ the running engine can keep serving the same request without any
/// teardown/boot. It therefore excludes appearance, candidate bar, host traits, input
/// mode and host document identity: those never justify a restart.
public struct KeyboardRouteKey: Equatable, Sendable {
    /// Stable resource-set id (`KeyboardResourceSet.id`). nil = no explicit resource set
    /// (Release unconfigured state; default route outside the Debug built-in package).
    public let resourceID: String?
    /// App Group publication generation (`KeyboardResourceSet.publicationGeneration`).
    /// Carried only by the publication record; never inferred from paths.
    public let publicationGeneration: String?
    /// Engine read-only shared directory.
    public let sharedDirectory: URL?
    /// Engine writable user directory (holds learning data; different directory =
    /// different learning identity).
    public let userDirectory: URL?
    /// Read-only prebuilt resource directory (nil = regular deployment route).
    public let prebuiltDirectory: URL?
    /// Source schema (user-visible scheme id) actually enabled.
    public let sourceSchemaID: String?
    /// Physical layout. Paired with the source schema; both are required.
    public let layout: KeyboardLayoutKind

    public init(
        resourceID: String?, publicationGeneration: String?, sharedDirectory: URL?,
        userDirectory: URL?, prebuiltDirectory: URL?, sourceSchemaID: String?,
        layout: KeyboardLayoutKind
    ) {
        self.resourceID = resourceID
        self.publicationGeneration = publicationGeneration
        self.sharedDirectory = sharedDirectory
        self.userDirectory = userDirectory
        self.prebuiltDirectory = prebuiltDirectory
        self.sourceSchemaID = sourceSchemaID
        self.layout = layout
    }

    /// Builds from a resource set and the (source schema, layout) actually enabled.
    ///
    /// `sourceSchemaID` must come from the same boot combination: when booting via
    /// `KeyboardResourceSet.bootSelection`, pass the source schema it resolved, not the
    /// resource set's possibly nil/stale published selection, or one running engine
    /// would map to two keys and restart repeatedly.
    public init(resource: KeyboardResourceSet, sourceSchemaID: String, layout: KeyboardLayoutKind) {
        self.init(
            resourceID: resource.id,
            publicationGeneration: resource.publicationGeneration,
            sharedDirectory: resource.sharedDirectory.standardizedFileURL,
            userDirectory: resource.userDirectory.standardizedFileURL,
            prebuiltDirectory: resource.prebuiltDirectory?.standardizedFileURL,
            sourceSchemaID: sourceSchemaID,
            layout: layout)
    }

    /// Privacy-safe diagnostic: publication identity and layout only, never
    /// input/candidate/schema content.
    public var diagnosticDescription: String {
        let generation = publicationGeneration.map { String($0.prefix(8)) } ?? "-"
        return "resource=\(resourceID ?? "-") gen=\(generation) layout=\(layout.rawValue)"
    }
}

/// Route ledger of one session: the ready route, the route being booted, and the boot
/// generation that rejects stale boot results.
public struct KeyboardRouteState: Equatable, Sendable {
    /// Ready route currently serving requests. nil = no reusable ready route.
    public private(set) var running: KeyboardRouteKey?
    /// Route being booted (not ready yet); deduplicates repeated requests for the same target.
    public private(set) var pending: KeyboardRouteKey?
    /// Boot generation; an in-flight boot captures it and checks `isCurrent` before finishing.
    public private(set) var generation: UInt64 = 0

    public init() {}

    public func isCurrent(_ token: UInt64) -> Bool { token == generation }

    /// Whether `key` needs no restart: it is the ready route, or it is already booting.
    public func canReuse(_ key: KeyboardRouteKey, isReady: Bool) -> Bool {
        (isReady && running == key) || pending == key
    }

    /// Starts a new generation (first boot, switch, retry), dropping `running`/`pending`.
    @discardableResult
    public mutating func beginBoot() -> UInt64 {
        running = nil
        pending = nil
        generation &+= 1
        return generation
    }

    public mutating func notePending(_ key: KeyboardRouteKey) { pending = key }

    /// The ready engine switched source schema / layout within the same run, so the next
    /// appearance reuses it instead of restarting. No-op without a ready engine.
    public mutating func updateRunning(_ key: KeyboardRouteKey) {
        guard running != nil else { return }
        running = key
    }

    /// A boot finished without becoming ready: clears pending only if still current.
    public mutating func clearPending(token: UInt64) {
        guard isCurrent(token) else { return }
        pending = nil
    }

    /// Publishes ready. Returns false for a stale boot; the caller must shut down the
    /// engine it just started.
    @discardableResult
    public mutating func commitReady(_ key: KeyboardRouteKey, token: UInt64) -> Bool {
        guard isCurrent(token) else { return false }
        running = key
        pending = nil
        return true
    }

    /// `shutdown()`: invalidates every in-flight boot and drops any reusable route.
    public mutating func cancel() {
        running = nil
        pending = nil
        generation &+= 1
    }
}
