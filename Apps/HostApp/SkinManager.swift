import AppearanceKit
import Foundation

/// Appearance import parsing (deterministic, single entry point).
///
/// All three inputs resolve to the same "appearance project", so import is atomic: one import yields one identity
/// carrying both skin and candidate-bar layout, never "only the skin imported, candidate bar still old".
///   - appearance project file (`*.songyanappearance.json`);
///   - standalone skin file (`*.songyanskin.json`) -> wrapped with the current built-in candidate-bar layout;
///   - standalone candidate-bar file (`*.songyancand.json`) -> wrapped with the built-in system default skin;
///   - a `system-default` inside is copied to a new identity so it does not collide with the read-only built-in default.
///
/// Fully strict decoding: unknown fields, wrong versions, invalid values, and oversize inputs are all rejected with a
/// clear "path: description" error; a half configuration is never silently accepted.
enum AppearanceImportSupport {
    static let maximumBytes = 256 * 1024

    static func decode(documentAt url: URL) throws -> AppearanceDocument {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try AppearanceDocument.decodeImported(contentsOf: url)
    }
}
