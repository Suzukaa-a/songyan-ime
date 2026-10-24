import CandidateKit
import Combine
import KeyboardCore
import LayoutKit
import SwiftUI

extension KeyboardPanelView {
    /// Bundled merged letter pad (14-key, 18-key): the definition's rows at their weighted widths
    /// (`MergedKeypadGeometry`), with the separator in the Shift slot and Delete closing the last row.
    /// Keys keep the definition's codes; the Chinese merged page has no case, so the Shift slot becomes word-split.
    var mergedKeypad: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 4
            let rows = definitionMainRows
            let side = sharedDeleteWidth(for: geometry.size.width)
            let metrics = MergedKeypadGeometry.rows(
                weights: rows.map { $0.keys.map(\.widthWeight) },
                width: geometry.size.width, spacing: spacing,
                sideWidth: side)
            VStack(spacing: spacing) {
                ForEach(Array(zip(rows, metrics).enumerated()), id: \.offset) { index, entry in
                    let isLast = index == rows.count - 1
                    HStack(spacing: spacing) {
                        if isLast {
                            mergedSeparatorKey.frame(width: side, height: keyHeight)
                        }
                        ForEach(Array(entry.0.keys.enumerated()), id: \.offset) { keyIndex, key in
                            definitionKey(key, id: "merged-\(key.action.value ?? "\(index)-\(keyIndex)")")
                                .frame(width: entry.1.keyWidths[keyIndex], height: keyHeight)
                        }
                        if isLast {
                            RepeatingDeleteKey { isRepeating in handleKey(.backspace, emitFeedback: !isRepeating) }
                                .frame(width: side, height: keyHeight)
                        }
                    }
                    .frame(width: geometry.size.width)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(height: CGFloat(max(1, definitionMainRows.count)) * (keyHeight + 4) - 4)
    }

    /// Syllable separator in the merged pad's Shift slot; only a composition uses it.
    private var mergedSeparatorKey: some View {
        AlternateCharacterKey(
            cap: KeyCap(id: "merged-separator", title: "分词", action: .code("'")),
            alternates: [], visualRole: "control",
            titleSize: appearance.controlTextSize
        ) { _ in
            handleDefinitionAction(.code("'"))
        }
        .disabled(!controller.snapshot.isComposing)
        .accessibilityLabel("分词")
    }

    func definitionInset(_ row: LayoutRow, index: Int) -> CGFloat {
        // Familiar stagger only for the bundled QWERTY definitions; DIY weights stay exact.
        guard activeDefinition?.id == BuiltinLayouts.qwerty26.id,
            isBundledDefinition
        else { return 0 }
        return index == 1 ? 0.5 : (index == 2 ? 1.5 : 0)
    }

    func definitionRow(
        _ row: LayoutRow, id: String, inset: CGFloat = 0,
        spacing: CGFloat = 4
    ) -> some View {
        let keys = visibleKeys(row.keys)
        return GeometryReader { geometry in
            let available = max(0, geometry.size.width - CGFloat(max(0, keys.count - 1)) * spacing)
            let widths = LayoutRowWidthProjection(weights: keys.map(\.widthWeight), inset: Double(inset))
            let isControls = id == "controls"
            let minimum: CGFloat = isControls ? 44 : 0
            let remainder = max(0, available - CGFloat(keys.count) * minimum)
            let row = HStack(spacing: spacing) {
                ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                    definitionKey(key, id: "\(id)-\(index)")
                        .frame(
                            width: isControls
                                ? minimum + remainder * CGFloat(widths.keyFractions[index])
                                : available * CGFloat(widths.keyFractions[index]), height: keyHeight)
                }
            }
            .padding(.horizontal, available * CGFloat(widths.insetFraction))
            if isControls {
                // Only an authored control row can exceed the width (44pt minimum
                // per key), so only it may scroll.
                ScrollView(.horizontal, showsIndicators: false) { row }
                    .sharpCandidateScrollEdges()
            } else {
                // Letter/digit rows fill the width exactly, so they need no ScrollView:
                // one per row would add gesture arbitration to every key touch and
                // an iOS 26 scroll edge effect along the top of the first row.
                row
            }
        }
        .frame(height: keys.isEmpty ? 0 : keyHeight)
    }

    func visibleKeys(_ keys: [LayoutKey]) -> [LayoutKey] {
        keys.filter { $0.action.type != .globe || systemKeyboardSwitch != nil }
    }

    @ViewBuilder
    func auxiliaryColumn(_ position: LayoutAuxiliaryArea.Position) -> some View {
        // Called only by `configuredKeypad` (i.e. `usesStandardT9 == false`), so no always-true condition such as
        // `!usesStandardT9 || ...` is written here. Whether Return belongs to the shared T9 bottom row is decided by
        // `PhoneKeypadRailPolicy` / `t9AuxiliaryKeys`; DIY definitions keep their own keys verbatim.
        let keys = visibleKeys(
            (activeDefinition?.auxiliaryAreas ?? [])
                .filter { $0.position == position && !$0.requiresEngineDisambiguation }.flatMap(\.keys))
        if !keys.isEmpty {
            VStack(spacing: 4) {
                ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                    definitionKey(key, id: "\(position.rawValue)-\(index)")
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(
                width: 44,
                height: CGFloat(max(1, definitionMainRows.count)) * (keyHeight + 4) - 4)
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
    func definitionKey(_ key: LayoutKey, id: String) -> some View {
        // The bundled first key cycles punctuation while idle and separates syllables while composing.
        let isT9FirstKey = isBuiltinPhonePad && id == "row-0-0"
        let cycleValues = isT9FirstKey ? t9FirstKeyCycleValues : []
        let key =
            isT9FirstKey
            ? (controller.snapshot.isComposing
                ? BuiltinLayouts.t9SeparatorKey()
                : (BuiltinLayouts.t9CycleKey(cycleValues)
                    ?? BuiltinLayouts.t9PunctuationKey()))
            : key
        if key.action.type == .globe {
            if let systemKeyboardSwitch {
                NativeInputModeKey(
                    handleEvent: systemKeyboardSwitch,
                    accessibilitySwitch: { controller.handle(.switchKeyboard) })
            }
        } else if key.action.type == .backspace && (key.longPress ?? []).isEmpty {
            RepeatingDeleteKey { isRepeating in handleKey(.backspace, emitFeedback: !isRepeating) }
        } else if key.action.type == .enter {
            ReturnKey(
                title: controller.returnKeyTitle, isEnabled: controller.isReturnKeyEnabled,
                alternates: (key.longPress ?? []).enumerated().map { index, option in
                    KeyCap(id: "\(id)-option-\(index)", title: option.label, action: keyAction(option.action))
                }, longPressDelay: activeDefinition?.effectiveLongPressDelay ?? 0.35
            ) {
                handleDefinitionAction($0.action)
            }
        } else if key.action.type == .space {
            CursorSpaceKey(
                title: key.label,
                layoutName: currentKeyboardTitle,
                layoutHintName: layoutHintName,
                layoutHintToken: layoutHintToken,
                onTap: { handleKey(.space) },
                moveCursor: cursorMovement)
        } else {
            // Hints follow the letters each key carries, one per letter; a merged key
            // shows them in columns under its letters. The bundled merged pad draws
            // lowercase letters and keeps its digits on the 123 page.
            let letterGroup = LetterGroupLayout.group(of: key) ?? []
            let groupHints =
                page == .letters && !controller.isEnglishMode
                    && ShuangpinHintOverlay.letterGroups(for: activeDefinition) != nil
                ? ShuangpinHintOverlay.hints(
                    for: key, labels: shuangpinHints?.activePreset?.hints ?? [:],
                    preservingSecondaryLabel: !isBundledDefinition) : []
            let overlayHint = letterGroup.count == 1 ? groupHints.first ?? nil : nil
            let mergedHints = letterGroup.count > 1 && groupHints.contains { $0 != nil } ? groupHints : []
            let subtitle =
                !mergedHints.isEmpty
                ? nil
                : (usesBundledMergedPad ? overlayHint : (overlayHint ?? key.secondaryLabel))
            let cap = KeyCap(
                id: id, title: usesBundledMergedPad ? key.label.lowercased() : key.label,
                subtitle: subtitle, action: keyAction(key.action))
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
            let isT9DigitKey = isBuiltinPhonePad && BuiltinLayouts.t9DigitKeyUsesDeclaredAlternates(key)
            let options =
                isT9FirstKey || isT9DigitKey
                ? declaredAlternates(for: key, id: id)
                : (usesBundledMergedPad ? [] : definitionAlternates(for: key, id: id))
            // The idle first key has two actions and AX must describe both; while composing it is word-split + long-press 1.
            // This is a `@ViewBuilder` context, where an `if` is taken as a view branch, so a ternary expression is required.
            let cycleHint: String? =
                !isT9FirstKey
                ? nil
                : (controller.snapshot.isComposing
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
                    ? letterGroup.map { usesBundledMergedPad ? String($0).lowercased() : String($0) }
                    : [],
                groupHints: mergedHints,
                letterSwipe: letterSwipe,
                swipeUp: t9SwipeDigit(for: key),
                syllableHintBelow: overlayHint != nil,
                accessibilityHintOverride: cycleHint
            ) { selected in
                // Only a **short press of the main key** cycles. The long-press `1` popup (and any future alternate) must take
                // normal action semantics, otherwise lifting the finger after a long press on 1 would be mistaken for a cycle.
                if isT9FirstKey && !controller.snapshot.isComposing, selected == cap {
                    selectionFeedbackAfterEffect { controller.cycleT9Punctuation(symbols: cycleValues) }
                } else {
                    handleDefinitionAction(selected.action)
                }
            }
            .disabled(
                usesStandardT9 && key.action == LayoutAction(.code, value: "'") && !controller.snapshot.isComposing
            )
            .opacity(
                usesStandardT9 && key.action == LayoutAction(.code, value: "'") && !controller.snapshot.isComposing
                    ? 0.45 : 1)
        }
    }

    /// The bundled T9 digit keys type their digit on an upward flick, the same
    /// literal their long press offers.
    private func t9SwipeDigit(for key: LayoutKey) -> KeyCap? {
        guard isBuiltinPhonePad, key.action.type == .code, let digit = key.action.value,
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
            if controller.usesASCIIPunctuation,
                option.action.type == .literal,
                let value = option.action.value,
                !AlternateKeyPolicy.isAllowedInASCIIField(value)
            {
                return nil
            }
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
            return (key.longPress ?? []).enumerated().compactMap { index, option in
                if controller.usesASCIIPunctuation,
                    option.action.type == .literal,
                    let value = option.action.value,
                    !AlternateKeyPolicy.isAllowedInASCIIField(value)
                {
                    return nil
                }
                return KeyCap(
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

    private func keyAction(_ action: LayoutAction) -> KeyAction {
        switch action.type {
        case .code: return .code(action.value ?? "")
        case .literal: return .literal(action.value ?? "")
        case .space: return .space
        case .backspace: return .backspace
        case .enter: return .enter
        case .globe: return .switchKeyboard
        case .modeSwitch: return .cycleLayout
        }
    }

    private var definitionHasGlobe: Bool { definitionFacts.hasGlobe }

    @ViewBuilder
    var layoutUtilityBar: some View {
        HStack(spacing: 4) {
            if let row = definitionControlRow {
                definitionRow(row, id: "controls")
            } else {
                Spacer(minLength: 0)
            }
            if !definitionHasGlobe, let systemKeyboardSwitch {
                NativeInputModeKey(
                    handleEvent: systemKeyboardSwitch,
                    accessibilitySwitch: { controller.handle(.switchKeyboard) }
                )
                .frame(width: 44, height: keyHeight)
            }
            modeSwitchKey
                .frame(width: 44, height: keyHeight)
        }
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(.primary)
        .buttonStyle(KeyboardPressStyle())
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
