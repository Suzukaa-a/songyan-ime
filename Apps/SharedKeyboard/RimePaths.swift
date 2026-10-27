import AppearanceKit
import Foundation
import KeyboardCore
import OSLog
import os

/// Built-in package resources and the per-process writable user directory.
public enum RimePaths {
    /// Shared directory of the unified appearance project (Host writes, the extension only reads):
    /// skin and candidate area live in one snapshot, so one file read yields both parts of the same appearance identity.
    public static func sharedAppearanceDirectory() -> URL? {
        KeyboardRecipeStore.sharedContainerURL()?
            .appendingPathComponent("KeyboardAppearance", isDirectory: true)
    }
    /// Host-local appearance draft directory (drafts can still be saved when the shared container is not writable; the extension cannot read it).
    public static func localAppearanceDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KeyboardAppearanceDrafts", isDirectory: true)
    }
    /// Shared appearance store (the extension only reads; Host apply writes here).
    public static func sharedAppearanceStore() -> AppearanceStore? {
        guard let directory = sharedAppearanceDirectory() else { return nil }
        return AppearanceStore(directory: directory)
    }
    /// Local appearance draft store (used by Host editing/saving; still works when the shared container is unavailable).
    public static func localAppearanceStore() -> AppearanceStore {
        AppearanceStore(directory: localAppearanceDirectory())
    }
    public static func optionPreferencesDirectory() -> URL {
        let name = "KeyboardOptions"
        if let container = KeyboardRecipeStore.sharedContainerURL() {
            return container.appendingPathComponent(name, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name, isDirectory: true)
    }
    /// Built-in package scheme package (BuiltinPackages/Basic in Bundle.main).
    /// - Note: HostApp and KeyboardExtension each embed BuiltinPackages in their own bundle, so both
    ///   processes find the complete Rime shared data in a read-only bundle.
    public static func builtinPackage(in bundle: Bundle = .main) -> URL? {
        BuiltinResources.packageDirectory(in: bundle)
    }

    /// Base of the process-writable directory (a keyboard extension without full access can still write its own container).
    static func writableBase(subdir: String) -> URL? {
        let fm = FileManager.default
        let dirs = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let base = dirs.first ?? fm.urls(for: .documentDirectory, in: .userDomainMask).first
        guard let base else { return nil }
        return base.appendingPathComponent(subdir, isDirectory: true)
    }

    /// Private user directory used by the interactive engine (try-typing area / keyboard extension UI).
    public static func interactiveUserDirectory() -> URL? {
        writableBase(subdir: "RimeUser")
    }

    /// Stable, extension-private learning store. Never copied from the installer.
    public static func recipeUserDirectory(kind: KeyboardRecipeStore.ResourceKind, packageID: String? = nil) -> URL? {
        switch kind {
        case .userScheme:
            guard let id = packageID, PublishedKeyboardSourceKey.validPackageID(id) else { return nil }
            // The installed built-in scheme keeps learning in the same place as the bundled fallback
            // it replaces, so switching between them never loses what was learned.
            if id == ProductionInputAvailability.builtinPackageID { return interactiveUserDirectory() }
            return writableBase(subdir: "RimeSchemeUser/" + id)
        case .userDictionary:
            // Imported dictionaries share this process's existing built-in learning (songyan_shared),
            // never an active database copied from the host or App Group.
            return interactiveUserDirectory()
        }
    }

    /// Host fallback only: never attach a published revision to another installation's userdb.
    public static func publishedTrialUserDirectory(_ activation: KeyboardRecipeStore.Activation) -> URL? {
        guard let base = recipeUserDirectory(kind: activation.kind, packageID: activation.packageID),
            !activation.revision.isEmpty,
            activation.revision.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
        else { return nil }
        return base.appendingPathComponent("PublishedTrials/" + activation.revision)
    }

    /// Resolve Host learning against the publication, never the newest installation of another kind.
    public static func hostTrialUserDirectory(_ activation: KeyboardRecipeStore.Activation, applicationSupport: URL)
        throws -> URL
    {
        struct SourceIdentity: Decodable {
            let id: String
            let revision: String
            let schemaID: String
        }
        let root: URL
        switch activation.kind {
        case .userDictionary: root = applicationSupport.appendingPathComponent("DictionaryImportStore")
        case .userScheme:
            guard let id = activation.packageID, recipeUserDirectory(kind: .userScheme, packageID: id) != nil else {
                throw KeyboardRecipeStore.StoreError(message: "试打方案标识无效，请重新打开试打")
            }
            root = applicationSupport.appendingPathComponent("SchemePackages/" + id)
        }
        let versions = root.appendingPathComponent("versions")
        let candidates =
            (try? FileManager.default.contentsOfDirectory(at: versions, includingPropertiesForKeys: nil)) ?? []
        for directory in candidates.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if let generation = activation.hostInstallationGeneration, directory.lastPathComponent != generation {
                continue
            }
            guard let bytes = try? Data(contentsOf: directory.appendingPathComponent("source.json")),
                let manifest = try? JSONDecoder().decode(SourceIdentity.self, from: bytes),
                manifest.revision == activation.revision,
                activation.packageID == nil || manifest.id == activation.packageID,
                FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent(
                        "user/build/\(activation.selectedSchemaID ?? manifest.schemaID).schema.yaml"
                    ).path)
            else { continue }
            return directory.appendingPathComponent("user")
        }
        guard let fallback = publishedTrialUserDirectory(activation) else {
            throw KeyboardRecipeStore.StoreError(message: "找不到与当前版本对应的试打词库目录，请在「松烟」App 中重新试打")
        }
        return fallback
    }
}

// MARK: - App Group container

extension KeyboardRecipeStore {
    /// Default App Group; `Config/Identity.xcconfig` declares the same value.
    public static let defaultGroupID = "group.app.songyan.shared"

    /// Group identifier declared in this target's entitlements. Both Info.plists
    /// carry it as `SongyanAppGroup`, expanded from `SONGYAN_APP_GROUP`, so a
    /// fork that overrides the identity in `Config/Local.xcconfig` needs no code change.
    public static let declaredGroupID: String = {
        let declared = Bundle.main.object(forInfoDictionaryKey: "SongyanAppGroup") as? String
        guard let declared, !declared.isEmpty, !declared.hasPrefix("$(") else { return defaultGroupID }
        return declared
    }()

    /// App group used for every shared-container and shared-defaults lookup.
    public static var groupID: String { declaredGroupID }

    /// Every `containerURL(forSecurityApplicationGroupIdentifier:)` and
    /// `UserDefaults(suiteName:)` is an IPC to the container manager; device logs
    /// showed one on the keyboard's main thread every few keys. The container
    /// cannot move within a process, so a resolved URL is kept; nil is re-asked.
    private static let cachedContainer = OSAllocatedUnfairLock<URL?>(initialState: nil)
    // UserDefaults is documented thread-safe but explicitly not Sendable.
    private static let cachedDefaults = OSAllocatedUnfairLock<UserDefaults?>(uncheckedState: nil)

    public static func sharedContainerURL() -> URL? {
        cachedContainer.withLock { cached in
            if let cached { return cached }
            cached = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
            return cached
        }
    }

    /// The App Group preferences, created once (UserDefaults is thread-safe and
    /// still observes the other process's writes through cfprefsd).
    public static func sharedDefaults() -> UserDefaults? {
        cachedDefaults.withLockUnchecked { cached in
            if let cached { return cached }
            cached = UserDefaults(suiteName: groupID)
            return cached
        }
    }

    /// Whether this process may write the App Group. A keyboard without Full Access can
    /// read it but every write fails, so the extension declares this from `hasFullAccess`
    /// and keeps its changes in memory for the session; the host app always writes.
    public static var canWriteSharedContainer: Bool {
        get { sharedWritesAllowed.withLock { $0 } }
        set { sharedWritesAllowed.withLock { $0 = newValue } }
    }
    private static let sharedWritesAllowed = OSAllocatedUnfairLock(
        initialState: Bundle.main.bundleURL.pathExtension != "appex")
}

/// Preferences both the host app and the keyboard change. Without write access a change
/// stays in this process for the session instead of failing in cfprefsd.
public enum SharedPreferences {
    // Values are plist scalars (Bool, String, numbers), which are immutable.
    private static let session = OSAllocatedUnfairLock<[String: Any]>(uncheckedState: [:])

    public static func object(forKey key: String, in store: UserDefaults) -> Any? {
        session.withLockUnchecked { $0[key] } ?? store.object(forKey: key)
    }

    public static func set(_ value: Any, forKey key: String, in store: UserDefaults) {
        guard KeyboardRecipeStore.canWriteSharedContainer else {
            session.withLockUnchecked { $0[key] = value }
            return
        }
        session.withLockUnchecked { $0[key] = nil }
        store.set(value, forKey: key)
    }
}

// MARK: - DIY keyboard layout storage (LayoutKit)
//
// HostApp is the only writer; the keyboard extension reads the same directory. The App Group
// shared container is preferred (the extension needs full access to read DIY layouts); when the
// container is unavailable or not writable it falls back to the app-local directory, where the
// extension cannot read custom layouts (built-in layouts are unaffected, LayoutKit provides them as the fallback).

/// Describes the DIY layout directory location (shown explicitly to the user in the UI).
public enum LayoutStoreLocation: Equatable, Sendable {
    /// App Group shared container (KeyboardLayouts/), readable by the keyboard extension.
    case shared(URL)
    /// App-local directory (RimeLayouts/); the keyboard extension cannot read DIY layouts from it.
    case local(URL)

    public var url: URL {
        switch self {
        case .shared(let url), .local(let url): return url
        }
    }

    public var isShared: Bool {
        if case .shared = self { return true }
        return false
    }
}

extension RimePaths {
    /// Layout directory name (relative to the App Group container root or the app container).
    public static let layoutDirectoryName = "KeyboardLayouts"

    /// Resolves the DIY layout directory: prefers the App Group shared container (with a read/write probe), falling back to the app-local one on failure.
    /// Performs no writes outside the directory and does not touch existing recipe/dictionary paths.
    public static func layoutStoreDirectory() -> LayoutStoreLocation {
        let resolved = probedStoreDirectory(sharedName: layoutDirectoryName, localName: "RimeLayouts", label: "layout")
        return resolved.isShared ? .shared(resolved.url) : .local(resolved.url)
    }

    /// The shared container's `sharedName` directory once it passes a create/write/read/delete probe;
    /// otherwise the process-local `localName` directory under Application Support (or Documents).
    static func probedStoreDirectory(
        sharedName: String, localName: String, label: String
    ) -> (url: URL, isShared: Bool) {
        let fm = FileManager.default
        if let container = KeyboardRecipeStore.sharedContainerURL() {
            let url = container.appendingPathComponent(sharedName, isDirectory: true)
            do {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
                let probe = url.appendingPathComponent(".probe-\(UUID().uuidString)")
                try Data("ok".utf8).write(to: probe, options: .atomic)
                _ = try Data(contentsOf: probe)
                try fm.removeItem(at: probe)
                return (url, true)
            } catch {
                Logger.keyboardStorage.error(
                    "App Group \(label, privacy: .public) directory unavailable: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        let url = writableBase(subdir: localName)!
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return (url, false)
    }

    /// Layout directory for the keyboard read path: resolves the URL only, with no read/write probe.
    ///
    /// The probe in `layoutStoreDirectory()` creates/writes/reads back/deletes a file, which is main-thread
    /// I/O. It stays at `LayoutManager` initialization (single writer, Host side), but re-running it on
    /// every keyboard appearance is unnecessary. Readers only care whether the shared container exists:
    /// if available, return the shared directory (the same URL as the existing probe path), otherwise
    /// fall back to the local directory. When it is truly unreadable `LayoutStore.load()` reports the error; this function does not mask it.
    public static func layoutStoreReadLocation() -> LayoutStoreLocation {
        if let container = KeyboardRecipeStore.sharedContainerURL() {
            return .shared(container.appendingPathComponent(layoutDirectoryName, isDirectory: true))
        }
        return .local(writableBase(subdir: "RimeLayouts")!)
    }

    /// A read-only instance of the shared appearance store (creates no directory, writes no probe).
    ///
    /// The read path only needs the shared container URL; `AppearanceStore.read()` itself never throws
    /// and never writes to disk. Returns nil when the container is unavailable (no full access).
    public static func sharedAppearanceReadStore() -> AppearanceStore? {
        guard let directory = sharedAppearanceDirectory() else { return nil }
        return AppearanceStore(directory: directory)
    }
}
