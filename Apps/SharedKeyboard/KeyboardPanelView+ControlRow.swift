import CandidateKit
import Combine
import KeyboardCore
import LayoutKit
import SwiftUI

extension KeyboardPanelView {
    // MARK: Control row (layout menu / globe / page switch / CN-EN toggle / space / delete / return)

    var currentKeyboardTitle: String {
        UserKeyboardRoster.currentTitle(
            schemaID: controller.selectedSchemaID,
            layout: controller.layout,
            in: controller.userKeyboardChoices)
            ?? (isBundledDefinition
                ? UserTerminology.layoutName(controller.layout)
                : activeDefinition?.name ?? UserTerminology.layoutName(controller.layout))
    }

    var controlRow: some View { controlRow(columns: nil) }

    /// The bundled phone shell passes its columns so the bottom keys line up
    /// under the rail and digit columns above them.
    func phoneControlRow(_ metrics: PhoneKeypadMetrics, splitOverride: ActiveLayoutSplit? = nil) -> some View {
        controlRow(
            columns: usesFixedEditingRail
                ? .init(rail: metrics.railWidth, digit: metrics.digitWidth) : nil, splitOverride: splitOverride)
    }

    /// The bundled 9-key, and every layout's categorised symbol page except an
    /// imported phone keypad's (which keeps its declared rails), draw the fixed
    /// ⌫ / 重输 / ⏎ column and the phone bottom row (first key under the rail, wide space).
    var usesFixedEditingRail: Bool {
        KeyboardPanelRules.usesFixedEditingRail(
            showsCategorySymbolPage: showsCategorySymbolPage, hasAuthoredPage: pageDefinition != nil,
            mainIsPhoneKeypad: usesPhoneDefinition, mainIsBuiltinPhonePad: isBuiltinPhonePad)
    }

    var showsCategorySymbolPage: Bool {
        KeyboardPanelRules.showsCategorySymbolPage(
            page: page, authoredPage: pageDefinition, mainIsPhoneKeypad: usesPhoneDefinition,
            prefersCategoryPage: prefersCategorySymbolPage)
    }

    func controlRow(columns: KeyboardControlPolicy.PhoneColumns?, splitOverride: ActiveLayoutSplit? = nil)
        -> some View
    {
        ControlRow(
            policy: controlPolicy,
            returnTitle: controller.returnKeyTitle,
            returnEnabled: controller.isReturnKeyEnabled,
            layoutName: controller.isEnglishMode ? nil : currentKeyboardTitle,
            layoutHintName: layoutHintName,
            layoutHintToken: layoutHintToken,
            modeKey: modeSwitchKey,
            systemKeyboardSwitch: systemKeyboardSwitch,
            moveCursor: cursorMovement,
            onPage: {
                emitKeyFeedback()
                page = $0
                showsAllCandidates = false
            },
            onKey: { handleKey($0) },
            phoneColumns: columns,
            split: splitOverride ?? activeSplit,
            splitRowIndex: pageDefinition?.rows.count ?? definitionMainRows.count,
            symbolPageLocked: symbolPageLocked,
            onToggleSymbolLock: {
                emitKeyFeedback()
                symbolPageLocked.toggle()
            }
        )
    }

    /// Consumes only a token from a real successful switch; reselecting the same item, page switches and view rebuilds produce no new token.
    func consumeLayoutChange() {
        guard let change = controller.successfulChange, change.token != layoutHintToken else { return }
        layoutHintToken = change.token
        layoutHintName = currentKeyboardTitle
        let token = change.token
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if layoutHintToken == token { layoutHintName = nil }
        }
    }

    /// **"More tools" entry** (separate from the candidate bar): opens only the utilities panel (symbol library, quick phrases,
    /// keyboard options/inline options). It is the last item of the "ABC/中文" **long-press** menu rather than a large
    /// permanent button in the candidate bar, which serves input only (candidates / composition / real status).
    ///
    /// It stays separate from the short press of "ABC/中文" (CN/EN toggle only); it offers no input-method or 26/14/9 layout choice,
    /// and every layout (including author-defined/imported keyboards) reaches it through the same language-key long press.
    var moreToolsCapID: String { "keyboard-more-tools" }

    var modeSwitchKey: some View {
        let action = controlPolicy.languageAction(for: nil)
        return AlternateCharacterKey(
            cap: KeyCap(
                id: "input-mode", title: controlPolicy.languageTitle(for: nil),
                subtitle: nil, action: .cycleLayout),
            alternates: userKeyboardAlternates,
            layoutPicker: true
        ) { cap in
            if cap.id == "input-mode" {
                // Short press follows the page: letters toggle the real input language; 123 and
                // the row-shaped #+= page only flip the panel symbol branch and stay put; the
                // categorised grid returns to the main letter keyboard. None of these writes the
                // engine input mode except the existing real-language toggle.
                switch action {
                case .toggleLanguage:
                    keyFeedbackAfterEffect { controller.toggleInputMode() }
                case .toggleSymbols:
                    emitKeyFeedback()
                    togglePanelSymbolMarks()
                case .returnToLetters:
                    emitKeyFeedback()
                    page = .letters
                    showsAllCandidates = false
                }
            } else {
                handleLanguageMenuCap(cap)
            }
        }
        .accessibilityLabel(controlPolicy.languageAccessibilityLabel(for: nil))
    }

    /// The language key's long-press menu (user keyboards, then More tools). It backs both the
    /// built-in control row and an authored languageSwitch key that declares no long press.
    func handleLanguageMenuCap(_ cap: KeyCap) {
        if cap.id == moreToolsCapID {
            // "More tools...": opens the utilities panel, separate from the candidate bar. The last item of the long-press menu,
            // not a permanent candidate-bar button.
            emitKeyFeedback()
            showsUtilitiesMenu = true
            return
        }
        guard
            let keyboard = controller.userKeyboardChoices.first(where: {
                Self.userKeyboardCapID($0) == cap.id
            })
        else { return }
        // The long-press switcher only switches among published user keyboards; selecting one switches input method + layout jointly.
        var changed = false
        selectionFeedbackAfterEffect { changed = controller.selectUserKeyboard(keyboard) }
        if changed {
            onReadingRowReport?(readingRowReport)
            page = .letters
            showsAllCandidates = false
        }
    }

    /// The long-press list = those **published** keyboards whose resources are currently runnable (in publish order), with a
    /// "More tools" item appended; no 26/14/9 layouts and no input-method choice. With an empty list the
    /// "More tools" item is still offered so the tools panel stays reachable (no tappable dead item is built).
    var userKeyboardAlternates: [KeyCap] {
        var caps = controller.userKeyboardChoices.map { keyboard in
            KeyCap(
                id: Self.userKeyboardCapID(keyboard), title: keyboard.title,
                subtitle: isCurrent(keyboard) ? UserTerminology.userKeyboardCurrent : nil,
                action: .cycleLayout)
        }
        caps.append(
            KeyCap(
                id: moreToolsCapID,
                title: UserTerminology.keyboardMoreTools,
                subtitle: nil, action: .cycleLayout))
        return caps
    }

    static func userKeyboardCapID(_ keyboard: UserKeyboard) -> String {
        "user-keyboard:\(keyboard.id)"
    }

    func isCurrent(_ keyboard: UserKeyboard) -> Bool {
        keyboard.isCurrent(schemaID: controller.selectedSchemaID, layout: controller.layout)
    }

    var controlPolicy: KeyboardControlPolicy {
        let showsCategorySymbolPage = showsCategorySymbolPage
        return KeyboardPanelRules.controlPolicy(
            page: page, isEnglishMode: controller.isEnglishMode,
            hasGlobe: systemKeyboardSwitch != nil,
            usesASCIIPunctuation: effectiveUsesASCIIPunctuation,
            phoneShellVisible: KeyboardPanelRules.phoneShellVisible(
                usesStandardT9: usesStandardT9, page: page, hasAuthoredPage: pageDefinition != nil,
                mainIsPhoneKeypad: usesPhoneDefinition, showsCategorySymbolPage: showsCategorySymbolPage),
            usesFixedEditingRail: usesFixedEditingRail,
            declaredTrailingReturn: t9AuxiliaryKeys(.trailing).contains { $0.action.type == .enter },
            showsCategorySymbolPage: showsCategorySymbolPage,
            numericPageReachesSymbols: page != .letters || numericPageReachesSymbols)
    }
}
