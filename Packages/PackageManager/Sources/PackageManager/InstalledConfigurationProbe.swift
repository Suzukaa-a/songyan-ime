import Foundation

/// Launch-time probe of installed configuration (strict, read-only, no network).
///
/// Decides whether a genuinely valid install exists on disk, to skip first-run setup.
/// Only strictly decodable receipts with a valid generation count; empty directories,
/// leftover staging/logs and malformed JSON all mean "not installed".
public enum InstalledConfigurationProbe: Sendable {

    /// Single-source store (`active.json` directly under the root): true only if it decodes
    /// strictly and its generation is valid.
    public static func hasActiveInstallation(inStoreRoot root: URL) async -> Bool {
        let manager = RecipePackageManager(rootURL: root)
        do { return try await manager.activeInstallation() != nil } catch { return false }
    }

    /// Directory-style store (one subdirectory per source): true if any subdirectory holds a
    /// strictly valid install receipt. Does not read source contents recursively or modify disk.
    public static func hasAnyActiveInstallation(inPackageStoreRoot root: URL) async -> Bool {
        let fm = FileManager.default
        guard
            let entries = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
        else { return false }
        for entry in entries {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDirectory == true else { continue }
            if await hasActiveInstallation(inStoreRoot: entry) { return true }
        }
        return false
    }
}
