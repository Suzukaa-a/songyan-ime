import CandidateKit
import Combine
import KeyboardCore
import LayoutKit
import SwiftUI

extension KeyboardPanelView {
    /// A successful scheme/style choice also updates the persisted physical definition.
    /// Otherwise extension recreation can reconcile an old definition over the new pair.
    /// Main key row of the letters / 123 / #+= pages (123 and #+= are both direct literal keys).
    @ViewBuilder
    private var keyRows: some View {
        switch page {
        case .letters:
            if usesStandardQwerty {
                standardQwertyKeypad
            } else if usesBundledMergedPad {
                mergedKeypad
            } else if usesConfiguredLayout {
                configuredKeypad
            } else {
                // Renderer input stays at KeyboardRow/KeyCap; LayoutKit can supply these rows.
                ForEach(Array(letterRows.enumerated()), id: \.element.id) { index, row in
                    WeightedKeyRow(caps: row.caps, edgeUnits: letterRowInset(index), alternates: alternates) { cap in
                        handleKey(cap.action)
                    }
                }
            }
        case .numeric, .symbols:
            // The shared 26/14 page keeps exactly the same symbols and geometry.
            // Every literal symbol is a character key and keeps the character
            // surface, like the letters it replaces; only real controls (Delete,
            // the page key, CN/EN, Return) carry the control/accent tone. A key
            // with a long-press list shows its first entry in the corner, as the
            // letters do; the lists are kept short so the rows stay calm. These
            // caps are as narrow as 26-key letters,
            // so they reuse the same panel-local key preview: the finger-covered
            // glyph is confirmed above the key while its hit rectangle, action
            // and slide-off cancel stay exactly those of the key itself. The full
            // #+= symbol page is shared even for a phone letter definition;
            // compressing it into 3x3 hides too many direct-access symbols.
            ForEach(Array(symbolRows.enumerated()), id: \.element.id) { index, row in
                if index == 2 {
                    GeometryReader { geometry in
                        HStack(spacing: 4) {
                            WeightedKeyRow(
                                caps: row.caps, alternates: alternates, showsKeyPreview: true
                            ) {
                                handleKey($0.action)
                            }
                            .frame(width: max(0, geometry.size.width - sharedDeleteWidth(for: geometry.size.width) - 4))
                            RepeatingDeleteKey { isRepeating in handleKey(.backspace, emitFeedback: !isRepeating) }
                                .frame(width: sharedDeleteWidth(for: geometry.size.width), height: keyHeight)
                        }
                    }
                    .frame(height: keyHeight)
                } else {
                    WeightedKeyRow(
                        caps: row.caps, alternates: alternates, showsKeyPreview: true
                    ) {
                        handleKey($0.action)
                    }
                }
            }
        }
    }

    /// Render gate for the key area (letters/123/#+= main rows and the bottom row): the ~35 key bodies are recomputed only when an input that really affects
    /// key caps, positions, long-press alternates, or bottom-row titles/enabled state changes; per-key candidate/preedit
    /// publishes during composition do not rebuild the whole area. Key callbacks read live values through `controller` and `@State` storage,
    /// so reusing the previous closures when recomputation is skipped stays correct. Any new input that affects key-area rendering must be folded in here.
    var gatedKeyRows: some View {
        // The gate supplies its own row spacing: after `.equatable()` wrapping, multi-row content does not expand into the outer VStack,
        // and omitting an explicit wrapper would change the line spacing.
        KeyAreaRenderGate(token: keyAreaRenderToken(phone: nil, readsComposition: keyRowsReadComposition)) {
            VStack(spacing: 4) { keyRows }
        }.equatable()
    }

    /// Whether the main key rows (not the bottom control row, which has its own gate)
    /// draw anything from the composition: the Return key's title and enabled state,
    /// the merged pad's separator, the bundled 9-key first key. Plain letter rows do not,
    /// so starting or ending a word does not rebuild every letter key.
    private var keyRowsReadComposition: Bool {
        guard page == .letters, !controller.isEnglishMode else { return false }
        if usesBundledMergedPad || isBuiltinPhonePad || usesStandardT9 { return true }
        let auxiliary = (activeDefinition?.auxiliaryAreas ?? []).flatMap(\.keys)
        return (definitionMainRows.flatMap(\.keys) + auxiliary).contains {
            $0.action.type == .enter || $0.action == LayoutAction(.code, value: "'")
        }
    }

    var keyAreaRenderToken: KeyAreaRenderToken { keyAreaRenderToken(phone: nil) }

    /// The phone keypad's static regions (3×3 grid, editing rail, control row) also
    /// depend on the shell's resolved geometry.
    func keyAreaRenderToken(
        phone metrics: PhoneKeypadMetrics?,
        readsComposition: Bool = true
    ) -> KeyAreaRenderToken {
        KeyAreaRenderToken(
            phoneMetrics: metrics,
            controller: ObjectIdentifier(controller),
            hostBindingTick: hostBindingTick,
            keyAreaGeneration: keyAreaGeneration,
            page: page,
            keyHeight: keyHeight,
            appearance: appearance,
            preferredLayoutID: localLayoutID ?? selectedLayoutID,
            definitionInputsRevision: controller.definitionInputsRevision,
            shuangpinHintEnabled: shuangpinHints?.enabled ?? false,
            shuangpinHintPresetID: shuangpinHints?.selectedPresetID,
            shuangpinHintLabels: shuangpinHints?.activePreset?.hints ?? [:],
            shuangpinHintRevision: shuangpinHintRevision,
            activeDefinition: activeDefinition,
            layout: controller.layout,
            selectedSchemaID: controller.selectedSchemaID,
            inputMode: controller.inputMode,
            isEnglishMode: controller.isEnglishMode,
            shiftState: controller.shiftState,
            isComposing: readsComposition && controller.snapshot.isComposing,
            usesASCIIPunctuation: controller.usesASCIIPunctuation,
            returnKeyTitle: readsComposition ? controller.returnKeyTitle : "",
            isReturnKeyEnabled: readsComposition && controller.isReturnKeyEnabled,
            schemaAlphabet: controller.activeSchemaAlphabet,
            publishedKeyboards: controller.publishedKeyboards,
            quickSymbols: quickSymbols.symbols,
            layoutHintName: layoutHintName,
            layoutHintToken: layoutHintToken,
            hasKeyAlternates: keyAlternates != nil,
            hasSystemKeyboardSwitch: systemKeyboardSwitch != nil,
            allowsCursorMovement: allowsCursorMovement,
            prefersCategorySymbolPage: prefersCategorySymbolPage)
    }

    var usesConfiguredLayout: Bool { page == .letters && !controller.isEnglishMode }

    /// The one phone-keypad shell serves the bundled T9 **and** any imported
    /// definition with the same three-by-three digit structure, so both get the
    /// identical geometry instead of the imported one falling back to a second,
    /// differently-aligned renderer. 14/26-key rows can never match (their rows
    /// never have exactly three keys of telephone digits).
    var usesStandardT9: Bool {
        usesConfiguredLayout && usesPhoneDefinition
    }

    var usesPhoneDefinition: Bool { definitionFacts.isPhone }

    /// Content equality with the bundled T9 gates the bundled-only chrome (the
    /// quick-symbol rail, the fixed Delete + separator rail).
    var isBuiltinPhonePad: Bool { definitionFacts.isBuiltinPhonePad }

    /// Exact match of a bundled merged letter layout (14-key, 18-key; content-level Equatable, so DIY
    /// key edits and same-id imports do not match): the shared merged pad + bottom row via ControlRow,
    /// instead of sizing controls by JSON weights.
    var usesBundledMergedPad: Bool { usesConfiguredLayout && definitionFacts.isBundledMergedPad }

    /// Whether the current **physical definition** proves support for compact spelling (composition disambiguation + read-only reading browse).
    ///
    /// This is **not** `controller.layout`: kind describes input method/encoding, and a definition with 26-key rows but a
    /// `builtinLayout` mislabeled `phone9`/`merged14` would get that kind too. This reads the
    /// real row/key structure (`CompactSpellingLayout`); a 26-key layout is always false.
    var compactSpellingCapability: Bool { definitionFacts.needsEngineSpelling }

    /// Syncs the physical capability to the controller/session (the sole eligibility for disambiguation UI and engine queries).
    /// Called on the definition resolve/switch **event path**, so eligibility is correct before any query runs.
    func injectCompactSpellingCapability() {
        // Capability and **content-level identity** are injected from the same source: the controller's direct entry points use them for failure-recovery decisions.
        controller.updateCompactSpellingContext(
            eligible: compactSpellingCapability,
            numericTransport: activeDefinition.map(PhoneKeypadStructure.matches) == true,
            definitionIdentity: LayoutRuntimeIdentity(activeDefinition),
            readingKeys: CompactSpellingLayout.readingKeyMap(for: activeDefinition))
    }

    /// The 123 rows, or the row-shaped #+= page's (the categorised page has no rows).
    var symbolRows: [KeyboardRow] {
        page == .symbols
            ? SymbolPageTable.symbolRows(ascii: controller.usesASCIIPunctuation)
            : SymbolPageTable.numericRows(ascii: controller.usesASCIIPunctuation)
    }

    /// Only the untouched bundled 26-key definitions receive the standard system-key shell.
    var usesStandardQwerty: Bool {
        controller.isEnglishMode || (isBundledDefinition && activeDefinition?.id == BuiltinLayouts.qwerty26.id)
    }

    private var standardQwertyKeypad: some View {
        ForEach(0..<3, id: \.self) { index in
            if index == 2 {
                GeometryReader { geometry in
                    let sideWidth = sharedDeleteWidth(for: geometry.size.width)
                    HStack(spacing: 4) {
                        ShiftKey(
                            state: controller.shiftState, isEnglishMode: controller.isEnglishMode,
                            tap: { keyFeedbackAfterEffect { controller.handleShiftTap() } },
                            doubleTap: { keyFeedbackAfterEffect { controller.handleShiftDoubleTap() } }
                        )
                        .frame(width: sideWidth, height: keyHeight)
                        standardQwertyRow(index)
                        RepeatingDeleteKey { isRepeating in handleKey(.backspace, emitFeedback: !isRepeating) }
                            .frame(width: sideWidth, height: keyHeight)
                    }
                }
                .frame(height: keyHeight)
            } else {
                standardQwertyRow(index)
            }
        }
    }

    /// The visible cap and the UIKit hit rectangle use one width in 26-key,
    /// merged-14, and 123/# +=. Keep Delete wider than the merged-14 M cap
    /// even at narrow phone widths; the symbol page must not shrink it back.
    func sharedDeleteWidth(for width: CGFloat) -> CGFloat {
        max(56, (width - 32) / 10 * 1.8)
    }

    @ViewBuilder
    private func standardQwertyRow(_ index: Int) -> some View {
        if controller.isEnglishMode {
            WeightedKeyRow(
                caps: controller.englishLetterRows[index].caps,
                edgeUnits: index == 1 ? 0.5 : 0, alternates: alternates,
                showsKeyPreview: true
            ) {
                handleKey($0.action)
            }
        } else if definitionMainRows.indices.contains(index) {
            definitionRow(definitionMainRows[index], id: "row-\(index)", inset: index == 1 ? 0.5 : 0)
        }
    }

    var cursorMovement: ((Int) -> Void)? {
        guard allowsCursorMovement else { return nil }
        return { controller.moveCursor(by: $0) }
    }
}
