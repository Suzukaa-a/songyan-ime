import Foundation
import KeyboardCore

/// What the keyboard currently uses (an installed input scheme or the built-in one), as read
/// from the shared selection, plus the "switch back to built-in" action.
///
/// Installing, applying and editing a scheme live in the scheme/dictionary centers; this center
/// only mirrors the shared selection so every screen can react to a switch.
@MainActor
final class KeyboardSelectionCenter: ObservableObject {
    static let shared = KeyboardSelectionCenter()

    enum ApplicationPhase: Equatable {
        case idle, applying, done
        case failed(String)
    }

    @Published private(set) var applicationPhase: ApplicationPhase = .idle
    /// True when the keyboard uses an installed input scheme rather than the built-in one.
    @Published private(set) var usesInstalledScheme = false

    var isBusy: Bool { applicationPhase == .applying }

    /// Whose 我的键盘 a general entry opens: with nothing published the keyboard runs the built-in
    /// scheme, so its keyboards are the ones to edit.
    var userKeyboardSource: UserKeyboardSource {
        usesInstalledScheme ? .active : .package(ProductionInputAvailability.builtinPackageID)
    }

    /// Latest-wins gate: a late read never overwrites a newer value.
    private var gate = LatestWinsReadGate()
    private var snapshot = AppliedSelectionSnapshot.none
    private var switchTask: Task<Void, Never>?

    /// Reads the shared selection on the read queue; the main actor only applies the result.
    func refresh() async {
        let token = gate.begin()
        let outcome = await AppliedSelectionLoader.load()
        guard
            StructuredRefreshOutcome.shouldApply(
                isCancelled: Task.isCancelled,
                accepted: gate.accepts(token))
        else { return }
        let resolved = AppliedSelectionSnapshot.resolve(previous: snapshot, outcome: outcome)
        snapshot = resolved.snapshot
        usesInstalledScheme = resolved.snapshot.recipeEnabled
        HostLog.append(
            "keyboard selection: "
                + (resolved.error ?? resolved.snapshot.keyboardStatusLine(requiresFullAccessNote: false)))
    }

    /// Keeps the publication but makes the keyboard use the built-in scheme.
    func switchToBuiltin() {
        guard !isBusy else { return }
        applicationPhase = .applying
        switchTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await EngineOpQueue.async {
                    try KeyboardRecipeStore.setEnabled(false)
                }
                usesInstalledScheme = false
                await refresh()
                applicationPhase = .done
            } catch {
                HostLog.append("keyboard selection save failed: \(error.localizedDescription)")
                let missingGroup = await AppliedSelectionLoader.sharedContainerUnavailable()
                applicationPhase = .failed(
                    missingGroup
                        ? AppliedSelectionLoader.missingGroupMessage
                        : "无法确认结果，请重新读取后重试。")
                await refresh()
            }
        }
    }
}
