import Foundation

/// One installed scheme's identity as it matters for a repeated import.
public struct InstalledSchemeIdentity: Equatable, Sendable {
    public let id: String
    public let name: String
    /// The input method the source enables by default; it names the scheme inside a source.
    public let entrySchemaID: String

    public init(id: String, name: String, entrySchemaID: String) {
        self.id = id
        self.name = name
        self.entrySchemaID = entrySchemaID
    }
}

/// Importing a scheme that is already installed replaces it instead of adding a second copy.
///
/// A package ID is derived from the imported bytes, so newer files of the same scheme would
/// otherwise get a new ID and leave the old install behind. The entry input method is the
/// scheme's identity: it does not change between versions of the same source, and two different
/// schemes do not share it. Matching is deliberately exact — an import that cannot prove it is the
/// same scheme installs as a separate package.
public enum SchemeReimport {
    /// The installed package the recognized import replaces, or nil for a new scheme.
    /// `importedID` is the ID the imported bytes produced; the same one is never a replacement.
    public static func replacing(
        entrySchemaID: String, importedID: String,
        installed: [InstalledSchemeIdentity]
    ) -> InstalledSchemeIdentity? {
        guard !entrySchemaID.isEmpty else { return nil }
        return installed.first { $0.entrySchemaID == entrySchemaID && $0.id != importedID }
    }
}
