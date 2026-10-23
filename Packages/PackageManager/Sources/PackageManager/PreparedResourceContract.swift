import Foundation

/// Immutable value returned only after all pinned bytes passed size/SHA validation.
public struct PrefetchedRecipe: Sendable {
    public let manifest: RecipeManifest
    let bytes: [String: Data]
    init(manifest: RecipeManifest, bytes: [String: Data]) {
        self.manifest = manifest
        self.bytes = bytes
    }
}

public extension RecipeDeployment {
    /// Checks that every planned model the enabled schemas resolve to is present with the planned size.
    /// Hashing is done once, at capture.
    func validateResolvedModelIdentities(enabledSchemaIDs: [String]) throws {
        let planned = Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.path.lowercased(), $0) })
        for id in enabledSchemaIDs {
            guard !id.isEmpty, !id.contains("/"), id != ".", id != ".." else {
                throw RecipeInstallError.deployment("Invalid schema ID")
            }
            let config = try String(
                contentsOf: userDataURL.appendingPathComponent("build/\(id).schema.yaml"), encoding: .utf8)
            let yaml = try BoundedYAML.load(yaml: config) as? [String: Any]
            guard let grammar = yaml?["grammar"] as? [String: Any], let language = grammar["language"] as? String,
                !language.isEmpty
            else { continue }
            let path = language + ".gram"
            guard !path.hasPrefix("/"),
                path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
                    !$0.isEmpty && $0 != "." && $0 != ".."
                })
            else {
                throw RecipeInstallError.deployment("Invalid model language path")
            }
            // User-only models outside this plan remain owned by the user and are validated live.
            guard let expected = planned[path.lowercased()] else { continue }
            let candidates = [userDataURL, resourceURL].map { $0.appendingPathComponent(path) }
            guard let resolved = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
                throw RecipeInstallError.deployment("Planned model is missing: \(path)")
            }
            let actual = try resolved.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard actual == expected.size else {
                throw RecipeInstallError.deployment("Resolved model identity differs from plan: \(path)")
            }
        }
    }
}
