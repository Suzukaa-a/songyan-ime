import Combine
import Foundation
import KeyboardCore

// Only publication reads and installer transactions are seams. The production
// status evaluator, entire view model and Save eligibility body are injected.
enum UserKeyboardSource { case active, package(String) }
enum KeyboardRecipeStore {
    struct Activation: Sendable {
        var revision: String
        var hostInstallationGeneration: String?
        var packageID: String?
        var selectedSchemaID: String? = nil
        var selectedLayout: KeyboardLayoutKind? = nil
    }
}
struct UserKeyboardPublicationView: Sendable {
    var keyboards: [UserKeyboard]
    var activation: KeyboardRecipeStore.Activation?
    var isCurrent: Bool
}
@MainActor enum Fixture {
    static let keyboard = UserKeyboard(inputMethodID: "test", inputMethodName: "Test", layout: .qwerty26)
    static var view = UserKeyboardPublicationView(
        keyboards: [keyboard],
        activation: .init(revision: "old", hostInstallationGeneration: "old-generation", packageID: "package"),
        isCurrent: true)
    static var installed = (revision: "new", generation: "new-generation")
    static var reads = 0
    static var identityReads = 0
    static var identityFails = false
    static var writes = 0
    /// When set, the next manager mutation (add/remove/replace) throws; the
    /// mutation itself fails and reloadAfterMutation runs with succeeded=false.
    static var mutationFailsOnce = false
    static func reset(
        revision: String, generation: String?, installedRevision: String,
        installedGeneration: String, current: Bool = true
    ) {
        view = .init(
            keyboards: [keyboard],
            activation: .init(
                revision: revision,
                hostInstallationGeneration: generation, packageID: "package"), isCurrent: current)
        installed = (installedRevision, installedGeneration)
        reads = 0
        identityReads = 0
        writes = 0
        identityFails = false
        mutationFailsOnce = false
        SourcePublishedKeyboardProvider.snapshotFailsOnce = false
    }
}
@MainActor final class SchemeImportCenter {
    static let shared = SchemeImportCenter()
    func installedKeyboardIdentity(packageID: String?) async throws -> (revision: String, generation: String) {
        precondition(packageID == "package")
        Fixture.identityReads += 1
        if Fixture.identityFails { throw NSError(domain: "fixture", code: 1) }
        return Fixture.installed
    }
}
@MainActor final class DictionaryImportCenterUserKeyboards: UserKeyboardManaging {
    let center: SchemeImportCenter
    init(center: SchemeImportCenter, source: UserKeyboardSource) { self.center = center }
    var supportsManagement: Bool { true }
    func addableKeyboards() async throws -> [UserKeyboardCandidate] {
        [.init(inputMethodID: "test", inputMethodName: "Test", layout: .qwerty26)]
    }
    func addKeyboard(_ candidate: UserKeyboardCandidate) async throws -> String {
        if Fixture.mutationFailsOnce {
            Fixture.mutationFailsOnce = false
            throw NSError(domain: "fixture", code: 3)
        }
        return "added"
    }
    func removeKeyboard(_ keyboard: UserKeyboard) async throws -> String {
        if Fixture.mutationFailsOnce {
            Fixture.mutationFailsOnce = false
            throw NSError(domain: "fixture", code: 3)
        }
        return "removed"
    }
    func replaceKeyboards(_ keyboards: [UserKeyboard]) async throws -> String { "saved" }
    func replaceKeyboards(
        _ keyboards: [UserKeyboard], selecting: UserKeyboard? = nil, viewed: UserKeyboardPublicationView
    ) async throws -> String {
        if Fixture.mutationFailsOnce {
            Fixture.mutationFailsOnce = false
            throw NSError(domain: "fixture", code: 3)
        }
        // CAS baseline: the save must receive the publication snapshot the page
        // captured (either the normal view or the stopped-source presentation).
        precondition(
            viewed.activation?.revision == Fixture.view.activation?.revision,
            "the save receives the original captured publication")
        Fixture.writes += 1
        Fixture.view.keyboards = keyboards
        let current = selecting ?? keyboards.first
        Fixture.view.activation = .init(
            revision: Fixture.installed.revision,
            hostInstallationGeneration: Fixture.installed.generation, packageID: "package",
            selectedSchemaID: current?.inputMethodID, selectedLayout: current?.layout)
        Fixture.view.isCurrent = true
        return selecting.map { "using \($0.id)" } ?? "saved"
    }
    // PRODUCTION_EVALUATOR
}
struct SourcePublishedKeyboardProvider: PublishedKeyboardListProviding, Sendable {
    let source: UserKeyboardSource
    /// When set, snapshot() throws once so a mutation-triggered reload can be
    /// observed failing after the mutation itself already succeeded.
    @MainActor static var snapshotFailsOnce = false
    @MainActor func snapshot() async throws -> UserKeyboardPublicationView {
        Fixture.reads += 1
        if Self.snapshotFailsOnce {
            Self.snapshotFailsOnce = false
            throw NSError(domain: "fixture", code: 2)
        }
        return Fixture.view
    }
    @MainActor func publishedKeyboards() async throws -> [UserKeyboard] {
        // Production routes the flat list through snapshot() so both read paths
        // share one semantics; mirror that here.
        try await snapshot().keyboards
    }
}
struct ActivationPublishedKeyboardProvider: PublishedKeyboardListProviding, Sendable {
    @MainActor func publishedKeyboards() async throws -> [UserKeyboard] { Fixture.view.keyboards }
}
enum HostLog { static func append(_ line: String) {} }

// PRODUCTION_CENTER

@MainActor struct SaveEligibility {
    let center: UserKeyboardCenter
    let initialized: Bool
    let hasChanges: Bool
    let selectedRoster: [UserKeyboard]
    var selectedIDs: Set<String> { Set(selectedRoster.map(\.id)) }
    var baselineIDs: Set<String> { hasChanges ? [] : selectedIDs }
    /// Mirrors the view's synchronous save-in-flight flag: while a save Task is
    /// running the view must not offer save again and dismissal guards must hold.
    var isSaving = false
    // PRODUCTION_SAVE_ELIGIBILITY
}

struct DraftChanges {
    let initialized: Bool
    let hasEditedSelection: Bool
    let selectedIDs: Set<String>
    let baselineIDs: Set<String>
    // PRODUCTION_DRAFT_CHANGES
}

@main struct InstallationProbe {
    @MainActor static func main() async {
        func makeCenter() -> UserKeyboardCenter {
            .scoped(to: .package("package"))
        }
        func canSave(
            _ center: UserKeyboardCenter, roster: [UserKeyboard]? = nil,
            isSaving: Bool = false
        ) -> Bool {
            SaveEligibility(
                center: center, initialized: true, hasChanges: false,
                selectedRoster: roster ?? [Fixture.keyboard], isSaving: isSaving
            ).canSave
        }
        // Same source, unchanged roster, different installed revision.
        Fixture.reset(
            revision: "old", generation: "same-generation", installedRevision: "new",
            installedGeneration: "same-generation")
        let updated = makeCenter()
        await updated.refresh()
        precondition(updated.sourceNeedsUpdate && !updated.sourceIsCurrent && canSave(updated))
        precondition(
            Fixture.reads == 1 && Fixture.identityReads == 1,
            "source and roster use a single publication snapshot")
        precondition(!canSave(updated, roster: []))
        let saved = await updated.apply([Fixture.keyboard])
        precondition(saved && Fixture.writes == 1)
        precondition(
            updated.sourceIsCurrent && !updated.sourceNeedsUpdate && !canSave(updated),
            "a successful updated installation returns to the current state")
        print("PASS: unchanged roster can explicitly apply an installed update")

        // A reinstall can change the installation generation without changing its revision.
        Fixture.reset(revision: "same", generation: "before", installedRevision: "same", installedGeneration: "after")
        let reinstalled = makeCenter()
        await reinstalled.refresh()
        precondition(reinstalled.sourceNeedsUpdate && canSave(reinstalled))
        Fixture.reset(revision: "same", generation: nil, installedRevision: "same", installedGeneration: "after")
        let unidentified = makeCenter()
        await unidentified.refresh()
        precondition(unidentified.sourceNeedsUpdate && canSave(unidentified))
        print("PASS: installation generation and a missing identity are checked")

        Fixture.reset(
            revision: "same", generation: "generation", installedRevision: "same", installedGeneration: "generation")
        let current = makeCenter()
        await current.refresh()
        precondition(current.sourceIsCurrent && !current.sourceNeedsUpdate && !canSave(current))
        let suggested = DraftChanges(
            initialized: true, hasEditedSelection: false,
            selectedIDs: [Fixture.keyboard.id], baselineIDs: [])
        precondition(!suggested.hasChanges, "An automatic suggestion must allow Back without discard confirmation")
        precondition(
            SaveEligibility(
                center: current, initialized: true, hasChanges: true,
                selectedRoster: [Fixture.keyboard]
            ).canSave,
            "A suggested selection is still eligible to apply")
        let edited = DraftChanges(
            initialized: true, hasEditedSelection: true,
            selectedIDs: [Fixture.keyboard.id], baselineIDs: [])
        precondition(edited.hasChanges, "An explicit edit must retain discard protection")
        print("PASS: automatic suggestions can be saved without trapping Back navigation")
        Fixture.reset(
            revision: "same", generation: "generation", installedRevision: "same",
            installedGeneration: "generation", current: false)
        let other = makeCenter()
        await other.refresh()
        precondition(!other.sourceIsCurrent && !other.sourceNeedsUpdate && canSave(other))
        precondition(Fixture.identityReads == 0)
        print("PASS: current no-op and explicit switch to another source keep their behavior")

        Fixture.reset(
            revision: "same", generation: "generation", installedRevision: "same", installedGeneration: "generation")
        Fixture.identityFails = true
        let unreadable = makeCenter()
        await unreadable.refresh()
        if case .failed = unreadable.phase {} else { preconditionFailure("failed identity must not claim ready") }
        precondition(!canSave(unreadable) && Fixture.writes == 0)
        print("PASS: unreadable installation fails closed")

        // While the view's synchronous save Task is in flight the roster still
        // describes an eligible save, but the flag must keep canSave false so
        // retry, back navigation and dismissal stay blocked.
        Fixture.reset(
            revision: "same", generation: "generation", installedRevision: "new", installedGeneration: "generation")
        let midSave = makeCenter()
        await midSave.refresh()
        precondition(canSave(midSave), "an updated source with a roster is eligible before saving")
        precondition(
            !canSave(midSave, isSaving: true),
            "an in-flight save must disable further saves and dismissal")
        print("PASS: in-flight save keeps the save button disabled")

        // A failed save mutation must return false, surface an error and keep
        // the roster untouched — never a false completion or a second write.
        Fixture.reset(
            revision: "same", generation: "generation", installedRevision: "same", installedGeneration: "generation")
        Fixture.mutationFailsOnce = true
        let failedSave = makeCenter()
        await failedSave.refresh()
        let failedApplied = await failedSave.apply([Fixture.keyboard])
        precondition(!failedApplied && Fixture.writes == 0, "a failed save reports failure without writing")
        precondition(failedSave.resultMessage == nil, "a failed save must not claim a completion message")
        precondition(failedSave.errorMessage != nil, "a failed save must surface an error message")
        print("PASS: failed save reports failure without false completion")

        // A failed mutation whose reload also fails must land in .failed with
        // the combined wording — an earlier implementation reported this as completed.
        // The reload failure is armed only after refresh() has succeeded so it
        // lands inside apply's own reloadAfterMutation, not in refresh().
        Fixture.reset(
            revision: "same", generation: "generation", installedRevision: "same", installedGeneration: "generation")
        Fixture.mutationFailsOnce = true
        let failedBoth = makeCenter()
        await failedBoth.refresh()
        SourcePublishedKeyboardProvider.snapshotFailsOnce = true
        let failedBothApplied = await failedBoth.apply([Fixture.keyboard])
        precondition(!failedBothApplied && Fixture.writes == 0)
        guard case .failed(let failedMessage) = failedBoth.phase else {
            preconditionFailure("mutation + reload both failing must be .failed, not ready")
        }
        precondition(
            failedMessage.contains("请重新读取后重试"),
            "combined failure must carry the retry wording, got: \(failedMessage)")
        precondition(failedBoth.resultMessage == nil, "no completion message on double failure")
        print("PASS: mutation and reload both failing surfaces combined failure")

        // A successful mutation whose reload then fails must not report the
        // mutation as completed-with-failed-reload being silently swallowed:
        // the write happened, apply still returns true, and the phase carries
        // the explicit "已完成，但列表未能刷新" wording.
        Fixture.reset(
            revision: "same", generation: "generation", installedRevision: "same", installedGeneration: "generation")
        let savedButStale = makeCenter()
        await savedButStale.refresh()
        SourcePublishedKeyboardProvider.snapshotFailsOnce = true
        let appliedStale = await savedButStale.apply([Fixture.keyboard])
        precondition(appliedStale && Fixture.writes == 1, "the write itself succeeded")
        guard case .failed(let staleMessage) = savedButStale.phase else {
            preconditionFailure("reload failure after a successful mutation must be visible, not ready")
        }
        precondition(
            staleMessage.contains("已完成，但列表未能刷新"),
            "successful mutation + failed reload must use the succeeded wording, got: \(staleMessage)")
        precondition(
            savedButStale.resultMessage == "saved",
            "the mutation's own completion message is preserved from the write")
        print("PASS: successful mutation with failed reload reports explicitly")

        // "Use now" on a pair that is not in the roster yet adds it, makes it the
        // keyboard in use, and the reload reports it as current.
        Fixture.reset(
            revision: "same", generation: "generation", installedRevision: "same", installedGeneration: "generation")
        let nine = UserKeyboard(inputMethodID: "test", inputMethodName: "Test", layout: .phone9)
        let using = makeCenter()
        await using.refresh()
        precondition(using.currentKeyboardID == nil, "a publication without a selection has no keyboard in use")
        let used = await using.apply([Fixture.keyboard], selecting: nine)
        precondition(used && Fixture.writes == 1)
        precondition(Fixture.view.keyboards.map(\.id) == [Fixture.keyboard.id, nine.id], "the used pair is added")
        precondition(using.currentKeyboardID == nine.id, "the used pair is reported as in use")
        precondition(using.resultMessage == "using \(nine.id)")
        print("PASS: use now adds the pair and reports it as in use")

        // Another source's publication never marks a keyboard of this page as in use.
        Fixture.reset(
            revision: "same", generation: "generation", installedRevision: "same",
            installedGeneration: "generation", current: false)
        Fixture.view.activation?.selectedSchemaID = "test"
        Fixture.view.activation?.selectedLayout = .qwerty26
        let elsewhere = makeCenter()
        await elsewhere.refresh()
        precondition(elsewhere.currentKeyboardID == nil)
        print("PASS: only the page's own source has a keyboard in use")
    }
}
