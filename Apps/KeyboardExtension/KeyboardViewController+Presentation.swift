import CandidateKit
import Combine
import KeyboardCore
import LayoutKit
import OSLog
import SwiftUI
import UIKit

extension KeyboardViewController {
    func syncSystemColorScheme(animated: Bool) {
        if let active = Self.activeController, active !== self { return }
        // The actual UIInputView owns the keyboard surface. Use its trait
        // before its window: the two can briefly disagree during a host field
        // switch. The controller and window are fallbacks while attaching.
        let styles = [
            inputView?.traitCollection.userInterfaceStyle,
            viewIfLoaded?.window?.traitCollection.userInterfaceStyle,
            traitCollection.userInterfaceStyle,
        ]
        guard let style = styles.compactMap({ $0 }).first(where: { $0 != .unspecified }) else { return }
        let scheme: ColorScheme
        switch style {
        case .dark: scheme = .dark
        case .light: scheme = .light
        default: return
        }
        if !route.hasResolvedSystemColorScheme { route.hasResolvedSystemColorScheme = true }
        guard route.systemColorScheme != scheme else { return }
        KeyboardLifecycleDiagnostics.emit(
            "keyboardColorScheme",
            [
                "inputStyle": "\(inputView?.traitCollection.userInterfaceStyle.rawValue ?? -1)",
                "windowStyle": "\(viewIfLoaded?.window?.traitCollection.userInterfaceStyle.rawValue ?? -1)",
                "controllerStyle": "\(traitCollection.userInterfaceStyle.rawValue)",
                "resolvedDark": scheme == .dark ? "1" : "0",
            ])
        if animated {
            withAnimation(.easeInOut(duration: 0.22)) { route.systemColorScheme = scheme }
        } else {
            route.systemColorScheme = scheme
        }
    }

    func phaseLabel(_ phase: KeyboardPadSession.Phase?) -> String {
        switch phase {
        case .starting?: return "starting"
        case .ready?: return "ready"
        case .failed?: return "failed"
        case nil: return "unbound"
        }
    }

    /// Read-only structured diagnostics on a real transition to `.ready`: whether this appearance was a warm
    /// resume, an in-process re-boot or a true cold start, plus time since process/appearance start and physical memory.
    ///
    /// Records only phase, duration and numbers (`phys_footprint`), never input, candidates, schema text or
    /// host document content, and changes no engine/lifecycle state.
    func noteEnginePhase(_ phase: KeyboardPadSession.Phase) {
        let label = phaseLabel(phase)
        #if DEBUG
            DebugProbe.writeSnapshot(
                role: "keyboardExtension",
                [
                    "phase": label,
                    "route": session?.runningRouteKey?.diagnosticDescription ?? "-",
                ], force: true)
        #endif
        if let previous = lastObservedPhaseLabel, previous != label {
            KeyboardLifecycleDiagnostics.emit(
                "enginePhaseChanged",
                [
                    "from": previous, "to": label,
                    "session": KeyboardLifecycleDiagnostics.identity(session),
                    "controller": KeyboardLifecycleDiagnostics.identity(session?.controller),
                    "route": session?.runningRouteKey?.diagnosticDescription ?? "-",
                ])
        }
        lastObservedPhaseLabel = label
        if label == "starting", appearanceBootClassification != nil {
            restartedDuringAppearance = true
        }
        guard case .ready = phase else { return }
        // Combine may replay an already-ready shared session in viewDidLoad,
        // before viewWillAppear establishes an appearance classification. Do
        // not call that a cold boot, but do keep its PID/token/route/footprint
        // evidence: otherwise the only ready observation can disappear.
        guard let entryKind = appearanceBootClassification else {
            Self.processHasEverBeenReady = true
            KeyboardLifecycleDiagnostics.emit(
                "engineReadySnapshot",
                [
                    "controller": KeyboardLifecycleDiagnostics.identity(self),
                    "boot": "unclassified",
                    "sinceProcessStartSec": String(format: "%.3f", KeyboardLifecycleDiagnostics.monotonic),
                    "footprintBytes": String(KeyboardLifecycleDiagnostics.footprintBytes),
                    "prebuilt": session?.resourceSet?.prebuiltDirectory != nil ? "1" : "0",
                    "route": session?.runningRouteKey?.diagnosticDescription ?? "-",
                ])
            return
        }
        let kind: KeyboardBootClassification =
            restartedDuringAppearance && entryKind == .warmReuse
            ? .coldRebootInProcess : entryKind
        restartedDuringAppearance = false
        Self.processHasEverBeenReady = true
        let sinceProcessStart = KeyboardLifecycleDiagnostics.monotonic
        let sinceAppearance = appearanceEntryMonotonic.map { max(0, sinceProcessStart - $0) } ?? 0
        KeyboardLifecycleDiagnostics.emit(
            "engineReady",
            [
                "controller": KeyboardLifecycleDiagnostics.identity(self),
                "boot": kind.rawValue,
                "cold": kind.isCold ? "1" : "0",
                "sinceProcessStartSec": String(format: "%.3f", sinceProcessStart),
                "sinceAppearanceSec": String(format: "%.3f", sinceAppearance),
                "footprintBytes": String(KeyboardLifecycleDiagnostics.footprintBytes),
                "prebuilt": session?.resourceSet?.prebuiltDirectory != nil ? "1" : "0",
                "route": session?.runningRouteKey?.diagnosticDescription ?? "-",
            ])
    }

    /// A new presentation is the only time iOS measures a new height: budget it for the
    /// definition selected now (a layout switched during the last presentation was
    /// only re-fitted inside that one's shell). Kept until the keyboard is dismissed.
    func endPresentationGeometry() {
        guard let input = viewIfLoaded as? KeyboardPanelInputView else { return }
        input.endPresentation()
        guard Self.activeController === self else { return }
        // UIKit can measure the reused input view before the next viewWillAppear.
        // Prepare that budget now so it cannot cache the outgoing layout's height.
        let budget = KeyboardInitialPresentation.load().presentationBudget(
            compact: traitCollection.verticalSizeClass == .compact)
        let height = CGFloat(budget.shellHeight)
        input.setPanelHeight(height)
        preferredContentSize.height = height
    }

    func adoptPresentationShell() {
        let budget = KeyboardInitialPresentation.load().presentationBudget(
            compact: traitCollection.verticalSizeClass == .compact)
        applyPresentationBudget(budget)
    }

    private func applyPresentationBudget(_ budget: KeyboardPanelPresentationBudget) {
        guard let input = view as? KeyboardPanelInputView else { return }
        let height = CGFloat(budget.shellHeight)
        input.beginPresentation(height: height)
        hostingHeightConstraint?.constant = height
        preferredContentSize.height = height
        presentation.presentedHeight = nil
        presentation.budget = budget
        logPanelGeometry("budget")
    }

    func syncPresentationSizeClass() {
        guard Self.activeController === self,
            let input = viewIfLoaded as? KeyboardPanelInputView,
            input.acceptsPresentation(input.presentationRevision)
        else { return }
        let compact = traitCollection.verticalSizeClass == .compact
        guard presentation.budget.compact != compact else { return }
        applyPresentationBudget(presentation.budget.withCompact(compact))
    }

    /// Deferred receipts may only change the controller and presentation that observed them.
    func syncPresentedHeight() {
        guard Self.activeController === self, let input = view as? KeyboardPanelInputView else { return }
        let revision = input.presentationRevision
        guard input.acceptsPresentation(revision) else { return }
        let presented = input.retainedPresentedHeight
        guard presentation.presentedHeight != presented else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, Self.activeController === self,
                let input = self.view as? KeyboardPanelInputView,
                input.acceptsPresentation(revision),
                input.retainedPresentedHeight == presented,
                self.presentation.presentedHeight != presented
            else { return }
            self.presentation.presentedHeight = presented
            self.hostingHeightConstraint?.constant = presented ?? input.panelHeight
            self.view.setNeedsLayout()
            self.logPanelGeometry("presented")
        }
    }

    /// Bottom edge = the root's real bottom edge, whatever height UIKit gave it.
    /// While the system keeps presenting an earlier budget, the root's Auto Layout
    /// engine still resolves `view.bottomAnchor` from the requested budget's
    /// Auto Layout geometry, so the constraint-placed hosting view can land `budget - bounds`
    /// off the real bottom (top band clipped, empty band under the keys). Correct
    /// the frame after Auto Layout ran; constraints stay for the system measure.
    func placeHostingView() {
        guard let hosted = hostingController?.view,
            let height = hostingHeightConstraint?.constant
        else { return }
        let bounds = view.bounds
        let frame = CGRect(
            x: bounds.minX, y: bounds.maxY - height,
            width: bounds.width, height: height)
        if hosted.frame != frame { hosted.frame = frame }
    }

    /// Geometry only: no input, candidate text, schema or document contents. Native
    /// timestamps let the cold-entry review distinguish live layout from a cached
    /// system snapshot. No timers, layout forcing, data writes or UI delay.
    func logPanelGeometry(_ event: String, deduplicate: Bool = false) {
        let geometryEnabled = KeyboardGeometryDiagnostics.isEnabled
        let lifecycleEnabled = lifecycleGeometryEnabled
        guard geometryEnabled || lifecycleEnabled, isViewLoaded else { return }
        let phase: String
        switch session?.phase {
        case .starting?: phase = "starting"
        case .ready?: phase = "ready"
        case .failed?: phase = "failed"
        case nil: phase = "unbound"
        }
        let windowRect = view.convert(view.bounds, to: view.window)
        let hostingRect =
            hostingController?.view.convert(hostingController?.view.bounds ?? .zero, to: view.window) ?? .zero
        let input = inputView as? KeyboardPanelInputView
        let details =
            "phase=\(phase) budget=\(input?.panelHeight ?? -1) constraint=\(panelHeightConstraint?.constant ?? -1) priority=\(panelHeightConstraint?.priority.rawValue ?? -1) root=\(view.bounds) windowRect=\(windowRect) windowBounds=\(view.window?.bounds ?? .zero) hosting=\(hostingController?.view.bounds ?? .zero) hostingInWindow=\(hostingRect) safe=\(view.safeAreaInsets) vertical=\(traitCollection.verticalSizeClass.rawValue) selfSizing=\(input?.allowsSelfSizing ?? false)"
        if deduplicate, details == lastLayoutGeometry { return }
        lastLayoutGeometry = details
        if geometryEnabled { KeyboardGeometryDiagnostics.emit("\(event) \(details)") }
        if lifecycleEnabled {
            func points(_ value: CGFloat) -> String { String(format: "%.1f", Double(value)) }
            KeyboardLifecycleDiagnostics.emit(
                "geometry",
                [
                    "stage": event,
                    "controller": KeyboardLifecycleDiagnostics.identity(self),
                    "presentation": String(input?.presentationRevision ?? 0),
                    "retainedH": points(input?.retainedPresentedHeight ?? -1),
                    "phase": phase,
                    "layout": session?.layout.rawValue ?? "unknown",
                    "budget": points(input?.panelHeight ?? -1),
                    "constraint": points(panelHeightConstraint?.constant ?? -1),
                    "rootH": points(view.bounds.height),
                    "windowH": points(windowRect.height),
                    "windowBoundsH": points(view.window?.bounds.height ?? -1),
                    "rootYInWindow": points(windowRect.minY),
                    "hostingYInWindow": points(hostingRect.minY),
                    "hostingH": points(hostingController?.view.bounds.height ?? -1),
                    "windowAttached": view.window == nil ? "0" : "1",
                    "vertical": "\(traitCollection.verticalSizeClass.rawValue)",
                ])
        }
    }
}
