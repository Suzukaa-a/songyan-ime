import Foundation
import KeyboardCore

/// Sole adapter from the host app's "user keyboards" page to the canonical publication transaction.
///
/// Stores no roster, infers no capability, never writes `active.json` directly, and does not poll
/// UI busy/error fields. Each operation reads its source from the current publication record and awaits the real `async throws` transaction.
enum UserKeyboardSource: Sendable, Equatable {
    /// Home entry: manage the sources that are already published.
    case active
    /// Detail entry for a generic install source; the ID comes from the install record, never inferred from the scheme name.
    case package(String)
}

/// A page's single authoritative publication read. The full activation is the
/// CAS token; its roster and current-source flag come from that same read.
struct UserKeyboardPublicationView: Sendable {
    let keyboards: [UserKeyboard]
    let roster: [PublishedKeyboard]
    let activation: KeyboardRecipeStore.Activation?
    let sourceKey: String?
    let isCurrent: Bool
}

@MainActor
final class DictionaryImportCenterUserKeyboards: UserKeyboardManaging {
    static let shared = DictionaryImportCenterUserKeyboards(center: .shared, source: .active)

    private let center: SchemeImportCenter
    private let source: UserKeyboardSource

    init(center: SchemeImportCenter, source: UserKeyboardSource = .active) {
        self.center = center
        self.source = source
    }

    var supportsManagement: Bool { true }

    func addableKeyboards() async throws -> [UserKeyboardCandidate] {
        let context = try await currentContext()
        let keyboards = try await context.transaction.addableKeyboards()
        let preferred = keyboards.filter { $0.schemaID == context.preferredSchemaID }
        let remaining = keyboards.filter { $0.schemaID != context.preferredSchemaID }
        return PublishedKeyboard.displays(preferred + remaining, in: context.schemas).map {
            UserKeyboardCandidate(
                inputMethodID: $0.keyboard.schemaID,
                inputMethodName: $0.inputMethodName,
                layout: $0.keyboard.layout)
        }
    }

    func addKeyboard(_ candidate: UserKeyboardCandidate) async throws -> String {
        let context = try await currentContext()
        let keyboard = PublishedKeyboard(
            schemaID: candidate.inputMethodID,
            layout: candidate.layout)
        _ = try await context.transaction.addKeyboard(keyboard)
        return "已添加 \(candidate.keyboard().title)。"
    }

    func removeKeyboard(_ keyboard: UserKeyboard) async throws -> String {
        let context = try await currentContext()
        let published = PublishedKeyboard(
            schemaID: keyboard.inputMethodID,
            layout: keyboard.layout)
        _ = try await context.transaction.removeKeyboard(published)
        return "已移除 \(keyboard.title)。"
    }

    func replaceKeyboards(_ keyboards: [UserKeyboard]) async throws -> String {
        let context = try await currentContext()
        let requested = keyboards.map {
            PublishedKeyboard(schemaID: $0.inputMethodID, layout: $0.layout)
        }
        let published = try await context.transaction.replaceKeyboards(requested)
        return UserTerminology.userKeyboardSaved(count: published.count)
    }

    func replaceKeyboards(_ keyboards: [UserKeyboard], viewed: UserKeyboardPublicationView) async throws -> String {
        let context = try await currentContext()
        let requested = keyboards.map { PublishedKeyboard(schemaID: $0.inputMethodID, layout: $0.layout) }
        let published = try await center.performReplaceKeyboards(
            packageID: context.packageID, requested: requested,
            viewedActivation: viewed.activation, viewedRoster: viewed.roster,
            viewedSourceKey: viewed.sourceKey)
        return UserTerminology.userKeyboardSaved(count: published.count)
    }

    /// Compare the captured publication with the installed identity. Do not read a
    /// second publication: its roster and CAS token must remain the page's snapshot.
    func isCurrentInstallation(_ viewed: UserKeyboardPublicationView) async throws -> Bool {
        guard viewed.isCurrent, let activation = viewed.activation,
            let packageID = activation.packageID
        else { return false }
        let installed = try await center.installedKeyboardIdentity(packageID: packageID)
        return activation.revision == installed.revision
            && activation.hostInstallationGeneration == installed.generation
    }

    private func currentContext() async throws
        -> (
            schemas: [KeyboardSchemaDescriptor],
            transaction: any UserKeyboardPublicationTransaction, packageID: String, preferredSchemaID: String?
        )
    {
        switch source {
        case .active:
            guard let activation = try await AppliedSelectionLoader.loadActivation(),
                activation.recipeEnabled
            else {
                throw UserKeyboardPublicationError.sourceNotInstalled
            }
            // Custom pinyin has no per-source user-keyboard transaction; saving through another
            // source would silently switch the keyboard to that input scheme.
            guard activation.kind != .userDictionary else {
                throw UserKeyboardPublicationError.unavailable(
                    "自定义拼音没有可添加的键盘。要改用其他方案，"
                        + "请在「\(UserTerminology.inputScheme)」中打开该方案，并在「\(UserTerminology.userKeyboard)」中选好键盘后保存。")
            }
            guard let packageID = activation.packageID else { throw UserKeyboardPublicationError.sourceNotInstalled }
            return (
                activation.schemas ?? [],
                center.userKeyboardTransaction(packageID: packageID), packageID, activation.selectedSchemaID
            )
        case .package(let packageID):
            let resources = try await center.keyboardResources(packageID: packageID)
            return (
                resources.schemas, center.userKeyboardTransaction(packageID: packageID), packageID,
                resources.selectedSchemaID
            )
        }
    }
}

/// A source detail must not display another source's published keyboards. It shows the
/// **target source's own** persisted roster (from the publication record's per-source
/// map) even when another source is currently active — so editing/removing rows on a
/// non-current source's page keeps that source's full list instead of collapsing it.
/// Before first publication its list is correctly empty, while the scoped manager still
/// exposes the installed source's validated addable combinations.
struct SourcePublishedKeyboardProvider: PublishedKeyboardListProviding, Sendable {
    let source: UserKeyboardSource

    func snapshot() async throws -> UserKeyboardPublicationView {
        try await KeyboardResourceReadQueue.async {
            let activation = try KeyboardRecipeStore.activation()
            let isCurrent = activation.map { $0.recipeEnabled && matches($0) } ?? false
            let sourceKey = source == .active ? activation?.rosterKey : rosterKey
            guard let activation else {
                return UserKeyboardPublicationView(
                    keyboards: [], roster: [], activation: nil,
                    sourceKey: sourceKey, isCurrent: false)
            }
            // Stopping use changes activation, not the saved roster. The view must
            // retain the same baseline that the publication transaction compares.
            if matches(activation) {
                return UserKeyboardPublicationView(
                    keyboards: ActivationPublishedKeyboardProvider.keyboards(
                        activation.keyboards, schemas: activation.schemas ?? []),
                    roster: activation.keyboards, activation: activation,
                    sourceKey: sourceKey, isCurrent: isCurrent)
            }
            // Another source's schema descriptions cannot name this roster.
            let stored = sourceKey.flatMap { activation.keyboardsBySource?[$0] } ?? []
            return UserKeyboardPublicationView(
                keyboards: ActivationPublishedKeyboardProvider.keyboards(stored, schemas: []),
                roster: stored, activation: activation, sourceKey: sourceKey, isCurrent: false)
        }
    }

    func publishedKeyboards() async throws -> [UserKeyboard] {
        try await snapshot().keyboards
    }

    /// Structured roster key for this source; `.active` has none (uses the flat roster of the current record).
    private var rosterKey: String? {
        switch source {
        case .active: return nil
        case .package(let packageID):
            return KeyboardRecipeStore.rosterKey(kind: .userScheme, packageID: packageID)
        }
    }

    private func matches(_ activation: KeyboardRecipeStore.Activation) -> Bool {
        switch source {
        case .active:
            return true
        case .package(let packageID):
            return activation.kind == .userScheme && activation.packageID == packageID
        }
    }
}
