import CandidateKit
import Combine
import KeyboardCore
import LayoutKit
import OSLog
import SwiftUI
import UIKit

extension KeyboardViewController {
    private func documentIdentity() -> UUID? {
        guard let identity = RimeDocumentIdentifier(textDocumentProxy) as UUID? else {
            abandonDocumentOwnership()
            return nil
        }
        return identity
    }

    /// Forgets local state before clearing the engine: the clear republishes the
    /// composition and re-enters `onMarkedComposition`, which must find nothing owned.
    /// Never cancels host text through an unowned proxy.
    private func abandonDocumentOwnership() {
        let hadOwnership = activeDocumentID != nil || markedDocument != nil || pendingMarked != nil
        forgetLocalDocumentState()
        if hadOwnership { clearComposition() }
    }

    /// The host may invalidate `textDocumentProxy` before or during disappearance
    /// (lock screen, host suspension, process replacement), so teardown only drops
    /// local state and never touches the departing proxy. A stale engine composition
    /// is cleared when a new visible controller owns a valid host again.
    func detachFromHostWithoutUsingProxy() {
        forgetLocalDocumentState()
        proxyWriteInProgress = false
    }

    /// Touches only process-local state: never `textDocumentProxy`, never the engine.
    private func forgetLocalDocumentState() {
        activeDocumentID = nil
        markedDocument = nil
        pendingMarked = nil
        lastEchoedMarked = nil
        markedBaselineContext = nil
        markedInsertionContext = nil
        keyboardOnlyComposition = false
        cancelledMarkedEcho = nil
        expectedContext = nil
        session.reportCompositionPresentation(.idle)
        session.resetHostContext()
    }

    private func adoptDocument(_ id: UUID) {
        abandonDocumentOwnership()
        activeDocumentID = id
        expectedContext = proxyContext
    }

    /// Whether `document` is still the one this controller owns, for use after a
    /// step that may have dropped ownership (a nil identity gap clears it).
    func stillOwns(_ document: UUID) -> Bool {
        documentIdentity() == document && activeDocumentID == document
    }

    /// The document a proxy write may target, or nil. If the proxy now shows another
    /// document (the field changed before any callback arrived), the caller's captured
    /// composition/commit belongs to the old one: it is dropped and the new document is
    /// adopted for the next operation. A first adoption with nothing owned proceeds, so
    /// the first key after an identity gap is not lost.
    func writableDocument() -> UUID? {
        // Before the host document attach the proxy may still be mid-handoff;
        // the attach (cancelOrphanedMarked) reconciles anything skipped here.
        guard Self.activeController === self, !hostDocumentAttachPending,
            session.backend?.hostInputIsReady != false,
            let current = documentIdentity()
        else { return nil }
        if activeDocumentID != current {
            let hadOwner = activeDocumentID != nil
            adoptDocument(current)
            if hadOwner { return nil }
        }
        return current
    }
    /// Shared default-on preference; the external host owns marked-text appearance.
    /// `KeyboardCompositionPreferences.defaults` builds a suite store and re-registers
    /// defaults on each access; this runs on every marked write, so keep one store.
    private static let compositionDefaults = KeyboardCompositionPreferences.defaults
    private var inlineCompositionEnabled: Bool {
        SharedPreferences.object(forKey: KeyboardCompositionPreferences.enabledKey, in: Self.compositionDefaults)
            as? Bool ?? KeyboardCompositionPreferences.defaultInlineEnabled
    }

    @discardableResult
    func observeMarkedEcho() -> Bool {
        guard let current = documentIdentity(), let owner = markedDocument,
            owner == current, let pendingMarked
        else { return false }
        let before = textDocumentProxy.documentContextBeforeInput
        let after = textDocumentProxy.documentContextAfterInput
        let context = ProxyDocumentContext(before: before, after: after, selected: textDocumentProxy.selectedText)
        if lastEchoedMarked == pendingMarked, expectedContext != context { return false }
        let changed = markedBaselineContext != context || lastEchoedMarked == pendingMarked
        guard changed, pendingMarked.isEchoed(before: before, after: after, selectedText: context.selected) else {
            return false
        }
        lastEchoedMarked = pendingMarked
        expectedContext = context
        session.reportCompositionPresentation(.inline(evidence: .documentContextEcho))
        return true
    }

    /// Removing our short native mark may be acknowledged on a later callback.
    /// Accept only the exact insertion contexts captured before that mark, in the
    /// same document. A suffix match cannot authorize a document edit.
    @discardableResult
    func observeCancelledMarkedEcho() -> Bool {
        guard let echo = cancelledMarkedEcho,
            let current = documentIdentity(), current == echo.document,
            echo.context == proxyContext,
            echo.context.selected == nil
        else { return false }
        expectedContext = echo.context
        cancelledMarkedEcho = nil
        return true
    }

    func writeProxy(_ action: () -> Void) {
        proxyWriteInProgress = true
        action()
        expectedContext = proxyContext
        proxyWriteInProgress = false
        // Our own writes often arrive without text/selection callbacks, so the cached
        // "field is empty" (return key enablement) would stay at the value from before
        // e.g. a chat app cleared the field on send. Re-read now and after the host
        // has applied the edit.
        refreshHostTraits()
        scheduleHostTraitsRefresh()
    }

    func scheduleHostTraitsRefresh() {
        guard !hostTraitsRefreshScheduled else { return }
        hostTraitsRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.hostTraitsRefreshScheduled = false
            self?.refreshHostTraits()
        }
    }

    func updateMarked(_ composition: MarkedComposition?) {
        guard Self.activeController === self else { return }
        guard let composition, !composition.text.isEmpty else {
            cancelOwnedMarked()
            keyboardOnlyComposition = false
            return
        }
        _ = observeCancelledMarkedEcho()
        guard let document = writableDocument() else {
            // No adoptable document, or the field changed under this key: its
            // engine-only composition must not leak into the new document.
            clearComposition()
            return
        }
        guard inlineCompositionEnabled else {
            cancelOwnedMarked()
            session.reportCompositionPresentation(.keyboard(reason: "未开启在输入框中显示拼写"))
            return
        }
        if keyboardOnlyComposition || !composition.isWithinProxyInlineBudget {
            if !keyboardOnlyComposition { cancelOwnedMarked() }
            keyboardOnlyComposition = true
            session.reportCompositionPresentation(.keyboard(reason: "长拼写在键盘内显示"))
            return
        }
        // Every controller refresh re-sends the composition. Re-marking identical
        // text makes some hosts redraw (and re-scroll) the field on each key.
        if composition == pendingMarked, markedDocument == document,
            expectedContext == proxyContext
        {
            return
        }
        if markedDocument == nil { markedInsertionContext = proxyContext }
        cancelledMarkedEcho = nil
        markedBaselineContext = proxyContext
        pendingMarked = composition
        markedDocument = document
        writeProxy {
            textDocumentProxy.setMarkedText(composition.text, selectedRange: composition.selection)
        }
        if !observeMarkedEcho() {
            // A proxy does not expose acceptance or markedTextRange; context can exclude
            // visible marked text entirely. Missing echo is not evidence of rejection.
            session.reportCompositionPresentation(.awaitingHost)
        }
    }

    /// On commit, replaces the already-echoed composition with the result and unmarks it: two host operations
    /// with no "empty composition" frame in between (clearing the mark, unmarking, then inserting would make the field
    /// flash a state without a composition). Used only when the host has echoed the current marked text, which
    /// proves it supports marked text; other hosts still use insertText so text is never lost.
    func commitOverEchoedMarked(_ text: String, document: UUID) -> Bool {
        guard markedDocument == document,
            let pendingMarked, lastEchoedMarked == pendingMarked,
            expectedContext == proxyContext
        else { return false }
        self.pendingMarked = nil
        lastEchoedMarked = nil
        markedDocument = nil
        markedInsertionContext = nil
        cancelledMarkedEcho = nil
        keyboardOnlyComposition = false
        session.reportCompositionPresentation(.idle)
        writeProxy {
            textDocumentProxy.setMarkedText(
                text, selectedRange: NSRange(location: (text as NSString).length, length: 0))
            textDocumentProxy.unmarkText()
        }
        return true
    }

    func cancelOwnedMarked() {
        _ = observeMarkedEcho()
        let wasEchoed = pendingMarked != nil && pendingMarked == lastEchoedMarked
        let insertionContext = markedInsertionContext
        pendingMarked = nil
        lastEchoedMarked = nil
        markedInsertionContext = nil
        session.reportCompositionPresentation(.idle)
        guard let owner = markedDocument else { return }
        markedDocument = nil
        guard let current = documentIdentity(), owner == current else {
            abandonDocumentOwnership()
            return
        }
        guard expectedContext == proxyContext else { return }
        if wasEchoed, let insertionContext {
            cancelledMarkedEcho = CancelledMarkedEcho(
                document: owner,
                context: ProxyDocumentContext(
                    before: insertionContext.before, after: insertionContext.after, selected: nil))
        }
        writeProxy {
            textDocumentProxy.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
            textDocumentProxy.unmarkText()
        }
        _ = observeCancelledMarkedEcho()
    }

    /// Removes it with an empty mark at an empty caret, which only replaces a marked
    /// range: a host that already finalized the text keeps it (nothing is marked, so
    /// nothing is inserted), and a selection, which an empty mark would replace, is
    /// never touched. The document identity is not compared (iOS issues a new one
    /// when it presents the keyboard again), and many hosts leave marked text out of
    /// the proxy context, so its echo cannot be required either.
    func cancelOrphanedMarked() {
        guard Self.orphanedMarked else { return }
        guard markedDocument == nil else {
            Self.orphanedMarked = false
            return
        }
        guard writableDocument() != nil else { return }
        Self.orphanedMarked = false
        let cancel = (textDocumentProxy.selectedText ?? "").isEmpty
        KeyboardLifecycleDiagnostics.emit("orphanedMarked", ["outcome": cancel ? "cancelled" : "kept"])
        guard cancel else { return }
        writeProxy {
            textDocumentProxy.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
            textDocumentProxy.unmarkText()
        }
    }

    func checkDocumentOwnership() {
        guard !proxyWriteInProgress, !hostDocumentAttachPending, Self.activeController === self,
            let current = documentIdentity()
        else { return }
        if activeDocumentID != current {
            adoptDocument(current)
            return
        }
        // Some hosts report their marked-text context asynchronously after setMarkedText returns.
        // Accept only an observed full echo in the same document; do not discard it as an external edit.
        if observeMarkedEcho() || observeCancelledMarkedEcho() { return }
        guard expectedContext != proxyContext else { return }
        // External selection/focus move: never mutate the new target or delete host text.
        // Both a marked and a keyboard-only composition belong to the old insertion point.
        markedDocument = nil
        pendingMarked = nil
        lastEchoedMarked = nil
        markedInsertionContext = nil
        cancelledMarkedEcho = nil
        keyboardOnlyComposition = false
        session.reportCompositionPresentation(.idle)
        session.resetHostContext()
        clearComposition()
        expectedContext = proxyContext
    }

    /// The first proxy contact of an appearance. UIKit delivers the new host's
    /// controller state on an XPC thread around `viewWillAppear` and replaces the
    /// proxy's state object there; a main-thread proxy read during that handoff
    /// messaged the released object (device crashes in `documentIdentifier`). The
    /// handoff finishes with a sync hop to the main queue, so the next main turn,
    /// or `viewDidAppear` if it comes first, reads the settled state.
    func attachToHostDocument() {
        guard hostDocumentAttachPending, Self.activeController === self else { return }
        hostDocumentAttachPending = false
        checkDocumentOwnership()
        expectedContext = proxyContext
        syncInputModeSwitchKey()
        // A ready session (nothing to resume) can clean up now; otherwise the resume does.
        cancelOrphanedMarked()
        refreshHostTraits()
    }

    /// Unbinds the shared proxy/session. Only the still-active controller may call this.
    func unbindSharedProxy() {
        guard Self.activeController === self else { return }
        session?.controller?.cancelRailSelection()
        if markedDocument != nil, pendingMarked != nil { Self.orphanedMarked = true }
        // `viewWillDisappear` can run after the host invalidated its document proxy
        // (notably while locking). Never read/write that proxy from teardown.
        detachFromHostWithoutUsingProxy()
        session.onCommit = nil
        session.onDispatchCommit = nil
        session.onDeleteBackward = nil
        session.onReadDocumentContext = nil
        session.onReplaceLiteralSuffix = nil
        session.onRefreshHostTraits = nil
        session.onMoveCursor = nil
        session.onSwitchKeyboard = nil
        session.onMarkedComposition = nil
        session.onSelectionChanged = nil
        session.hostContextIdentifier = nil
        session.asyncInsertionContext = nil
        session.resetHostContext()
        // The engine session suspends below; a batch decoding on the engine queue
        // must not race it or land a composition into a hidden keyboard. Only after
        // the proxy callbacks are gone: dropping the echo republishes marked text.
        session.controller?.session.cancelPendingCodes()
        let suspendStarted = ProcessInfo.processInfo.systemUptime
        if session.setHostVisibility(false) {
            KeyboardLifecycleDiagnostics.emit(
                "engineSessionSuspended",
                [
                    "ms": String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - suspendStarted) * 1000),
                    "route": session.runningRouteKey?.diagnosticDescription ?? "-",
                ])
        }
        // The suspended engine has no composition; without this the next appearance
        // shows the old candidates (taps on them fail) until the session resumes.
        // Reads the backend's cached state only; the proxy callbacks are already gone.
        session.controller?.session.refresh()
        KeyboardFeedbackService.shared.release()
        activeDocumentID = nil
        Self.activeController = nil
    }

    func clearComposition() {
        // Keys still decoding belong to the old insertion point too: drop them before
        // the engine clears, so none can compose again afterwards.
        session.controller?.session.cancelPendingCodes()
        session.backend?.clearComposition()
        session.controller?.session.refresh()
    }

    func refreshHostTraits() {
        guard Self.activeController === self, let controller = session?.controller else { return }
        updateHostTraits(on: controller)
    }

    func updateHostTraits(on controller: KeyboardController) {
        guard Self.activeController === self, !hostDocumentAttachPending else { return }
        let ownsDocument = writableDocument() != nil
        let proxy = textDocumentProxy
        controller.updateHostTraits(
            keyboardType: proxy.keyboardType ?? .default,
            returnKeyType: proxy.returnKeyType ?? .default,
            keyboardAppearance: proxy.keyboardAppearance ?? .default,
            autocapitalizationType: proxy.autocapitalizationType,
            enablesReturnKeyAutomatically: proxy.enablesReturnKeyAutomatically,
            beforeCursor: ownsDocument ? proxy.documentContextBeforeInput : nil,
            documentIsEmpty: ownsDocument ? !proxy.hasText : nil)
    }
}
