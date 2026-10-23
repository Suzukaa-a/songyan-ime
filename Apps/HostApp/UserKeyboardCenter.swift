import Combine
import Foundation
import KeyboardCore
import OSLog

/// View model for the host app's "user keyboards" management.
///
/// Responsibilities:
///  * read the display projection of the **published** keyboard list (single source of truth = the publication record);
///  * read the **authoritative addable** combinations (from the publish transaction; this UI infers no capabilities);
///  * add/remove through the same transaction and refresh the list right after success.
///
/// It does **not** keep its own list, write `active.json`, resolve sources, or infer capabilities: those belong to the production
/// adapter files and the canonical transaction. All disk/engine work happens inside the implementation; this type only holds
/// UI state, and errors are never reported as success.
@MainActor
final class UserKeyboardCenter: ObservableObject {
    /// Each page owns its draft and matching publication snapshot; the transaction gate remains shared.
    static func scoped(to source: UserKeyboardSource) -> UserKeyboardCenter {
        UserKeyboardCenter(
            manager: DictionaryImportCenterUserKeyboards(center: .shared, source: source),
            listProvider: SourcePublishedKeyboardProvider(source: source))
    }

    /// Page-level state: loading / ready / read failed / view only.
    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
        /// The management transaction is not wired up yet (read-only): reading works, add/remove are unavailable.
        case readOnly(String)
        /// No applied source yet; start from a concrete input scheme's detail instead of retrying the read.
        case needsSource
    }

    @Published private(set) var phase: Phase = .loading
    /// Published keyboard list (in publish order).
    @Published private(set) var publishedKeyboards: [UserKeyboard] = []
    /// Authoritative addable combinations (only items the transaction provides and that are not yet added).
    @Published private(set) var addableKeyboards: [UserKeyboardCandidate] = []
    /// The keyboard currently in progress (add or remove); nil = idle.
    @Published private(set) var busyKeyboardID: String?
    /// User-facing note for the most recent successful action.
    @Published private(set) var resultMessage: String?
    /// User-facing note for the most recent failure/hint.
    @Published private(set) var errorMessage: String?
    /// For tests and UI to decide whether to present management controls.
    @Published private(set) var supportsManagement = false
    /// Same source, revision and installation generation as the keyboard publication.
    @Published private(set) var sourceIsCurrent = true
    @Published private(set) var sourceNeedsUpdate = false
    /// The keyboard in use (`UserKeyboard.id`); nil when this source is not the one the keyboard runs.
    @Published private(set) var currentKeyboardID: String?
    /// From the same publication read as the visible roster, never a second status read.
    private var viewedPublication: UserKeyboardPublicationView?

    private let manager: UserKeyboardManaging
    private let listProvider: PublishedKeyboardListProviding

    init(
        manager: UserKeyboardManaging,
        listProvider: PublishedKeyboardListProviding = ActivationPublishedKeyboardProvider()
    ) {
        self.manager = manager
        self.listProvider = listProvider
    }

    /// One structured refresh: reads the published list; when manageable, also reads the authoritative addable combinations.
    func refresh() async {
        phase = .loading
        errorMessage = nil
        do {
            let viewed = try await (listProvider as? SourcePublishedKeyboardProvider)?.snapshot()
            let published: [UserKeyboard]
            if let viewed {
                published = viewed.keyboards
            } else {
                published = try await listProvider.publishedKeyboards()
            }
            publishedKeyboards = published
            supportsManagement = manager.supportsManagement
            guard manager.supportsManagement else {
                addableKeyboards = []
                phase = .readOnly(UserTerminology.userKeyboardReadOnlyNotice)
                return
            }
            let addable = try await manager.addableKeyboards()
            updateLists(published: published, addable: addable)
            viewedPublication = viewed
            currentKeyboardID = Self.currentKeyboardID(in: viewed)
            sourceIsCurrent = viewed?.isCurrent ?? true
            sourceNeedsUpdate = false
            if sourceIsCurrent, let viewed, let production = manager as? DictionaryImportCenterUserKeyboards {
                sourceIsCurrent = try await production.isCurrentInstallation(viewed)
                sourceNeedsUpdate = !sourceIsCurrent
            }
            phase = .ready
        } catch UserKeyboardPublicationError.sourceNotInstalled {
            addableKeyboards = []
            phase = .needsSource
        } catch UserKeyboardPublicationError.unavailable(let reason) {
            addableKeyboards = []
            phase = .readOnly(reason)
        } catch {
            // A failed read keeps the old list (no flicker to empty).
            HostLog.append("user keyboard list failed: \(error.localizedDescription)")
            phase = .failed("无法读取我的键盘，请重试。")
        }
    }

    /// Adds a keyboard through the same transaction (generate -> verify -> publish) and refreshes the list right after success.
    func add(_ candidate: UserKeyboardCandidate) async {
        guard busyKeyboardID == nil else { return }
        busyKeyboardID = candidate.id
        errorMessage = nil
        resultMessage = nil
        defer { busyKeyboardID = nil }
        do {
            resultMessage = try await manager.addKeyboard(candidate)
            await reloadAfterMutation(succeeded: true)
        } catch {
            // Only structured pre-write errors prove that the published list did not change.
            HostLog.append("user keyboard add failed: \(error.localizedDescription)")
            errorMessage = UserTerminology.userKeyboardFailureMessage(
                error, fallback: "无法确认结果，请重新读取后重试。")
            await reloadAfterMutation(succeeded: false)
        }
    }

    /// Removes a keyboard through the same transaction and republishes; removed from the list right after success.
    func remove(_ keyboard: UserKeyboard) async {
        guard busyKeyboardID == nil else { return }
        busyKeyboardID = keyboard.id
        errorMessage = nil
        resultMessage = nil
        defer { busyKeyboardID = nil }
        do {
            resultMessage = try await manager.removeKeyboard(keyboard)
            await reloadAfterMutation(succeeded: true)
        } catch {
            HostLog.append("user keyboard removal failed: \(error.localizedDescription)")
            errorMessage = UserTerminology.userKeyboardFailureMessage(
                error, fallback: "无法确认结果，请重新读取后重试。")
            await reloadAfterMutation(succeeded: false)
        }
    }

    /// Submit the complete edited roster once. No per-toggle generation, publication or reload.
    ///
    /// An empty list is not committed: after saving, the keyboard switches to this page's input scheme, and with no keyboard at all typing is impossible.
    /// `selecting` ("use now") also makes that keyboard the one in use; it is added to the roster when missing.
    func apply(_ keyboards: [UserKeyboard], selecting: UserKeyboard? = nil) async -> Bool {
        var keyboards = keyboards
        if let selecting, !keyboards.contains(where: { $0.id == selecting.id }) { keyboards.append(selecting) }
        guard busyKeyboardID == nil else { return false }
        guard !keyboards.isEmpty else {
            resultMessage = nil
            errorMessage = UserTerminology.userKeyboardSaveNeedsOne
            return false
        }
        #if DEBUG
            let saveStarted = Date()
            defer {
                let ms = Date().timeIntervalSince(saveStarted) * 1000
                Logger.keyboardSave.debug("completed in \(ms, format: .fixed(precision: 1), privacy: .public) ms")
            }
        #endif
        busyKeyboardID = "batch"
        errorMessage = nil
        resultMessage = nil
        defer { busyKeyboardID = nil }
        do {
            if let production = manager as? DictionaryImportCenterUserKeyboards {
                guard let viewedPublication else {
                    throw UserKeyboardPublicationError.unavailable("键盘列表尚未读取，请重新读取后保存。")
                }
                resultMessage = try await production.replaceKeyboards(
                    keyboards, selecting: selecting, viewed: viewedPublication)
            } else {
                resultMessage = try await manager.replaceKeyboards(keyboards)
            }
            await reloadAfterMutation(succeeded: true)
            return true
        } catch {
            // Structured pre-write errors preserve the list; an atomic publish error may not.
            HostLog.append("user keyboard batch apply failed: \(error.localizedDescription)")
            errorMessage = UserTerminology.userKeyboardFailureMessage(
                error, fallback: "无法确认结果，请重新读取后重试。")
            await reloadAfterMutation(succeeded: false)
            return false
        }
    }

    /// Re-reads the list and addable items after a change; a failed read does **not** undo a successful write
    /// (the write was committed atomically by the transaction) and only notes that the list may not have refreshed.
    private func reloadAfterMutation(succeeded: Bool) async {
        do {
            let viewed = try await (listProvider as? SourcePublishedKeyboardProvider)?.snapshot()
            let published: [UserKeyboard]
            if let viewed {
                published = viewed.keyboards
            } else {
                published = try await listProvider.publishedKeyboards()
            }
            publishedKeyboards = published
            updateLists(published: published, addable: try await manager.addableKeyboards())
            viewedPublication = viewed
            currentKeyboardID = Self.currentKeyboardID(in: viewed)
            sourceIsCurrent = viewed?.isCurrent ?? true
            sourceNeedsUpdate = false
            if sourceIsCurrent, let viewed, let production = manager as? DictionaryImportCenterUserKeyboards {
                sourceIsCurrent = try await production.isCurrentInstallation(viewed)
                sourceNeedsUpdate = !sourceIsCurrent
            }
            phase = .ready
        } catch {
            HostLog.append("user keyboard reload failed after mutation: \(error.localizedDescription)")
            phase = .failed(
                succeeded
                    ? "操作已完成，但列表未能刷新，请重新打开此页面。"
                    : (errorMessage ?? UserTerminology.genericOperationFailure)
                        + "\n列表未能刷新，请重试。")
        }
    }

    /// Fills the published list with this source's own input method names (records of non-current sources only carry neutral names);
    /// addable items only list combinations not yet published.
    private func updateLists(published: [UserKeyboard], addable: [UserKeyboardCandidate]) {
        publishedKeyboards = UserKeyboardRoster.backfillingNames(published, from: addable)
        let publishedIDs = Set(published.map(\.id))
        addableKeyboards = addable.filter { !publishedIDs.contains($0.id) }
    }

    /// Only a publication of this page's own source has a keyboard in use.
    private static func currentKeyboardID(in viewed: UserKeyboardPublicationView?) -> String? {
        guard let viewed, viewed.isCurrent, let activation = viewed.activation,
            let schemaID = activation.selectedSchemaID, let layout = activation.selectedLayout
        else { return nil }
        return UserKeyboard(inputMethodID: schemaID, inputMethodName: "", layout: layout).id
    }

    func dismissMessages() {
        errorMessage = nil
        resultMessage = nil
    }
}
