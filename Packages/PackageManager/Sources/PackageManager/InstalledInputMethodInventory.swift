import Foundation
import KeyboardCore

/// The input methods that installs on disk still declare, used to decide whether a stored page
/// pairing still has a provider.
///
/// Conservative by construction: every read that cannot be completed yields `nil` instead of a
/// smaller set, so a caller never concludes that a method has no provider from a partial read.
public enum InstalledInputMethodInventory {
    private static let declarationSizeLimit = 1_000_000

    /// Built-in schemes plus every install's own declarations. The authoritative lists win over
    /// filenames, because a damaged install can lose `X.schema.yaml` while still declaring X.
    ///
    /// nil = something declared exists but could not be read, so the inventory is incomplete.
    public static func declaredInputMethods(storeRoot: URL) -> Set<String>? {
        let fm = FileManager.default
        var providers = Set(BuiltinTemplateSchemas.sourceSchemaIDs)
        guard fm.fileExists(atPath: storeRoot.path) else { return providers }
        guard
            let slots = try? fm.contentsOfDirectory(
                at: storeRoot, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles])
        else { return nil }
        for slot in slots {
            guard PublishedKeyboardSourceKey.validPackageID(slot.lastPathComponent) else { continue }
            guard let values = try? slot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            else { return nil }
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            // A real install slot that cannot be listed may be hiding declarations.
            guard (try? fm.contentsOfDirectory(atPath: slot.path)) != nil else { return nil }
            guard let ids = inputMethodIDs(inSlot: slot) else { return nil }
            providers.formUnion(ids)
        }
        return providers
    }

    /// The fields of the active marker this inventory needs. Read as a narrow shape so it stays
    /// independent of the install record's full encoding.
    private struct ActiveMarker: Decodable {
        let generation: String
        let schemaID: String
    }

    /// Input methods one install slot declares. The active marker is the authority: it names
    /// the live generation and the default input method, so a lost resource directory still
    /// declares its method. nil = the slot exists but cannot be re-read completely.
    private static func inputMethodIDs(inSlot slot: URL) -> Set<String>? {
        let marker: ActiveMarker?
        do {
            marker = try readDeclaration(
                ActiveMarker.self, at: slot.appendingPathComponent(InstalledPackageLayout.activeMarker))
        } catch { return nil }
        let versions = slot.appendingPathComponent(InstalledPackageLayout.versionsDirectory, isDirectory: true)
        guard let generations = try? FileManager.default.contentsOfDirectory(atPath: versions.path) else {
            // No versions/ is a failed or staging install; an unlistable one is incomplete.
            if isDirectory(versions) { return nil }
            return marker == nil ? [] : nil
        }
        guard let marker else {
            // No active marker: every generation present still declares its own methods.
            var ids: Set<String> = []
            for name in generations {
                guard
                    let declared = inputMethodIDs(
                        inGeneration: versions.appendingPathComponent(name, isDirectory: true))
                else { return nil }
                ids.formUnion(declared)
            }
            return ids
        }
        // The marker's generation must be re-readable, or the install's methods are unknown.
        guard generations.contains(marker.generation) else { return nil }
        let generation = versions.appendingPathComponent(marker.generation, isDirectory: true)
        // The marker names only the default method, so without the generation's own resources
        // the rest of its declared set cannot be recovered. The inventory is then incomplete,
        // rather than suddenly declaring just the default and dropping the others' preferences.
        guard isDirectory(generation.appendingPathComponent(InstalledPackageLayout.resourcesDirectory))
        else { return nil }
        guard var ids = inputMethodIDs(inGeneration: generation) else { return nil }
        // A marked generation that declares nothing is damaged, not an install with no input
        // methods: the marker names only the default, so the set must not shrink to just it.
        guard !ids.isEmpty else { return nil }
        ids.insert(marker.schemaID)
        return ids
    }

    /// Input methods one generation declares. nil = a declaration in it is present but unreadable.
    private static func inputMethodIDs(inGeneration generation: URL) -> Set<String>? {
        let bases = [InstalledPackageLayout.resourcesDirectory, InstalledPackageLayout.userDirectory]
        var ids: Set<String> = []
        for base in bases {
            guard let names = schemaFileNames(in: generation.appendingPathComponent(base))
            else { return nil }
            ids.formUnion(names)
        }
        let resources = generation.appendingPathComponent(InstalledPackageLayout.resourcesDirectory)
        do {
            if let declared = try readDeclaration(
                [KeyboardSchemaDescriptor].self,
                at: resources.appendingPathComponent(InstalledPackageLayout.keyboardSchemas))
            {
                ids.formUnion(declared.map(\.id))
            }
            if let declared = try readDeclaration(
                [String].self,
                at: resources.appendingPathComponent(InstalledPackageLayout.keyboardSourceSchemas))
            {
                ids.formUnion(declared)
            }
        } catch { return nil }
        for base in bases {
            let build = generation.appendingPathComponent(base, isDirectory: true)
                .appendingPathComponent(InstalledPackageLayout.buildDirectory, isDirectory: true)
            guard let sources = adapterInputMethodIDs(in: build, known: ids) else { return nil }
            ids.formUnion(sources)
        }
        return ids
    }

    /// Input methods a build declares. Its adapter registry maps each generated companion back
    /// to the source it serves. Without a registry, a schema file that is not already a known
    /// input method cannot be attributed, so the inventory stays incomplete (an ordinary 26-key
    /// install writes no registry and its build files are all known source schemas).
    private static func adapterInputMethodIDs(in build: URL, known: Set<String>) -> Set<String>? {
        let registry = build.appendingPathComponent(KeyboardResourceSet.adapterRegistryFileName)
        if FileManager.default.fileExists(atPath: registry.path) {
            guard
                let adapters = try? readDeclaration([KeyboardResourceSet.EncodingAdapter].self, at: registry)
            else { return nil }
            return Set(adapters.map(\.sourceSchemaID))
        }
        guard let names = schemaFileNames(in: build) else { return nil }
        return names.allSatisfy { known.contains($0) } ? [] : nil
    }

    /// `*.schema.yaml` names in a directory; [] when it is absent, nil when it exists but cannot
    /// be listed (only the latter makes the inventory incomplete).
    private static func schemaFileNames(in directory: URL) -> Set<String>? {
        guard isDirectory(directory) else { return [] }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return nil }
        let suffix = InstalledPackageLayout.schemaFileSuffix
        return Set(names.filter { $0.hasSuffix(suffix) }.map { String($0.dropLast(suffix.count)) })
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// nil = the file is absent (an install that never wrote it).
    private static func readDeclaration<T: Decodable>(_ type: T.Type, at url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard data.count < declarationSizeLimit else { throw CocoaError(.fileReadTooLarge) }
        return try JSONDecoder().decode(type, from: data)
    }
}
