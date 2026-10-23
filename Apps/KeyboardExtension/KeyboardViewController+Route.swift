import CandidateKit
import Combine
import KeyboardCore
import LayoutKit
import OSLog
import SwiftUI
import UIKit

extension KeyboardViewController {
    func selectBuiltin(_ builtin: Bool) {
        guard Self.activeController === self, !selectionSaveInFlight else { return }
        if builtin && !hasFullAccess && session.resourceSet == nil { return }
        let runningGeneration = session.resourceSet?.publicationGeneration
        selectionSaveInFlight = true
        selectionSaveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                selectionSaveInFlight = false
                selectionSaveTask = nil
            }
            do {
                guard hasFullAccess else {
                    throw KeyboardRecipeStore.StoreError(message: "保存切换需要开启「允许完全访问」；已保留上次的选择")
                }
                try await EngineOpQueue.async {
                    try KeyboardRecipeStore.setEnabled(!builtin, expectedGeneration: runningGeneration)
                }
                guard Self.activeController === self else { return }
                route.selectionError = nil
                route.recovery = nil
                Self.rescuedRoute = nil
                route.explainRecipeAvailability = !builtin
                refreshResourceRoute()
            } catch {
                guard Self.activeController === self else { return }
                Self.diagnosticLogger.error(
                    "recipe selection save failed: \(error.localizedDescription, privacy: .private)")
                let message = "无法确认方案保存结果，请重新读取后重试。"
                route.selectionError = message
                route.recovery = builtin ? .saveBuiltin : .applyRecipe
                route.notice = message
                route.message = message
            }
        }
    }

    func retryRoute(_ operation: ExtensionRouteStatus.Recovery) {
        guard Self.activeController === self else { return }
        switch operation {
        case .saveBuiltin: selectBuiltin(true)
        case .applyRecipe: selectBuiltin(false)
        case .reloadConfiguration:
            Self.rescuedRoute = nil
            refreshResourceRoute()
        }
    }

    func restoreBuiltinTemporarily() {
        guard Self.activeController === self else { return }
        if Self.rescuedRoute == nil { Self.rescuedRoute = Self.applied?.key ?? "" }
        Self.applied?.key = "builtin"
        route.schemeName = ProductionInputAvailability.runtimeUnconfiguredSchemeName
        route.message = "已临时使用\(ProductionInputAvailability.fallbackInputMethodName)；已保存的选择未更改。"
        if session.resourceSet != nil {
            session.restoreConfiguredRoute()
        } else if case .failed = session.phase {
            session.retry()
        } else {
            session.start()
        }
    }

    /// Shown when a choice is made while the keyboard was temporarily switched to the bundled fallback.
    var temporaryBuiltinSelectionNotice: String {
        "暂时使用\(ProductionInputAvailability.fallbackInputMethodName)，下次打开键盘时恢复原来的选择。"
    }

    var inactivePublicationSelectionNotice: String {
        "输入方案已在 App 中更改：本次切换仅在本次打开键盘时有效，未保存。"
    }

    /// One route resolution. Crosses concurrency domains, so it holds only Sendable values.
    struct ResolvedRoute: Sendable {
        enum Outcome: Sendable {
            case resource(KeyboardResourceSet)
            case unconfigured
            case failed(category: String, code: Int, userMessage: String)
        }
        var outcome: Outcome
        var key: String
        var reason: String
        var notice: String?
        var schemeName: String
    }

    private enum RouteRefreshResult: Sendable {
        /// The shared record still names the running generation and selection.
        case unchanged
        case resolved(ResolvedRoute)
    }

    /// Runs on the read queue: one bounded read of `active.json`, and a full resolve only when it no longer
    /// matches the running route. Captures nothing from the controller. Without Full Access a keyboard
    /// still has read-only access to the App Group, so the published choice applies either way.
    nonisolated private static func resolveRoute(
        running: KeyboardRouteKey?, explainRecipeAvailability: Bool
    ) -> RouteRefreshResult {
        let selection = KeyboardRecipeStore.readSelection()
        if let running, KeyboardRecipeStore.selection(selection, matches: running) { return .unchanged }
        return .resolved(resolveSelection(selection, explainRecipeAvailability: explainRecipeAvailability))
    }

    nonisolated private static func resolveSelection(
        _ selection: KeyboardRecipeStore.SelectionRead, explainRecipeAvailability: Bool
    ) -> ResolvedRoute {
        let reason = ProductionInputAvailability.runtimeUnconfiguredReason
        do {
            let snapshot = try KeyboardRecipeStore.snapshot(selection: selection, selectedOnly: true)
            if let snapshot {
                guard
                    let user = RimePaths.recipeUserDirectory(
                        kind: snapshot.activation.kind,
                        packageID: snapshot.activation.packageID)
                else {
                    throw KeyboardRecipeStore.StoreError(message: "无法访问键盘词库存储目录")
                }
                let base = snapshot.resourceSet(userDirectory: user)
                // The extension offers only keyboards the host app has added: a record with a list or a selection shows
                // only the listed combinations. Never discovers or prepares unadded combinations.
                let desired =
                    snapshot.activation.enforcesPublishedKeyboards
                    ? base.restricted(toPublished: snapshot.activation.keyboards)
                    : base
                let key = snapshot.activation.generation + ":" + (snapshot.activation.selectedSchemaID ?? "")
                diagnosticLogger.debug(
                    "resolved published revision: \(snapshot.activation.revision, privacy: .private)")
                return ResolvedRoute(
                    outcome: .resource(desired), key: key,
                    reason: "\(snapshot.activation.name) · 预编译", notice: nil,
                    schemeName: desired.name)
            }
            return ResolvedRoute(
                outcome: .unconfigured, key: "builtin", reason: reason,
                notice: explainRecipeAvailability ? ProductionInputAvailability.runtimeUnconfiguredNotice : nil,
                schemeName: ProductionInputAvailability.runtimeUnconfiguredSchemeName)
        } catch {
            return failedRoute(error)
        }
    }

    nonisolated private static func failedRoute(_ error: Error) -> ResolvedRoute {
        let failure = sharedRecipeReadFailure(error)
        return ResolvedRoute(
            outcome: .failed(
                category: failure.category, code: failure.code,
                userMessage: failure.userMessage),
            key: "builtin",
            reason: ProductionInputAvailability.runtimeUnconfiguredReason, notice: nil,
            schemeName: ProductionInputAvailability.runtimeUnconfiguredSchemeName)
    }

    /// Classifies a resolution failure (static, no instance state, callable from a background thread).
    nonisolated private static func sharedRecipeReadFailure(_ error: Error) -> (
        category: String, code: Int, userMessage: String
    ) {
        if let storeError = error as? KeyboardRecipeStore.StoreError {
            diagnosticLogger.error(
                "shared recipe store read failed: \(storeError.localizedDescription, privacy: .private)")
            return ("store", 0, "暂时无法读取输入方案，请打开「松烟」App 重新选择。")
        }
        if error is DecodingError {
            return ("decode", 0, "输入方案记录已损坏，请打开「松烟」App 重新选择。")
        }
        let cocoa = error as NSError
        if cocoa.domain == NSCocoaErrorDomain {
            return ("filesystem", cocoa.code, "暂时无法读取输入方案文件，请打开「松烟」App 重新选择。")
        }
        return ("unexpected", cocoa.code, "无法读取输入方案，请打开「松烟」App 重新选择。")
    }

    /// `viewWillAppear` refreshes first and the repeat from `viewDidAppear` is skipped, so one appearance reads once.
    func refreshRouteOncePerAppearance() {
        guard !routeRefreshedThisAppearance else { return }
        routeRefreshedThisAppearance = true
        refreshResourceRoute()
    }

    /// Route refresh entry point (appearance, scheme change, retry). One task per call; a newer call cancels
    /// the previous one. The file read runs on `KeyboardResourceReadQueue`; the main thread only snapshots
    /// in-memory state and applies the result, and only if the task was not cancelled.
    func refreshResourceRoute() {
        routeTask?.cancel()
        routeTask = nil
        guard Self.activeController === self else { return }
        let explainRecipeAvailability = route.explainRecipeAvailability
        let rescued = Self.rescuedRoute
        // Reuse needs a ready engine, a previous result to restore and no pending rescue.
        let running = Self.applied != nil && rescued == nil ? session.runningRouteKey : nil
        routeTask = Task { @MainActor [weak self] in
            let result = await KeyboardLifecycleDiagnostics.measureAsync("routePlan") { () -> RouteRefreshResult in
                do {
                    return try await KeyboardResourceReadQueue.async {
                        Self.resolveRoute(running: running, explainRecipeAvailability: explainRecipeAvailability)
                    }
                } catch {
                    return .resolved(Self.failedRoute(error))
                }
            }
            guard !Task.isCancelled, let self else { return }
            switch result {
            case .unchanged:
                guard Self.rescuedRoute == nil, let applied = Self.applied else { return }
                self.route.message = applied.reason
                self.route.notice = self.route.selectionError ?? applied.notice
                self.route.schemeName = applied.schemeName
                KeyboardLifecycleDiagnostics.emit(
                    "routeRefresh.decision",
                    [
                        "result": "reuse",
                        "phase": self.phaseLabel(self.session?.phase),
                        "footprintBytes": String(KeyboardLifecycleDiagnostics.footprintBytes),
                        "route": self.session?.runningRouteKey?.diagnosticDescription ?? "-",
                    ])
            case .resolved(let resolved):
                self.apply(resolved: resolved, rescued: rescued)
                KeyboardLifecycleDiagnostics.emit(
                    "routeRefresh.decision",
                    [
                        "result": "apply",
                        "phase": self.phaseLabel(self.session?.phase),
                        "route": self.session?.runningRouteKey?.diagnosticDescription ?? "-",
                    ])
            }
        }
    }

    func apply(resolved: ResolvedRoute, rescued: String?) {
        var key = resolved.key
        var notice = resolved.notice
        var reason = resolved.reason
        var desired: KeyboardResourceSet?
        switch resolved.outcome {
        case .resource(let resource):
            desired = resource
        case .unconfigured:
            desired = nil
        case .failed(let category, let code, let userMessage):
            Self.diagnosticLogger.error(
                """
                shared recipe read failed category=\(category, privacy: .public) \
                code=\(code, privacy: .public)
                """)
            route.message = userMessage
            route.notice = route.selectionError ?? "无法读取输入方案更新；继续使用当前输入方案。"
            if route.selectionError == nil { route.recovery = .reloadConfiguration }
            // A read failure must not tear down a usable session or save a fallback.
            // `start()` is idempotent and only boots when nothing is running.
            session.start()
            return
        }
        if let rescuedRoute = rescued {
            if key == rescuedRoute {
                desired = nil
                key = "builtin"
                reason = "临时使用\(ProductionInputAvailability.fallbackInputMethodName)；已保存的选择未更改。"
                notice = nil
            } else {
                Self.rescuedRoute = nil
            }
        }
        route.message = reason
        route.notice = route.selectionError ?? notice
        if route.selectionError == nil { route.recovery = notice == nil ? nil : .reloadConfiguration }
        if let error = route.selectionError { route.message = error + "\n" + reason }
        let schemeName = desired?.name ?? ProductionInputAvailability.runtimeUnconfiguredSchemeName
        route.schemeName = schemeName
        Self.applied = AppliedRoute(key: key, reason: reason, notice: notice, schemeName: schemeName)
        // `reason` can carry the name the user gave a keyboard.
        Self.diagnosticLogger.info(
            """
            route=\(key, privacy: .public) fullAccess=\(self.hasFullAccess, privacy: .public) \
            detail=\(reason, privacy: .private)
            """)
        if let desired {
            // The session reuses a ready engine whose route identity already matches: no restart.
            session.switchResource(to: desired, layout: desired.preferredLayout ?? session.layout)
        } else if session.resourceSet != nil {
            // The only route-withdrawal path: the shared record was read and names no applied scheme.
            session.restoreConfiguredRoute()
        } else {
            session.start()
        }
    }

    /// Refreshes the published keyboard list (official extension lifecycle): triggered once by `viewWillAppear`;
    /// the read itself runs in `KeyboardPadSession` on the read queue with a latest-wins gate. Uses no app-only notifications.
    func refreshPublishedKeyboards() {
        guard Self.activeController === self, session != nil else { return }
        Task { @MainActor [weak self] in
            await self?.session.refreshPublishedKeyboards()
        }
    }

    func refreshLayoutRegistry() {
        guard Self.activeController === self else { return }
        route.assignIfChanged(
            \.selectedLayoutID,
            UserDefaults.standard.string(forKey: Self.selectedDefinitionKey))
        // On reappearance, keep the last registry until the new result arrives: clearing first would make the panel
        // reconcile to the builtin layout and rebuild the key area, then switch back after the read (a visible "hot
        // reload"). Only the first time (no registry yet) counts as source-unsettled: the host keeps the previously granted pinyin-row height.
        if route.layoutRegistry == nil {
            route.assignIfChanged(\.layoutReadSettled, false)
        }
        // The layout registry read (`layouts.json`) is a separate file read, put on the dedicated read queue (not
        // serialized with the engine-ownership queue). The main thread reads no disk; the result is guarded by this
        // instance's latest-wins gate and by active, and disappear/new intents invalidate it.
        let token = layoutReadGate.begin()
        Task { @MainActor [weak self] in
            let result = await KeyboardLifecycleDiagnostics.measureAsync("layoutRead") {
                do {
                    return try await KeyboardResourceReadQueue.async { () -> LayoutReadResult in
                        let location = RimePaths.layoutStoreReadLocation()
                        guard location.isShared else {
                            Self.diagnosticLogger.error(
                                "shared layout directory unavailable: \(location.url.path, privacy: .private)")
                            return .unavailable("自定义布局暂时不可用，当前使用内置布局。")
                        }
                        do {
                            let registry = try LayoutStore(directoryURL: location.url).load()
                            return .loaded(registry, location.url.path)
                        } catch {
                            Self.diagnosticLogger.error(
                                "shared layout read failed: \(error.localizedDescription, privacy: .private)")
                            return .failed("无法读取布局，当前使用内置布局。")
                        }
                    }
                } catch {
                    return .failed("无法读取布局，当前使用内置布局。")
                }
            }
            guard let self, Self.activeController === self, self.layoutReadGate.accepts(token) else { return }
            // Settled in the same main-thread turn as the registry assignment (success, unavailable and failure all count as settled).
            defer { self.route.layoutReadSettled = true }
            switch result {
            case .loaded(let registry, let path):
                self.route.assignIfChanged(\.layoutRegistry, registry)
                self.route.assignIfChanged(\.layoutNotice, nil)
                Self.diagnosticLogger.debug("shared layout loaded: \(path, privacy: .private)")
                self.route.assignIfChanged(\.layoutMessage, "自定义布局已加载。")
            case .unavailable(let message):
                self.route.assignIfChanged(\.layoutRegistry, nil)
                self.route.assignIfChanged(\.layoutNotice, "自定义布局暂时不可用，当前使用内置布局。")
                self.route.assignIfChanged(\.layoutMessage, message)
            case .failed(let message):
                self.route.assignIfChanged(\.layoutRegistry, nil)
                self.route.assignIfChanged(\.layoutNotice, "无法读取布局，当前使用内置布局。")
                self.route.assignIfChanged(\.layoutMessage, message)
            }
        }
    }

    /// Layout read result (crosses concurrency domains, Sendable values only).
    private enum LayoutReadResult: Sendable {
        case loaded(LayoutRegistry, String)
        case unavailable(String)
        case failed(String)
    }
}
