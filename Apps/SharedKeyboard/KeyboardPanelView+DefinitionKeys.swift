import CandidateKit
import Combine
import KeyboardCore
import LayoutKit
import SwiftUI

extension KeyboardPanelView {
    /// Keys keep the definition's codes; the Chinese merged page has no case, so the Shift slot becomes word-split.
    var mergedKeypad: some View {
        KeyboardMergedPad(
            rows: definitionMainRows, split: activeSplit,
            key: { key, index, keyIndex in
                definitionKey(key, id: "merged-\(key.action.value ?? "\(index)-\(keyIndex)")")
            },
            separator: {
                KeyboardMergedSeparatorKey(isComposing: controller.snapshot.isComposing) {
                    handleDefinitionAction(.code("'"))
                }
            },
            delete: { RepeatingDeleteKey { isRepeating in handleKey(.backspace, emitFeedback: !isRepeating) } })
    }

    func definitionInset(_ row: LayoutRow, index: Int) -> CGFloat {
        // The familiar stagger belongs to the standard 26-key shell, not to the strict content
        // identity: metadata edits keep the same columns (DIY weights with another shape stay exact).
        guard definitionFacts.isBundledQwertyMainShell else { return 0 }
        return index == 1 ? 0.5 : (index == 2 ? 1.5 : 0)
    }

    func definitionRow(
        _ row: LayoutRow, id: String, inset: CGFloat = 0,
        spacing: CGFloat = 4, split: ActiveLayoutSplit? = nil, rowIndex: Int = 0,
        fixedKeyWidth: CGFloat? = nil, splitGap: CGFloat? = nil
    ) -> some View {
        KeyboardDefinitionRow(
            keys: visibleKeys(row.keys), inset: inset, spacing: spacing, split: split, rowIndex: rowIndex,
            fixedKeyWidth: fixedKeyWidth, splitGap: splitGap, isControls: id == "controls"
        ) { key, index in
            definitionKey(key, id: "\(id)-\(index)")
        }
    }

    func visibleKeys(_ keys: [LayoutKey]) -> [LayoutKey] {
        keys.filter { $0.action.type != .globe || systemKeyboardSwitch != nil }
    }

    @ViewBuilder
    func auxiliaryColumn(_ position: LayoutAuxiliaryArea.Position) -> some View {
        // Called only by `configuredKeypad` (i.e. `usesStandardT9 == false`), so no always-true condition such as
        // `!usesStandardT9 || ...` is written here. Whether Return belongs to the shared T9 bottom row is decided by
        // `PhoneKeypadRailPolicy` / `t9AuxiliaryKeys`; DIY definitions keep their own keys verbatim.
        KeyboardAuxiliaryColumn(
            keys: visibleKeys(
                (activeDefinition?.auxiliaryAreas ?? [])
                    .filter { $0.position == position && !$0.requiresEngineDisambiguation }.flatMap(\.keys)),
            rowCount: definitionMainRows.count
        ) { key, index in
            definitionKey(key, id: "\(position.rawValue)-\(index)")
        }
    }

    /// The **real order** in which the main-area first key cycles when idle (from the fourth item on).
    ///
    /// The order shares its source with the left rail's first three (`BuiltinLayouts.t9QuickSymbolValues`), so "three in the left rail + the rest on the first
    /// key" covers every item of the user's saved order exactly once. Only the bundled, unmodified 9-key
    /// reaches here (`isT9FirstKey`); DIY/imported definitions keep their own declarations verbatim.
    ///
    /// With the default sequence there is always a fourth item on (default is 6 items), but if the list is ever empty it falls back to the system
    /// address punctuation rather than leaving a dead key that does nothing on tap; title and action share a source, so they never disagree.
    private var t9FirstKeyCycleValues: [String] {
        let values = SymbolPageTable.quickCycle(
            symbols: quickSymbols.symbols,
            ascii: controller.usesASCIIPunctuation)
        return values.isEmpty
            ? BuiltinLayouts.t9PunctuationSymbols()
            : values
    }

    @ViewBuilder
    func definitionKey(
        _ key: LayoutKey, id: String, onAction: ((KeyAction, Bool) -> Void)? = nil
    ) -> some View {
        let perform: (KeyAction, Bool) -> Void = { action, feedback in
            if let onAction {
                onAction(action, feedback)
            } else if feedback {
                handleDefinitionAction(action)
            } else {
                handleKey(action, emitFeedback: false)
            }
        }
        // Page-level UI actions never become an engine key action: a main layout key that carries
        // one (or an authored long-press option that does) goes through the UI dispatcher instead
        // of being silently mapped onto layout cycling.
        let optionsContainUI = (key.longPress ?? []).contains { $0.action.type.isPageUI }
        // The known phone9 first key keeps its native cycle/separator behavior even when an authored
        // long press adds page UI actions; route it through the engine face with control-option
        // dispatch instead of the mixed UI face, which would lose cycling.
        if isKnownPhone9Primary && id == "row-0-0" {
            definitionEngineKey(
                key, id: id, perform: perform,
                onControlOption: { action in
                    performDefinitionFaceAction(action, alternate: true, onAction: onAction)
                })
        } else if key.action.type.isPageUI {
            definitionUIActionKey(key, id: id, onAction: onAction)
        } else if key.action.type == .code,
            (key.longPress ?? []).contains(where: { $0.action.type != .code && $0.action.type != .literal })
        {
            // A UI alternate must not replace letter-group swipes, hints or the T9 first-key policy.
            definitionEngineKey(
                key, id: id, perform: perform,
                onControlOption: { action in
                    performDefinitionFaceAction(action, alternate: true, onAction: onAction)
                })
        } else if optionsContainUI
            || ((key.action.type == .space || key.action.type == .globe) && !(key.longPress ?? []).isEmpty)
        {
            // An authored long press replaces the native gesture even when every option is literal.
            definitionMixedUIActionKey(key, id: id, onAction: onAction)
        } else {
            definitionEngineKey(key, id: id, perform: perform)
        }
    }

    /// A definition key whose visible action is a page-level UI action. Stable cap ids route back
    /// to the stored action; native gestures are replaced only where the author declared a
    /// long-press list, exactly like an authored page key.
    @ViewBuilder
    private func definitionUIActionKey(
        _ key: LayoutKey, id: String, onAction: ((KeyAction, Bool) -> Void)?
    ) -> some View {
        let actionMap = definitionUIActionMap(key, id: id)
        let languageKeepsMenu = key.action.type == .languageSwitch && (key.longPress ?? []).isEmpty
        let alternates =
            languageKeepsMenu
            ? userKeyboardAlternates
            : (key.longPress ?? []).enumerated().map { index, option in
                KeyCap(
                    id: "\(id)-ui-option-\(index)", title: option.label,
                    subtitle: nil, action: .cycleLayout)
            }
        let dispatch: (KeyCap) -> Void = { cap in
            if let action = actionMap[cap.id] {
                performDefinitionFaceAction(
                    action, alternate: cap.id.contains("-option-"), onAction: onAction)
            } else if languageKeepsMenu {
                handleLanguageMenuCap(cap)
            }
        }
        let customTitle = key.titleMode == .custom ? key.label : nil
        if key.action.type == .shift, (key.longPress ?? []).isEmpty {
            ShiftKey(
                state: controller.shiftState, isEnglishMode: controller.isEnglishMode,
                customTitle: customTitle, subtitle: key.secondaryLabel,
                tap: { keyFeedbackAfterEffect { controller.handleShiftTap() } },
                doubleTap: { keyFeedbackAfterEffect { controller.handleShiftDoubleTap() } })
        } else if key.action.type == .clearInput {
            AlternateCharacterKey(
                cap: KeyCap(
                    id: "\(id)-ui", title: definitionUIActionTitle(key),
                    subtitle: key.secondaryLabel, action: .cycleLayout),
                alternates: alternates,
                longPressDelay: activeDefinition?.effectiveLongPressDelay ?? 0.35,
                layoutPicker: languageKeepsMenu,
                visualRole: definitionUIActionRole(key),
                onSelect: dispatch
            )
            .accessibilityLabel(definitionUIActionAccessibility(key))
            .disabled(!controller.snapshot.isComposing)
        } else {
            AlternateCharacterKey(
                cap: KeyCap(
                    id: "\(id)-ui", title: definitionUIActionTitle(key),
                    subtitle: key.secondaryLabel, action: .cycleLayout),
                alternates: alternates,
                longPressDelay: activeDefinition?.effectiveLongPressDelay ?? 0.35,
                layoutPicker: languageKeepsMenu,
                visualRole: definitionUIActionRole(key),
                onSelect: dispatch
            )
            .accessibilityLabel(definitionUIActionAccessibility(key))
        }
    }

    /// Main-layout definition dispatch: page-level UI actions run in the UI layer, engine actions
    /// keep the engine handler path. Main actions never pass through the category recorder,
    /// which intentionally rejects plain codes.
    private func performDefinitionFaceAction(
        _ action: LayoutAction, alternate: Bool, onAction: ((KeyAction, Bool) -> Void)?
    ) {
        if action.type.isPageUI {
            performAuthoredPageAction(action, isAlternate: alternate)
        } else if let onAction {
            onAction(keyAction(action), true)
        } else {
            handleDefinitionAction(keyAction(action))
        }
    }

    /// Primary is an ordinary engine action; only its declared long-press options carry page UI
    /// actions. The primary keeps its live face (Return enabled, space title, delete glyph) and a
    /// short tap always performs that engine action, never the category filter.
    @ViewBuilder
    private func definitionMixedUIActionKey(
        _ key: LayoutKey, id: String, onAction: ((KeyAction, Bool) -> Void)?
    ) -> some View {
        let optionActions = Dictionary(
            uniqueKeysWithValues: (key.longPress ?? []).enumerated().map { index, option in
                ("\(id)-mixed-option-\(index)", option.action)
            })
        let optionCaps = (key.longPress ?? []).enumerated().map { index, option in
            KeyCap(
                id: "\(id)-mixed-option-\(index)", title: option.label,
                action: keyAction(option.action))
        }
        let primary: () -> Void = {
            switch key.action.type {
            case .shift:
                keyFeedbackAfterEffect { controller.handleShiftTap() }
            default:
                performDefinitionFaceAction(key.action, alternate: false, onAction: onAction)
            }
        }
        let select: (KeyCap) -> Void = { cap in
            guard let action = optionActions[cap.id] else {
                primary()
                return
            }
            performDefinitionFaceAction(action, alternate: true, onAction: onAction)
        }
        let customTitle = key.titleMode == .custom ? key.label : nil
        let longPressDelay = activeDefinition?.effectiveLongPressDelay ?? 0.35
        let primaryID = "\(id)-mixed-primary"
        switch key.action.type {
        case .enter:
            ReturnKey(
                title: customTitle ?? controller.returnKeyTitle,
                isEnabled: controller.isReturnKeyEnabled, alternates: optionCaps,
                longPressDelay: longPressDelay, capID: primaryID, subtitle: key.secondaryLabel,
                onSelect: select)
        case .space:
            AlternateCharacterKey(
                cap: KeyCap(
                    id: primaryID,
                    title: customTitle
                        ?? (key.titleMode == .automatic
                            ? (controller.isEnglishMode ? "space" : "空格") : key.label),
                    subtitle: key.secondaryLabel, action: .space),
                alternates: optionCaps, longPressDelay: longPressDelay, onSelect: select)
        case .globe:
            AlternateCharacterKey(
                cap: KeyCap(
                    id: primaryID, title: customTitle ?? "🌐", subtitle: key.secondaryLabel,
                    action: .switchKeyboard),
                alternates: optionCaps, longPressDelay: longPressDelay, onSelect: select)
        case .backspace:
            AlternateCharacterKey(
                cap: KeyCap(
                    id: primaryID, title: customTitle ?? "⌫", subtitle: key.secondaryLabel,
                    action: .backspace),
                alternates: optionCaps, longPressDelay: longPressDelay, onSelect: select)
        case .shift:
            AlternateCharacterKey(
                cap: KeyCap(
                    id: primaryID, title: customTitle ?? "⇧", subtitle: key.secondaryLabel,
                    action: .cycleLayout),
                alternates: optionCaps, longPressDelay: longPressDelay,
                visualRole: controller.shiftState.isActive ? "selected" : "control",
                onSelect: select)
        default:
            AlternateCharacterKey(
                cap: KeyCap(
                    id: primaryID,
                    title: customTitle
                        ?? key.literalFaceTitle(usesASCIIPunctuation: effectiveUsesASCIIPunctuation),
                    subtitle: key.secondaryLabel,
                    action: keyAction(key.action)),
                alternates: optionCaps, longPressDelay: longPressDelay,
                showsKeyPreview: key.action.type == .code && (key.action.value?.count ?? 0) == 1,
                onSelect: select)
        }
    }

    private func definitionUIActionMap(_ key: LayoutKey, id: String) -> [String: LayoutAction] {
        var actions: [String: LayoutAction] = ["\(id)-ui": key.action]
        for (index, option) in (key.longPress ?? []).enumerated() {
            actions["\(id)-ui-option-\(index)"] = option.action
        }
        return actions
    }

    private func definitionUIActionTitle(_ key: LayoutKey) -> String {
        guard key.titleMode == .automatic else { return key.label }
        return KeyboardPageControlFace.title(for: key, policy: controlPolicy) ?? key.label
    }

    private func definitionUIActionAccessibility(_ key: LayoutKey) -> String {
        guard key.titleMode == .automatic else { return key.label }
        return KeyboardPageControlFace.accessibilityLabel(for: key, policy: controlPolicy) ?? key.label
    }

    private func definitionUIActionRole(_ key: LayoutKey) -> String? {
        switch key.action.type {
        case .symbolLock: return symbolPageLocked ? "selected" : "control"
        case .shift: return controller.shiftState.isActive ? "selected" : "control"
        default: return nil
        }
    }

    @ViewBuilder
    private func definitionEngineKey(
        _ key: LayoutKey, id: String, perform: @escaping (KeyAction, Bool) -> Void,
        onControlOption: ((LayoutAction) -> Void)? = nil
    ) -> some View {
        let controlOptions = (key.longPress ?? []).enumerated().compactMap { index, option -> (KeyCap, LayoutAction)? in
            guard onControlOption != nil, option.action.type != .code, option.action.type != .literal else {
                return nil
            }
            return (
                KeyCap(id: "\(id)-ui-option-\(index)", title: option.label, action: .cycleLayout), option.action
            )
        }
        // The known phone9 first key cycles punctuation while idle and separates syllables while
        // composing. Only its dynamic action/title is overridden here: the authored key keeps its
        // label, secondary label, long-press list and declared width.
        let isT9FirstKey = isKnownPhone9Primary && id == "row-0-0"
        let isComposing = controller.snapshot.isComposing
        let cycleValues = isT9FirstKey ? t9FirstKeyCycleValues : []
        let dynamicFirstKey: (title: String, action: LayoutAction)? =
            isT9FirstKey
            ? (isComposing
                ? ("分词", LayoutAction(.code, value: "'"))
                : (
                    cycleValues.prefix(3).joined(),
                    LayoutAction(.literal, value: cycleValues.first ?? key.action.value ?? "")
                ))
            : nil
        // A custom title always wins. The live cycle title is a native-shell state, so a primary-only
        // match (metadata edited, shell not injected) keeps the author's stored label instead.
        let firstKeyTitle: String = {
            guard key.titleMode != .custom, let dynamicFirstKey, isBuiltinPhonePad else {
                return key.label
            }
            return dynamicFirstKey.title
        }()
        let firstKeyAction: LayoutAction = dynamicFirstKey?.action ?? key.action
        let customTitle = key.titleMode == .custom ? key.label : nil
        if key.action.type == .globe {
            if let systemKeyboardSwitch {
                NativeInputModeKey(
                    title: customTitle, subtitle: key.secondaryLabel,
                    handleEvent: systemKeyboardSwitch,
                    accessibilitySwitch: { controller.handle(.switchKeyboard) })
            }
        } else if key.action.type == .backspace && (key.longPress ?? []).isEmpty {
            RepeatingDeleteKey(title: customTitle, subtitle: key.secondaryLabel) { isRepeating in
                perform(.backspace, !isRepeating)
            }
        } else if key.action.type == .enter {
            ReturnKey(
                title: customTitle ?? controller.returnKeyTitle,
                isEnabled: controller.isReturnKeyEnabled,
                alternates: (key.longPress ?? []).enumerated().map { index, option in
                    KeyCap(id: "\(id)-option-\(index)", title: option.label, action: keyAction(option.action))
                }, longPressDelay: activeDefinition?.effectiveLongPressDelay ?? 0.35,
                subtitle: key.secondaryLabel
            ) {
                perform($0.action, true)
            }
        } else if key.action.type == .space {
            CursorSpaceKey(
                title: customTitle
                    ?? (key.titleMode == .automatic ? (controller.isEnglishMode ? "space" : "空格") : key.label),
                layoutName: currentKeyboardTitle,
                layoutHintName: layoutHintName,
                layoutHintToken: layoutHintToken,
                subtitle: key.secondaryLabel,
                onTap: { perform(.space, true) },
                moveCursor: cursorMovement)
        } else {
            // Hints follow the letters each key carries, one per letter; a merged key
            // shows them in columns under its letters. The bundled merged pad draws
            // lowercase letters and keeps its digits on the 123 page.
            let letterGroup = LetterGroupLayout.group(of: key) ?? []
            let presetKey = knownMainShellPresetKey(for: id, key: key)
            let knownShellFaceUnchanged = presetKey.map { bundledKeyFaceUnchanged(key, preset: $0) } == true
            let groupHints =
                page == .letters && !controller.isEnglishMode
                    && ShuangpinHintOverlay.letterGroups(for: activeDefinition) != nil
                ? ShuangpinHintOverlay.hints(
                    for: key, labels: shuangpinHints?.activePreset?.hints ?? [:],
                    // A known bundled main shell keeps its bundled hint policy while its face is
                    // untouched; an edited face keeps the author's labels, and imported/DIY
                    // definitions never get the bundled policy.
                    preservingSecondaryLabel:
                        !(isBundledDefinition
                        || (knownMainShellPreset != nil && knownShellFaceUnchanged))) : []
            let overlayHint = letterGroup.count == 1 ? groupHints.first ?? nil : nil
            let mergedHints = letterGroup.count > 1 && groupHints.contains { $0 != nil } ? groupHints : []
            let mergedShell = usesBundledMergedPad
            let bundledMergedFace = mergedShell && knownShellFaceUnchanged
            let subtitle =
                !mergedHints.isEmpty
                ? nil
                : (bundledMergedFace ? overlayHint : (overlayHint ?? key.secondaryLabel))
            let cap = KeyCap(
                id: id,
                title: isT9FirstKey
                    ? firstKeyTitle
                    : (bundledMergedFace
                        ? key.label.lowercased()
                        : key.literalFaceTitle(usesASCIIPunctuation: effectiveUsesASCIIPunctuation)),
                subtitle: subtitle, action: keyAction(isT9FirstKey ? firstKeyAction : key.action))
            // A sideways swipe types either exact letter, when the schema accepts both.
            let letterSwipe =
                page == .letters
                ? (AlternateKeyPolicy.letterSwipeCodes(
                    group: letterGroup,
                    schemaAlphabet: controller.activeSchemaAlphabet) ?? [])
                    .map {
                        KeyCap(id: "\(id)-swipe-\($0)", title: $0, action: .code(controller.exactPickCode($0)))
                    }
                : []
            // The bundled merged pad uses its code group on tap; the
            // per-key long-press alternative menu adds friction rather than an
            // essential input path. Imported/DIY declarations remain intact.
            //
            // The default 9-key's first key and digit keys 2-9 are the exception: their alternate **is the one the layout declares**
            // (first key `1`, each digit key its own digit; corner badge + long-press direct input), so take the declaration directly.
            // It cannot go through `AlternateKeyPolicy`, which by letter-page semantics rejects a `keyLabel` that is not a single letter,
            // and the first key's label is a punctuation string while digit keys are `.code("2")` with the "ABC" keycap, so both would be dropped;
            // the generic extension would also give the first key a redundant punctuation menu, turning the cycling key back into a long-press symbol key.
            // Other layouts keep the original policy; the check reuses LayoutKit's same function so tests take the same path.
            let isT9DigitKey = isKnownPhone9Primary && BuiltinLayouts.t9DigitKeyUsesDeclaredAlternates(key)
            // The first key's authored long-press order is the menu order, including page-UI
            // options: declared code/literal options and control options keep their declaration
            // position instead of splitting into two appended groups.
            let options: [KeyCap] =
                if isT9FirstKey {
                    orderedAuthorOptions(
                        for: key, id: id, includeControlOptions: onControlOption != nil)
                } else if isT9DigitKey {
                    if let presetKey, key.longPress == presetKey.longPress {
                        declaredAlternates(for: key, id: id) + controlOptions.map { $0.0 }
                    } else {
                        orderedAuthorOptions(
                            for: key, id: id, includeControlOptions: onControlOption != nil)
                    }
                } else if let presetKey, let knownMainShellPreset {
                    if key.longPress == presetKey.longPress {
                        // Untouched menu: the bundled policy stays (qwerty menus) or stays
                        // suppressed (merged pad deliberately has none).
                        if knownMainShellPreset.input.builtinLayout == .qwerty26 {
                            definitionAlternates(for: key, id: id) + controlOptions.map { $0.0 }
                        } else {
                            []
                        }
                    } else {
                        // Only the edited keys surface the author's menu, in declaration order and
                        // without policy-generated duplicate entries.
                        orderedAuthorOptions(
                            for: key, id: id, includeControlOptions: onControlOption != nil)
                    }
                } else if key.action.type == .code, !(key.longPress ?? []).isEmpty {
                    // Authored/DIY code long-press lists keep their declared order, labels,
                    // literals and pairs; only an untouched known-shell preset menu falls back to
                    // the policy above.
                    orderedAuthorOptions(
                        for: key, id: id, includeControlOptions: onControlOption != nil)
                } else {
                    definitionAlternates(for: key, id: id) + controlOptions.map { $0.0 }
                }
            // The idle first key has two actions and AX must describe both; while composing it is word-split + long-press 1.
            // This is a `@ViewBuilder` context, where an `if` is taken as a view branch, so a ternary expression is required.
            // The default hint describes the bundled first key (tap cycles, long press types 1).
            // A primary-only match keeps the author's label, so it must not promise those defaults.
            let cycleHint: String? =
                !isT9FirstKey
                ? nil
                : !isBuiltinPhonePad
                    ? (isComposing ? "轻点分词" : "连续点按轮换符号")
                    : (isComposing
                        ? "轻点分词，长按输入 1"
                        : "连续点按轮换符号，长按输入 1")
            AlternateCharacterKey(
                cap: cap, alternates: options,
                longPressDelay: activeDefinition?.effectiveLongPressDelay ?? 0.35,
                phoneKey: usesStandardT9,
                phoneSideKey: usesStandardT9 && !id.hasPrefix("row-"),
                showsKeyPreview: !compactSpellingCapability
                    && key.action.type == .code
                    && (key.action.value?.count ?? 0) == 1
                    && key.label.count == 1,
                letterGroup: letterGroup.count > 1
                    ? letterGroup.map { bundledMergedFace ? String($0).lowercased() : String($0) }
                    : [],
                groupHints: mergedHints,
                letterSwipe: letterSwipe,
                swipeUp: t9SwipeDigit(for: key),
                syllableHintBelow: overlayHint != nil,
                accessibilityHintOverride: cycleHint
            ) { selected in
                // Only a **short press of the main key** cycles. The long-press `1` popup (and any future alternate) must take
                // normal action semantics, otherwise lifting the finger after a long press on 1 would be mistaken for a cycle.
                if let option = controlOptions.first(where: { $0.0.id == selected.id }) {
                    onControlOption?(option.1)
                } else if isT9FirstKey && !isComposing, selected == cap {
                    selectionFeedbackAfterEffect { controller.cycleT9Punctuation(symbols: cycleValues) }
                } else {
                    perform(selected.action, true)
                }
            }
            .disabled(
                usesStandardT9 && key.action == LayoutAction(.code, value: "'") && !controller.snapshot.isComposing
                    && controlOptions.isEmpty
            )
            .opacity(
                usesStandardT9 && key.action == LayoutAction(.code, value: "'") && !controller.snapshot.isComposing
                    ? 0.45 : 1)
        }
    }

    private var knownMainShellPreset: LayoutDefinition? {
        KeyboardPanelRules.knownMainShellPreset(definitionFacts)
    }

    private func knownMainShellPresetKey(for id: String, key: LayoutKey) -> LayoutKey? {
        guard let preset = knownMainShellPreset else { return nil }
        return KeyboardPanelRules.mainShellPresetKey(in: preset, id: id, key: key)
    }

    /// The author's long-press order is the menu order, mixing code/literal actions and page-UI
    /// controls exactly where they were stored.
    private func orderedAuthorOptions(
        for key: LayoutKey, id: String, includeControlOptions: Bool
    ) -> [KeyCap] {
        (key.longPress ?? []).enumerated().compactMap { index, option in
            if option.action.type == .code || option.action.type == .literal {
                return KeyCap(
                    id: "\(id)-option-\(index)", title: option.label,
                    action: keyAction(option.action))
            }
            guard includeControlOptions else { return nil }
            return KeyCap(
                id: "\(id)-ui-option-\(index)", title: option.label,
                action: .cycleLayout)
        }
    }

    private func bundledKeyFaceUnchanged(_ key: LayoutKey, preset: LayoutKey) -> Bool {
        KeyboardPanelRules.keyFaceUnchanged(key, preset: preset)
    }

    /// The bundled T9 digit keys type their digit on an upward flick, the same
    /// literal their long press offers.
    private func t9SwipeDigit(for key: LayoutKey) -> KeyCap? {
        guard isKnownPhone9Primary, key.action.type == .code, let digit = key.action.value,
            digit.count == 1, ("2"..."9").contains(digit)
        else { return nil }
        return KeyCap(id: "swipe-\(digit)", title: digit, action: .literal(digit))
    }

    func handleDefinitionAction(_ action: KeyAction) {
        if action == .cycleLayout {
            // The layout key always goes through the controller's cycling entry: with a user keyboard list it cycles among the
            // **user-added keyboards**, and with an empty list it falls back to cycling built-in layouts (the keyboard stays usable). It does not cycle
            // the definition list itself, which would bypass the user-keyboard contract.
            selectionFeedbackAfterEffect { controller.cycleLayout() }
            onReadingRowReport?(readingRowReport)
        } else if action == .code("'") && !controller.snapshot.isComposing {
            return  // A syllable separator only applies to an existing composition; its alternates still work.
        } else {
            handleKey(action)
        }
    }

    /// Alternate for the bundled 9-key's first key: takes **only** the layout-declared longPress, bypassing the generic extension policy.
    ///
    /// This keeps the layout declaration, the resource inspection page, and runtime in agreement (all from the same `longPress`),
    /// and avoids growing a pile of punctuation just because the label is a comma. ASCII fields are still filtered by the same rule (digits are not
    /// affected), keeping the same behavior boundary as other keys.
    private func declaredAlternates(for key: LayoutKey, id: String) -> [KeyCap] {
        (key.longPress ?? []).enumerated().compactMap { index, option in
            guard option.action.type == .code || option.action.type == .literal else { return nil }
            return KeyCap(
                id: "\(id)-option-\(index)", title: option.label,
                action: keyAction(option.action))
        }
    }

    /// Definition-backed code keys share the same evidence-based alternate
    /// policy as standard rows. In particular, T9 group labels never become a
    /// fixed ABC list, and a merged-key partner is emitted only when the active
    /// schema's real alphabet proves that code. Non-code custom keys retain their
    /// declared actions, with ASCII-field punctuation filtering.
    private func definitionAlternates(for key: LayoutKey, id: String) -> [KeyCap] {
        guard key.action.type == .code else {
            // Authored non-code options are user data: keep every declared action/label/pair.
            return (key.longPress ?? []).enumerated().map { index, option in
                KeyCap(
                    id: "\(id)-option-\(index)", title: option.label,
                    action: keyAction(option.action))
            }
        }
        let representative = key.action.value ?? key.label
        let group = key.label.lowercased()
        let merged = group.count > 1 && group.allSatisfy(\.isLetter) ? group : nil
        let declaredLiterals = (key.longPress ?? []).compactMap {
            $0.action.type == .literal ? $0.action.value : nil
        }
        var options = AlternateKeyPolicy.options(
            for: .init(
                keyLabel: representative,
                mergedGroup: merged,
                secondaryLiterals: declaredLiterals,
                page: .letters,
                language: controller.isEnglishMode ? .english : .chinese,
                isUppercase: controller.shiftState.isActive,
                usesASCIIPunctuation: controller.usesASCIIPunctuation,
                schemaAlphabet: controller.activeSchemaAlphabet))

        // Imported compact merged layouts may declare explicit partner codes.
        // Preserve only live-alphabet single-character codes; phone/T9 groups
        // are excluded because their letter choices must come from live v4
        // prefix evidence, never a layout declaration.
        if !usesStandardT9 {
            let alphabet = Set(controller.activeSchemaAlphabet.lowercased())
            for declared in key.longPress ?? [] where declared.action.type == .code {
                guard let value = declared.action.value?.lowercased(), value.count == 1,
                    let character = value.first, alphabet.contains(character),
                    !options.contains(where: { option in
                        if case .code(let existing) = option.payload { return existing == value }
                        return false
                    })
                else { continue }
                options.append(.init(label: declared.label, payload: .code(value)))
            }
        }
        return options.enumerated().map { index, option in
            let action: KeyAction =
                switch option.payload {
                case .code(let value): .code(value)
                case .literal(let value): .literal(value)
                }
            return KeyCap(id: "\(id)-option-\(index)", title: option.label, action: action)
        }
    }

    func keyAction(_ action: LayoutAction) -> KeyAction {
        action.keyAction(usesASCIIPunctuation: effectiveUsesASCIIPunctuation)
    }

    private var definitionHasGlobe: Bool { definitionFacts.hasGlobe }

    var layoutUtilityBar: some View {
        KeyboardLayoutUtilityBar(
            controlRow: definitionControlRow, rowIndex: definitionMainRows.count, split: activeSplit,
            showsGlobe: systemKeyboardSwitch != nil, definitionHasGlobe: definitionHasGlobe,
            onPage: { target in
                emitKeyFeedback()
                page = target
                showsAllCandidates = false
            },
            key: { key, id, _ in definitionKey(key, id: id) },
            globe: {
                if let systemKeyboardSwitch {
                    NativeInputModeKey(
                        handleEvent: systemKeyboardSwitch,
                        accessibilitySwitch: { controller.handle(.switchKeyboard) })
                }
            },
            modeSwitch: { modeSwitchKey })
    }

    func alternates(for cap: KeyCap) -> [KeyCap] {
        if let keyAlternates { return keyAlternates(cap) }
        let mergedGroup: String?
        let secondaryLiterals: [String]
        let keyLabel: String
        switch cap.action {
        case .code(let value):
            keyLabel = value
            let group = cap.title.lowercased()
            mergedGroup = group.count > 1 && group.allSatisfy(\.isLetter) ? group : nil
            secondaryLiterals = AlternateKeyPolicy.defaultLetterLiterals(for: value)
        case .literal(let value):
            keyLabel = value
            mergedGroup = nil
            secondaryLiterals = []
        default:
            return []
        }

        let policyPage: AlternateKeyPolicy.Page =
            switch page {
            case .letters: .letters
            case .numeric: .numeric
            case .symbols: .symbols
            }
        let request = AlternateKeyPolicy.Request(
            keyLabel: keyLabel,
            mergedGroup: mergedGroup,
            secondaryLiterals: secondaryLiterals,
            page: policyPage,
            language: controller.isEnglishMode ? .english : .chinese,
            isUppercase: controller.shiftState.isActive,
            usesASCIIPunctuation: controller.usesASCIIPunctuation,
            schemaAlphabet: controller.activeSchemaAlphabet,
            visibleKeys: page == .letters ? [] : Set(symbolRows.flatMap { $0.caps.map(\.title) }))
        return AlternateKeyPolicy.options(for: request).enumerated().map { index, option in
            let action: KeyAction =
                switch option.payload {
                case .code(let value): .code(value)
                case .literal(let value):
                    controller.isEnglishMode && value.count == 1 && value.first?.isLetter == true
                        ? .letterVariant(value.lowercased()) : .literal(value)
                }
            return KeyCap(id: "\(cap.id)-alternate-\(index)", title: option.label, action: action)
        }
    }

    var letterRows: [KeyboardRow] {
        controller.isEnglishMode ? controller.englishLetterRows : KeyboardLayoutTable.mainRows(for: controller.layout)
    }

    func letterRowInset(_ index: Int) -> CGFloat {
        guard controller.isEnglishMode || controller.layout == .qwerty26 else { return 0 }
        return index == 1 ? 0.5 : (index == 2 ? 1.5 : 0)
    }

    /// Expands the current page of candidates: CandidateKit default renderer (list/grid, column count/spacing, and whole-row
    /// long sentences are all configurable). The height budget follows the main key-row area (compact and native globe unchanged).
    var expandedCandidates: some View {
        candidateRendererView(expanded: true)
            .frame(height: mainAreaHeight)
    }
}
