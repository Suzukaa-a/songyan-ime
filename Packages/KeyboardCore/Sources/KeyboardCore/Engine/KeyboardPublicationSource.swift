import Foundation

// MARK: - Publication source identity (structured provenance)
//
// When an installed source is deleted, whether an added keyboard belongs to it is
// decided by structured source identity, never by schema string: the same schema ID may
// come from another source (e.g. two sources both shipping a same-named shuangpin). So a
// source is `kind + packageID`, not a schema name.
//
// Lives alongside `PublishedKeyboard.swift` (publication unit + human-facing projection)
// as the single canonical definition; don't duplicate it elsewhere.

/// Source identity of a publication record.
public enum KeyboardPublicationSource: Equatable, Hashable, Sendable {
    /// Custom pinyin generated from a user dictionary.
    case userDictionary
    /// Generic imported source; `packageID` is the install slot identity.
    case userScheme(packageID: String)

    /// Builds from a `KeyboardRecipeStore.ResourceKind` raw value and package id (keeps
    /// KeyboardCore independent of app-layer types).
    public init?(resourceKind: String, packageID: String?) {
        switch resourceKind {
        case "userDictionary": self = .userDictionary
        case "userScheme":
            guard let packageID, !packageID.isEmpty else { return nil }
            self = .userScheme(packageID: packageID)
        default: return nil
        }
    }

    /// Package id of the source (generic imported sources only).
    public var packageID: String? {
        if case .userScheme(let id) = self { return id }
        return nil
    }

    public var isUserScheme: Bool { packageID != nil }
}

// MARK: - Publication list prune on delete (pure value, unit-testable)

public enum PublishedKeyboardPrune {
    public struct Result: Equatable, Sendable {
        /// Combinations kept after deletion (original order).
        public let retained: [PublishedKeyboard]
        /// Combinations removed by this deletion.
        public let removed: [PublishedKeyboard]

        public var didChange: Bool { !removed.isEmpty }

        public init(retained: [PublishedKeyboard], removed: [PublishedKeyboard]) {
            self.retained = retained
            self.removed = removed
        }
    }

    /// Combinations the publication record keeps when an installed source is deleted.
    ///
    /// Provenance rule (avoids deleting another source's same-named schema):
    ///  * only when the record's source is the deleted source are combinations removed
    ///    by the deleted source's structured schema list;
    ///  * a different source (even one shipping a same-named schema) is kept untouched.
    ///
    /// `deletedSchemaIDs` comes from the deleted install's own enabled list, not inferred
    /// from the publication list.
    public static func retained(
        published: [PublishedKeyboard],
        publicationSource: KeyboardPublicationSource,
        deletingSource: KeyboardPublicationSource,
        deletedSchemaIDs: Set<String>
    ) -> Result {
        guard publicationSource == deletingSource else {
            return Result(retained: published, removed: [])
        }
        var retained: [PublishedKeyboard] = []
        var removed: [PublishedKeyboard] = []
        for keyboard in published {
            if deletedSchemaIDs.contains(keyboard.schemaID) {
                removed.append(keyboard)
            } else {
                retained.append(keyboard)
            }
        }
        return Result(retained: retained, removed: removed)
    }
}

// MARK: - "In use" criterion (shared by the delete action and the UI)

/// Admission rule for deleting a user-installed source.
///
/// Matches the scheme detail UI's "in use" check: deletion is refused only when the
/// record is enabled (`recipeEnabled`) and both source kind and package id match. After
/// disabling (switching to built-in) `recipeEnabled == false`, so the source can be
/// deleted even if the record still points at it; the list is then pruned by provenance.
public enum InstalledSourceDeletionPolicy {
    public enum Decision: Equatable, Sendable {
        case allowed
        case refusedInUse
    }

    public static func decision(
        recipeEnabled: Bool,
        publicationSource: KeyboardPublicationSource?,
        deletingPackageID: String
    ) -> Decision {
        guard recipeEnabled, publicationSource == .userScheme(packageID: deletingPackageID) else {
            return .allowed
        }
        return .refusedInUse
    }

    /// User-facing refusal text (no raw error; raw errors only appear in developer options).
    public static let refusedMessage = "这个输入方案正在使用。请先切换到其他输入方案，再删除。"
}

// MARK: - Structured source key (dictionary key of the cross-source keyboard cache)
//
// The cross-source cache (`Activation.keyboardsBySource`) stores each source's last
// successfully published keyboard list by source key, as the authoritative baseline when
// switching back. The key is built only from structured source identity, never schema
// names, branding, recipe, paths or hashes.
//
// It is a dictionary key, not a disk path, so no ASCII whitelist: non-ASCII/Chinese
// package ids accepted by the install manifest must work too. Safety comes from
// rejecting empty, `.`, `..`, path separators, colons, `..` substrings and control
// characters, so it cannot be used for path escape.
public enum PublishedKeyboardSourceKey {
    /// Valid package id: non-empty, not `.`/`..`, no `/`, `\`, `:`, `..` substring or
    /// control characters. Unicode/Chinese is allowed (same as the install manifest rules).
    public static func validPackageID(_ packageID: String) -> Bool {
        guard !packageID.isEmpty, packageID != ".", packageID != "..",
            !packageID.contains("/"), !packageID.contains("\\"),
            !packageID.contains(":"), !packageID.contains("..")
        else { return false }
        return packageID.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    /// Valid key: `userDictionary`, or `userScheme:` + a valid package id. Fails closed on write/read.
    public static func isValid(_ key: String) -> Bool {
        if key == "userDictionary" { return true }
        guard key.hasPrefix(userSchemePrefix) else { return false }
        return validPackageID(String(key.dropFirst(userSchemePrefix.count)))
    }

    static let userSchemePrefix = "userScheme:"
}

public extension KeyboardPublicationSource {
    /// Structured cache key (`kind` + optional `packageID`). nil for an invalid identity;
    /// callers then skip recording rather than guess a key.
    var cacheKey: String? {
        switch self {
        case .userDictionary: return "userDictionary"
        case .userScheme(let packageID):
            return PublishedKeyboardSourceKey.validPackageID(packageID)
                ? PublishedKeyboardSourceKey.userSchemePrefix + packageID : nil
        }
    }
}
