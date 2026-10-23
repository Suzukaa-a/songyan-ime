import CandidateKit
import Combine
import Foundation
import KeyboardCore
import LayoutKit
import OSLog
import UIKit

extension KeyboardController {
    /// `beforeCursor == nil` means unavailable, never an empty field. A proxy
    /// cursor prefix cannot prove whole-document emptiness; only a host with
    /// independent full-document knowledge may supply `documentIsEmpty`.
    public func updateHostTraits(
        keyboardType: UIKeyboardType, returnKeyType: UIReturnKeyType,
        keyboardAppearance: UIKeyboardAppearance,
        autocapitalizationType: UITextAutocapitalizationType? = nil,
        enablesReturnKeyAutomatically: Bool? = nil,
        beforeCursor: String? = nil,
        documentIsEmpty: Bool? = nil
    ) {
        let kindChanged = self.keyboardType != keyboardType
        let capitalization = autocapitalizationType.map(HostKeyboardTypePolicy.AutoCapitalization.init)
        let contextChanged = hostContextBeforeInput != beforeCursor
        let capitalizationChanged = hostCapitalization != capitalization
        let returnEnabledChanged =
            self.enablesReturnKeyAutomatically != enablesReturnKeyAutomatically
            || hostDocumentIsEmpty != documentIsEmpty
        var changed = false
        if kindChanged {
            self.keyboardType = keyboardType
            changed = true
        }
        if self.returnKeyType != returnKeyType {
            self.returnKeyType = returnKeyType
            changed = true
        }
        if self.keyboardAppearance != keyboardAppearance {
            self.keyboardAppearance = keyboardAppearance
            changed = true
        }
        hostCapitalization = capitalization
        hostContextBeforeInput = beforeCursor
        self.enablesReturnKeyAutomatically = enablesReturnKeyAutomatically
        hostDocumentIsEmpty = documentIsEmpty
        if kindChanged { reconcileHostInput() }
        if kindChanged || capitalizationChanged || contextChanged { reconcileAutomaticShift() }
        // The return key reads `isReturnKeyEnabled` while rendering; repaint the panel
        // itself, not only the host's appearance, when that input changes.
        if returnEnabledChanged { objectWillChange.send() }
        if changed || returnEnabledChanged { hostTraitsChanged.send() }
    }

    private func reconcileHostInput() {
        switch HostKeyboardTypePolicy.preferredInput(HostKeyboardTypeKind(keyboardType)) {
        case .english:
            if hostRestoredMode == nil && inputMode != .english {
                setInputMode(.english)
                if inputMode == .english { hostRestoredMode = .chinese }
            }
        case .numeric, .unchanged:
            if let restored = hostRestoredMode {
                setInputMode(restored)
                if inputMode == restored { hostRestoredMode = nil }
            }
        }
    }

    func reconcileAutomaticShift() {
        // An empty document's before-input is nil; when the host confirms it is empty (`hasText == false`)
        // treat it as "", otherwise the first letter in an empty field would never auto-capitalize.
        // Unknown stays nil (no sentence-start inference).
        let context = hostContextBeforeInput ?? (hostDocumentIsEmpty == true ? "" : nil)
        let wanted =
            hostCapitalization.map {
                HostKeyboardTypePolicy.shouldCapitalize(
                    $0, beforeCursor: context,
                    kind: HostKeyboardTypeKind(keyboardType))
            } ?? false
        if automaticShiftArmed && (!wanted || shiftState == .off) {
            if shiftState == .once { session.setAutomaticShift(false) }
            automaticShiftArmed = false
        }
        if wanted && shiftState == .off && isEnglishMode {
            session.setAutomaticShift(true)
            automaticShiftArmed = session.shiftState == .once
        }
    }

    public var isReturnKeyEnabled: Bool {
        let isSearch = [.search, .google, .yahoo].contains(returnKeyType)
        return snapshot.isComposing
            || HostKeyboardTypePolicy.returnEnabled(
                isSearch: isSearch, enablesAutomatically: enablesReturnKeyAutomatically,
                documentIsEmpty: hostDocumentIsEmpty)
    }

    public var hostPreferredInput: HostKeyboardTypePolicy.PreferredInput {
        HostKeyboardTypePolicy.preferredInput(HostKeyboardTypeKind(keyboardType))
    }

    public var usesASCIIPunctuation: Bool {
        isEnglishMode || snapshot.isAsciiPunct
            || HostKeyboardTypePolicy.requiresASCIIPunctuation(HostKeyboardTypeKind(keyboardType))
    }

    public var returnKeyTitle: String {
        if snapshot.isComposing { return "确认" }
        switch returnKeyType {
        case .go: return "前往"
        case .google, .yahoo, .search: return "搜索"
        case .join: return "加入"
        case .next: return "下一项"
        case .route: return "路线"
        case .send: return "发送"
        case .done: return "完成"
        case .emergencyCall: return "紧急呼叫"
        case .continue: return "继续"
        default: return "换行"
        }
    }
}
