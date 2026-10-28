import CandidateKit
import KeyboardCore
import LayoutKit

/// Key-area decisions the live panel and the host previews derive from the same plain values, so a
/// preview cannot drift from the keyboard it shows. Lazy arguments keep the panel's short-circuits:
/// a typing page never resolves page facts it does not read.
enum KeyboardPanelRules {
    /// Main activation is settled on the width before the optional tools rail. Other pages keep its
    /// spacing without its row cuts unless they carry their own split.
    static func activeSplit(
        main: LayoutSplitConfiguration?, mainWidth: Double, showsMainLetters: Bool,
        pageSplit: @autoclosure () -> LayoutSplitConfiguration?, contentWidth: Double
    ) -> ActiveLayoutSplit? {
        let resolved = main?.resolved(forWidth: mainWidth)
        if showsMainLetters { return resolved }
        return ActiveLayoutSplit.resolving(nested: pageSplit(), parent: resolved, width: contentWidth)
    }

    /// The width cap a physical layout uses on a wide surface. A main split that really splits at the
    /// pre-rail width keeps the full surface instead of silently cancelling the opt-in.
    static func wideMaximumContentWidth(
        rawWidth: Double, mainSplit: @autoclosure () -> LayoutSplitConfiguration?, layout: KeyboardLayoutKind?
    ) -> Double? {
        guard rawWidth > KeyboardSurfaceWidth.phoneMaximum else { return nil }
        if let split = mainSplit(), split.isActive(width: rawWidth - 8) { return nil }
        switch layout {
        case .phone9: return KeyboardWideContentPolicy.phoneNineMaximumContentWidth
        case .merged14, .merged18: return KeyboardWideContentPolicy.mergedMaximumContentWidth
        case .qwerty26, nil: return nil
        }
    }

    /// #+= opens the categorised grid on a phone keypad (its 123 page is a digit pad, with no rows
    /// for a second page to share) or when the user chose it; otherwise it is the row-shaped page
    /// that shares the 123 page's geometry.
    static func showsCategorySymbolPage(
        page: KeyboardPage, authoredPage: @autoclosure () -> KeyboardPageDefinition?,
        mainIsPhoneKeypad: @autoclosure () -> Bool, prefersCategoryPage: Bool
    ) -> Bool {
        guard page == .symbols else { return false }
        if let authored = authoredPage() { return authored.symbolPresentation == .categorized }
        return mainIsPhoneKeypad() || prefersCategoryPage
    }

    /// The bundled 9-key, and every categorised symbol page except an imported phone keypad's
    /// (which keeps its declared rails), draw the fixed ⌫ / 重输 / ⏎ column and the phone bottom row.
    static func usesFixedEditingRail(
        showsCategorySymbolPage: Bool, hasAuthoredPage: @autoclosure () -> Bool,
        mainIsPhoneKeypad: @autoclosure () -> Bool, mainIsBuiltinPhonePad: @autoclosure () -> Bool
    ) -> Bool {
        showsCategorySymbolPage
            ? (!mainIsPhoneKeypad() || mainIsBuiltinPhonePad())
            : (mainIsBuiltinPhonePad() && !hasAuthoredPage())
    }

    /// The key-area shell the panel and the main-layout preview draw. Order matters: an authored
    /// chrome page owns its whole shell, a phone keypad's 123 page and the categorised #+= grid
    /// come before the letter shells, and the phone pad wins over the bundled 26-key shell.
    static func keyAreaRenderer(
        page: KeyboardPage, isEnglishMode: Bool, authoredPage: KeyboardPageDefinition?,
        facts: DefinitionResolutionMemo.Facts, showsCategorySymbolPage: @autoclosure () -> Bool
    ) -> KeyAreaRenderer {
        if authoredPage?.chrome != nil { return .authoredChromePage }
        if authoredPage == nil && page == .numeric && facts.isPhone { return .phoneDigitPad }
        if showsCategorySymbolPage() { return .categorySymbolPage }
        if authoredPage != nil { return .authoredRows }
        guard page == .letters else { return .symbolRows }
        if !isEnglishMode && facts.isPhone { return .phonePad }
        if isEnglishMode || facts.isBundledQwertyMainShell { return .standardQwerty }
        return facts.isBundledMergedPad ? .mergedPad : .configuredRows
    }

    /// The phone treatment belongs to the visible shell: an English QWERTY letter page uses the
    /// shared symbol entry and bottom Return even when the Chinese definition is a phone pad.
    static func phoneShellVisible(
        usesStandardT9: Bool, page: KeyboardPage, hasAuthoredPage: @autoclosure () -> Bool,
        mainIsPhoneKeypad: @autoclosure () -> Bool, showsCategorySymbolPage: @autoclosure () -> Bool
    ) -> Bool {
        usesStandardT9 || (!hasAuthoredPage() && mainIsPhoneKeypad() && page != .letters)
            || showsCategorySymbolPage()
    }

    /// Imported phone letter pages keep their declared bottom controls; Return stays off the bottom
    /// row while a visible phone rail already carries it.
    static func controlPolicy(
        page: KeyboardPage, isEnglishMode: Bool, hasGlobe: Bool, usesASCIIPunctuation: Bool,
        phoneShellVisible: Bool, usesFixedEditingRail: Bool,
        declaredTrailingReturn: @autoclosure () -> Bool, showsCategorySymbolPage: Bool,
        numericPageReachesSymbols: Bool = true
    ) -> KeyboardControlPolicy {
        let trailingHasReturn = !usesFixedEditingRail && phoneShellVisible && declaredTrailingReturn()
        return KeyboardControlPolicy(
            page: page, isEnglishMode: isEnglishMode, hasGlobe: hasGlobe,
            isPhoneLayout: phoneShellVisible, usesASCIIPunctuation: usesASCIIPunctuation,
            includesBottomEnter: !phoneShellVisible || (!usesFixedEditingRail && !trailingHasReturn),
            usesCategorySymbolPage: showsCategorySymbolPage, numericPageReachesSymbols: numericPageReachesSymbols)
    }

    /// The known bundled main-shell preset (26 or merged 14/18) whose main rows still provide the
    /// native geometry. Footer/aux sheets are not part of this identity.
    static func knownMainShellPreset(_ facts: DefinitionResolutionMemo.Facts) -> LayoutDefinition? {
        if facts.isBundledQwertyMainShell { return BuiltinLayouts.qwerty26 }
        if facts.isBundledMergedPad {
            switch facts.active?.input.builtinLayout {
            case .some(.merged14): return BuiltinLayouts.merged14
            case .some(.merged18): return BuiltinLayouts.merged18
            default: return nil
            }
        }
        return nil
    }

    /// The preset key at the same declared address, for the per-key face/long-press comparison.
    /// The merged shell addresses its keys by action (the layout data has no stable row address),
    /// so those ids are resolved by the unchanged main-row action.
    static func mainShellPresetKey(in preset: LayoutDefinition, id: String, key: LayoutKey) -> LayoutKey? {
        // Runs per rendered key: scan in place instead of building arrays.
        if id.hasPrefix("merged-") {
            for row in preset.rows.prefix(PhoneKeypadMetrics.mainRowCount) {
                if let match = row.keys.first(where: { $0.action == key.action }) { return match }
            }
            return nil
        }
        guard id.hasPrefix("row-") else { return nil }
        let address = id.dropFirst(4)
        guard let dash = address.firstIndex(of: "-"),
            let row = Int(address[..<dash]), let column = Int(address[address.index(after: dash)...]),
            preset.rows.indices.contains(row), preset.rows[row].keys.indices.contains(column)
        else { return nil }
        return preset.rows[row].keys[column]
    }

    /// The bundled merged pad's face policy (lowercase caps, suppressed secondary labels) only
    /// applies while the key face is still the preset. An authored label/secondary/title is shown
    /// verbatim; the letter group and swipe still come from that authored label.
    static func keyFaceUnchanged(_ key: LayoutKey, preset: LayoutKey) -> Bool {
        key.label == preset.label
            && key.secondaryLabel == preset.secondaryLabel
            && key.titleMode == preset.titleMode
            && key.action == preset.action
            && key.width == preset.width
    }

    /// A literal key of a page without authored chrome. Explicit bilingual pairs resolve first: an
    /// English page may pair arbitrary text, so the single-letter code heuristic must not swallow
    /// it. Fixed literals keep their value; a long-press list shows its first entry in the corner.
    static func pageCap(
        _ key: LayoutKey, id: String, kind: KeyboardPageKind, alternate: Bool, usesASCIIPunctuation: Bool,
        shiftActive: @autoclosure () -> Bool
    ) -> KeyCap {
        if let literal = key.resolvedLiteralValue(usesASCIIPunctuation: usesASCIIPunctuation) {
            let paired = key.action.isPairedLiteral
            let letter =
                !paired && kind == .english && literal.count == 1
                && literal.utf8.count == 1 && literal.first?.isLetter == true
            let action: KeyAction =
                letter
                ? (alternate ? .letterVariant(literal) : .code(literal.lowercased()))
                : .literal(literal)
            let title = key.literalFaceTitle(usesASCIIPunctuation: usesASCIIPunctuation)
            return KeyCap(
                id: id,
                title: letter && shiftActive() ? title.uppercased() : title,
                subtitle: key.secondaryLabel ?? key.longPress?.first?.label, action: action)
        }
        let value = key.action.value ?? ""
        let letter = kind == .english && value.count == 1 && value.utf8.count == 1 && value.first?.isLetter == true
        let action: KeyAction =
            letter
            ? (alternate ? .letterVariant(value) : .code(value.lowercased()))
            : key.action.keyAction(usesASCIIPunctuation: usesASCIIPunctuation)
        return KeyCap(
            id: id, title: letter && shiftActive() ? key.label.uppercased() : key.label,
            subtitle: key.secondaryLabel ?? key.longPress?.first?.label, action: action)
    }
}

/// Which key-area shell draws the current page; resolved once by `KeyboardPanelRules.keyAreaRenderer`.
enum KeyAreaRenderer: Equatable {
    /// An authored page whose rows, rails and footer all come from data.
    case authoredChromePage
    /// The digit pad a phone keypad uses for its 123 page.
    case phoneDigitPad
    /// The categorised #+= grid.
    case categorySymbolPage
    /// An authored page without chrome, drawn in the ordinary rows area.
    case authoredRows
    /// The phone-keypad letter shell (bundled T9 and imported definitions of the same structure).
    case phonePad
    case standardQwerty
    case mergedPad
    case configuredRows
    /// The row-shaped 123 / #+= pages.
    case symbolRows
}

extension LayoutAction {
    /// The engine action a layout action maps to. Page-level UI actions have no engine face; only
    /// authored chrome keys dispatch them, so they map onto the control tone (`.cycleLayout`).
    /// The symbol branch is only read for literals.
    func keyAction(usesASCIIPunctuation: @autoclosure () -> Bool) -> KeyAction {
        switch type {
        case .code: return .code(value ?? "")
        case .literal: return .literal(literalValue(usesASCIIPunctuation: usesASCIIPunctuation()) ?? "")
        case .space: return .space
        case .backspace: return .backspace
        case .enter: return .enter
        case .globe: return .switchKeyboard
        case .modeSwitch: return .cycleLayout
        case .shift, .pageSwitch, .languageSwitch, .symbolLock, .clearInput: return .cycleLayout
        }
    }
}
