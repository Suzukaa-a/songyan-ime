import Foundation

// MARK: - Cross-source published keyboard cache
//
// The shared publication record has only one source in use at a time, but each source's
// last successfully published keyboard list is kept by source identity as the
// authoritative baseline when switching back; otherwise switching sources would
// collapse the old source's list.
//
// Boundaries:
//  * `Activation.publishedKeyboards` is always the current source's real snapshot; the
//    extension reads only that and never gets another source's keyboards;
//  * this cache (`Activation.keyboardsBySource`) is only for cross-source restore, keyed
//    by structured `PublishedKeyboardSourceKey` (kind + optional packageID), never by
//    schema name/branding/path: the same schema ID may belong to different packages;
//  * merge/read are pure logic; invalid keys fail closed (the caller refuses to save).
//
// Not persisted here and independent of app-layer types.

/// A source key plus the full keyboard list of that source. `key` must be a valid structured source key.
public struct PublishedKeyboardRoster: Equatable, Sendable {
    public let key: String
    public let keyboards: [PublishedKeyboard]

    public init(key: String, keyboards: [PublishedKeyboard]) {
        self.key = key
        self.keyboards = keyboards
    }

    /// Merge result: grouped by source key, ordered and deduplicated by identity within a group.
    public struct Merged: Equatable, Sendable {
        /// Source key → full list (order is publication order).
        public let rosters: [String: [PublishedKeyboard]]
        /// Whether every key is a valid structured source key. When false the caller must refuse to save.
        public let selfConsistent: Bool

        public init(rosters: [String: [PublishedKeyboard]], selfConsistent: Bool) {
            self.rosters = rosters
            self.selfConsistent = selfConsistent
        }

        /// Full list for a source key; empty if absent.
        public func keyboards(forKey key: String) -> [PublishedKeyboard] {
            rosters[key] ?? []
        }
    }

    /// Merges rosters into a per-source-key cache.
    ///
    /// Rules (pure, schema-agnostic):
    ///  * same key: keep insertion order, deduplicate by identity (schema + layout);
    ///  * different keys stay independent; entries never move across sources;
    ///  * any invalid key ⇒ `selfConsistent == false` (that roster is skipped) and the
    ///    caller refuses to save rather than guess the source.
    public static func merged(_ rosters: [PublishedKeyboardRoster]) -> Merged {
        var result: [String: [PublishedKeyboard]] = [:]
        var consistent = true
        for roster in rosters {
            guard PublishedKeyboardSourceKey.isValid(roster.key) else {
                consistent = false
                continue
            }
            var list = result[roster.key] ?? []
            for keyboard in roster.keyboards where !list.contains(keyboard) {
                list.append(keyboard)
            }
            result[roster.key] = list
        }
        return Merged(rosters: result, selfConsistent: consistent)
    }
}
