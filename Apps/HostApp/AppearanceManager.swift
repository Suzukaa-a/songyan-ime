import AppearanceKit
import CandidateKit
import KeyboardCore
import SkinKit
import SwiftUI

/// Serial background queue for host-side appearance/layout configuration I/O.
///
/// Separate from `KeyboardResourceReadQueue` (low-priority reads): this queue runs operations that may create
/// directories, write files atomically and read them back (appearance/layout persistence), in order.
/// The main thread only awaits results and never touches disk.
///
/// Shared by `AppearanceManager` and `LayoutManager`.
enum HostConfigIOQueue {
    private static let serial = DispatchQueue(label: "app.songyan.host.config.io", qos: .utility)

    /// Runs configuration I/O on the serial background queue without blocking the caller.
    static func async<T>(_ body: @escaping @Sendable () throws -> T) async throws -> sending T {
        try await withCheckedThrowingContinuation { continuation in
            serial.async {
                do { continuation.resume(returning: try body()) } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

/// Unified appearance-item manager (the host app's only writer).
///
/// Replaces the separate `SkinManager` and `CandidateBarManager` selections:
/// the user works with one appearance item = keyboard skin + candidate-area layout behavior + display mode,
/// and save/apply/import/export all act on that single identity, so two selections cannot drift apart.
///
/// Storage layers:
///   - local draft store: `KeyboardAppearanceDrafts/` (editing and saving; works without the shared container);
///   - shared snapshot: `KeyboardAppearance/active.json` (the only source the keyboard extension reads).
///
/// Threading and disk discipline:
///   - init does no disk I/O: state starts from built-in defaults, and reads run on
///     `HostConfigIOQueue` while the main thread only applies results;
///   - reads use a latest-wins gate plus a cancellation gate: a late read never overwrites a newer read or a
///     completed save/apply (user actions invalidate in-flight reads first);
///   - user-initiated draft operations (`save`/`remove`/`apply` writes and list reloads) still run synchronously
///     on the main thread because `AdvancedSettingsView` calls `try manager.save(...)` synchronously.
@MainActor final class AppearanceManager: ObservableObject {
    static let shared = AppearanceManager()

    /// Local draft store (including read-only built-in defaults).
    @Published private(set) var projects: [AppearanceDocument] = [.systemDefault]
    /// The currently applied appearance (the one in the shared snapshot).
    @Published private(set) var applied: AppearanceDocument = .systemDefault
    /// Where the applied snapshot came from (applied snapshot / built-in default).
    @Published private(set) var appliedSource: AppearanceSnapshotSource = .systemDefault
    /// Display mode committed together with apply.
    @Published var editingAppearance: SkinAppearance = .system
    @Published var message: String?
    /// Explicit error (read/write failure reason).
    @Published var error: String?
    /// Whether the first (or latest) background read is still running; avoids showing "not read yet" as a false
    /// "appearance not found" conclusion.
    @Published private(set) var isLoading = true
    /// The local placeholder default is not the keyboard's applied state; "in use" is shown only once a shared read confirms it.
    @Published private(set) var sharedReadConfirmed = false

    private var local: AppearanceStore { RimePaths.localAppearanceStore() }

    /// Latest-wins gate for background reads: a late read must not overwrite a newer read or a completed user action.
    private var loadGate = LatestWinsReadGate()
    /// In-flight read task; `reload()` and user actions cancel it (only the result is dropped, not the underlying I/O).
    private var loadTask: Task<Void, Never>?

    /// Init does not touch disk: starts from the built-in defaults, then reads on the background queue.
    init() {
        reload()
    }

    var isSharedAvailable: Bool { RimePaths.sharedAppearanceStore() != nil }

    /// Re-reads the snapshot and drafts on `HostConfigIOQueue`; returns immediately.
    ///
    /// `message` carries only operation results; the notice for an appearance from a degraded
    /// source comes from `appliedSourceNotice`, to avoid duplication.
    func reload() {
        message = nil
        error = nil
        isLoading = true
        let token = loadGate.begin()
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let result = await Self.readState()
            // Cancellation gate + latest-wins gate: UI state is overwritten only if both pass.
            guard let self,
                StructuredRefreshOutcome.shouldApply(
                    isCancelled: Task.isCancelled,
                    accepted: self.loadGate.accepts(token))
            else { return }
            self.applyLoadedState(result)
        }
    }

    /// Background read (Sendable values in and out; the closure captures no MainActor objects).
    private nonisolated static func readState() async -> AppearanceLoadResult {
        do {
            return try await HostConfigIOQueue.async {
                var result = AppearanceLoadResult()
                let local = RimePaths.localAppearanceStore()

                if let shared = RimePaths.sharedAppearanceStore() {
                    let read = shared.read()
                    result.applied = read.snapshot.document
                    result.appliedSource = read.source
                    result.sharedReadConfirmed = read.error == nil
                    result.editingAppearance = read.snapshot.document.appearance
                    result.error = read.error
                } else {
                    let sharedError = "键盘暂时无法读取外观，外观仍保留在本机。"
                    result.error = result.error.map { $0 + "\n" + sharedError } ?? sharedError
                }

                do {
                    result.projects = try local.list()
                } catch {
                    result.projects = [.systemDefault]
                    if result.error == nil { result.error = "无法读取外观。" }
                }
                return result
            }
        } catch {
            // The queue only throws if this closure throws; read paths already convert failures to `error`, so this is purely defensive.
            var result = AppearanceLoadResult()
            result.error = "无法读取外观。"
            return result
        }
    }

    /// Applies the background result on the main thread.
    private func applyLoadedState(_ result: AppearanceLoadResult) {
        projects = result.projects
        applied = result.applied
        appliedSource = result.appliedSource
        sharedReadConfirmed = result.sharedReadConfirmed
        editingAppearance = result.editingAppearance
        error = result.error
        isLoading = false
    }

    /// Saves a draft (does not affect the applied appearance until it is explicitly applied).
    ///
    /// User actions take priority: invalidate in-flight reads first so a stale read cannot overwrite the draft just saved.
    func save(_ document: AppearanceDocument, replacing: Bool) throws {
        loadGate.invalidate()
        isLoading = false
        try local.save(document, replacing: replacing)
        projects = try local.list()
        message = "已保存"
    }

    /// Deletes an appearance item: removes only the project file in the local draft store (shared-container files
    /// are untouched); the applied snapshot keeps its content until the next apply.
    func remove(_ id: String) {
        loadGate.invalidate()
        isLoading = false
        do {
            try local.remove(id)
            projects = try local.list()
            message = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Apply: display mode, skin and candidate-area layout take effect in one atomic commit.
    ///
    /// Order: validate, backfill draft store, backfill shared store, atomically apply shared snapshot, notify keyboard.
    /// A failure at any step never leaves a half-applied state.
    ///
    /// User actions take priority: invalidate in-flight reads first so a stale read cannot roll back a completed apply.
    /// - Parameter persistDraft: when false, the local draft store is not written back (used only when switching light/dark,
    ///   so applied content does not overwrite unapplied draft edits in the same item).
    func apply(_ document: AppearanceDocument, persistDraft: Bool = true) {
        loadGate.invalidate()
        isLoading = false
        do {
            var target = document
            target.appearance = editingAppearance
            guard let shared = RimePaths.sharedAppearanceStore() else {
                throw AppearanceApplyFailure(text: "键盘暂时无法读取外观，外观已保存在本机。")
            }
            if !target.isSystemDefault {
                // Built-in presets are read-only: nothing is written to the local draft store; content is only committed to the shared store for the keyboard.
                if persistDraft, !target.isBuiltin { try local.save(target, replacing: true) }
                try shared.save(target, replacing: true)
            }
            try shared.apply(target)
            applied = target.normalized()
            appliedSource = .applied
            sharedReadConfirmed = true
            editingAppearance = applied.appearance
            projects = try local.list()
            message = "已应用，下次打开键盘时生效。"
            error = nil
            NotificationCenter.default.post(name: .keyboardAppearanceChanged, object: nil)
        } catch {
            HostLog.append("appearance apply failed: \(error.localizedDescription)")
            self.error = (error as? AppearanceApplyFailure)?.text ?? "应用失败，请重试。"
        }
    }

    /// "In use / has unapplied changes" check: compares both appearance content and display mode.
    func applicationStatus(for document: AppearanceDocument) -> String? {
        guard !isLoading, sharedReadConfirmed, document.id == applied.id else { return nil }
        return document.normalized() == applied.normalized() && editingAppearance == applied.appearance
            ? UserTerminology.statusInUse : "修改未应用"
    }

    /// Candidate-area layout summary for list rows (layout parameters belong to the item).
    func candidateSummary(for document: AppearanceDocument) -> String {
        CandidateAreaSummary.text(for: document.candidateBar)
    }

    /// Notice shown when the applied appearance comes from a degraded source (nil = normal apply path).
    ///
    /// No "appearance not found" conclusion before the first background read completes, so "still reading" is never shown as fact.
    var appliedSourceNotice: String? {
        if isLoading { return "正在读取外观设置…" }
        guard sharedReadConfirmed else { return nil }
        switch appliedSource {
        case .applied:
            guard !projects.contains(where: { $0.id == applied.id }) else { return nil }
            return "键盘正在使用「\(applied.name)」，它已不在列表中。"
        case .systemDefault: return "当前正在使用「系统默认」外观。"
        }
    }
}

/// User-facing explanation for an apply failure (raw errors go only to the diagnostic log).
private struct AppearanceApplyFailure: Error { let text: String }

/// Full result of a background read (Sendable values; passed across queues, the closure holds no MainActor objects).
private struct AppearanceLoadResult: Sendable {
    var projects: [AppearanceDocument] = [.systemDefault]
    var applied: AppearanceDocument = .systemDefault
    var appliedSource: AppearanceSnapshotSource = .systemDefault
    var sharedReadConfirmed = false
    var editingAppearance: SkinAppearance = .system
    var error: String?
}

/// Candidate-area layout summary (shared by list rows and detail; describes layout behavior only, no colors or font sizes).
enum CandidateAreaSummary {
    static func text(for bar: CandidateBarDefinition) -> String {
        let composition =
            [
                "composingOnly": "拼写行·输入时显示", "composingWithIdleRaw": "拼写行·始终显示",
                "hidden": "拼写行·隐藏",
            ][bar.compositionRow.visible.rawValue] ?? ""
        return [composition, expandedText(bar.expanded)]
            .joined(separator: " · ")
    }

    static func expandedText(_ expanded: CandidateBarDefinition.Expanded) -> String {
        switch expanded.mode {
        case .adaptive: return "展开·自适应"
        case .list: return "展开·单列"
        case .grid: return "展开·\(expanded.columns)列"
        }
    }

    static func icon(_ mode: CandidateBarDefinition.Expanded.Mode) -> String {
        switch mode {
        case .adaptive: return "text.alignleft"
        case .list: return "list.bullet"
        case .grid: return "square.grid.2x2"
        }
    }
}
