import Foundation

/// An ordinary (non-model) declared resource provided by the user (local pick or HTTPS download).
/// The SHA-256 is taken once from the exact bytes at acquisition, off the main actor, and only
/// this small identity is compared afterwards: different bytes mean a different identity, so a
/// plan made against older bytes no longer matches.
public struct ProvidedOrdinaryResource: Sendable, Equatable {
    public let data: Data
    public let sha256: String
    public var size: Int { data.count }

    init(data: Data, sha256: String) {
        self.data = data
        self.sha256 = sha256
    }

    public static func capturing(_ data: Data) -> ProvidedOrdinaryResource {
        ProvidedOrdinaryResource(data: data, sha256: sha256Hex(data))
    }
}

public extension RecipePackageManager {
    /// Bounded local read plus identity. Synchronous: call from a background task inside the
    /// caller's security-scope lease.
    nonisolated static func readLocalOrdinaryResource(_ url: URL, maximumBytes: Int) throws -> ProvidedOrdinaryResource
    {
        .capturing(try BoundedLocalFile.read(url, maximumBytes: min(maximumBytes, RecipeResourceBudget.sourceFile)))
    }

    /// Bounded HTTPS download plus identity.
    nonisolated static func fetchOrdinaryResource(_ url: URL, maximumBytes: Int) async throws
        -> ProvidedOrdinaryResource
    {
        let data = try await fetchHTTPBytes(url, maximumBytes: maximumBytes)
        try Task.checkCancellation()
        return .capturing(data)
    }
}

extension RecipePackageManager {
    /// Same, through the manager's shared transport so one plan's downloads reuse a session.
    nonisolated static func fetchOrdinaryResource(
        _ url: URL, maximumBytes: Int,
        from manager: RecipePackageManager
    ) async throws -> ProvidedOrdinaryResource {
        let data = try await manager.readBatchResource(url, maximumBytes: maximumBytes)
        try Task.checkCancellation()
        return .capturing(data)
    }
}
