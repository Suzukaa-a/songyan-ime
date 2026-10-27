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
        if let pageDefinition {
            authoredPage(pageDefinition)
        } else {
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
                        WeightedKeyRow(caps: row.caps, edgeUnits: letterRowInset(index), alternates: alternates) {
                            cap in
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
                KeyboardSymbolPageRows(
                    rows: symbolRows, split: activeSplit, alternates: alternates,
                    onTap: { handleKey($0.action) },
                    delete: { RepeatingDeleteKey { repeating in handleKey(.backspace, emitFeedback: !repeating) } })
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
        if pageDefinition != nil { return pageDefinitionReadsComposition }
        guard page == .letters, !controller.isEnglishMode else { return false }
        if usesBundledMergedPad || isBuiltinPhonePad || usesStandardT9 { return true }
        let auxiliary = (activeDefinition?.auxiliaryAreas ?? []).flatMap(\.keys)
        return (definitionMainRows.flatMap(\.keys) + auxiliary).contains {
            $0.action.type == .enter || $0.action.type == .clearInput
                || $0.action == LayoutAction(.code, value: "'")
        }
    }

    /// Every authored region counts: an Enter key draws the live Return title and enabled state,
    /// a clear-input key its live enabled state. Category content is top-level page content too.
    static func pageReadsComposition(_ page: KeyboardPageDefinition) -> Bool {
        page.containsKey { $0.action.type == .enter || $0.action.type == .clearInput }
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
            pageDefinition: pageDefinition,
            split: activeSplit,
            layout: controller.layout,
            selectedSchemaID: controller.selectedSchemaID,
            inputMode: controller.inputMode,
            isEnglishMode: controller.isEnglishMode,
            shiftState: controller.shiftState,
            isComposing: readsComposition && controller.snapshot.isComposing,
            usesASCIIPunctuation: effectiveUsesASCIIPunctuation,
            symbolMarks: effectiveSymbolMarks,
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
            prefersCategorySymbolPage: prefersCategorySymbolPage,
            symbolPageLocked: symbolPageLocked,
            symbolCategoryID: phoneSymbolCategoryID,
            showsExpandedCandidates: showsExpandedCandidates)
    }

    var usesConfiguredLayout: Bool { page == .letters && !controller.isEnglishMode && pageDefinition == nil }

    /// The one phone-keypad shell serves the bundled T9 **and** any imported
    /// definition with the same three-by-three digit structure, so both get the
    /// identical geometry instead of the imported one falling back to a second,
    /// differently-aligned renderer. 14/26-key rows can never match (their rows
    /// never have exactly three keys of telephone digits).
    var usesStandardT9: Bool {
        usesConfiguredLayout && usesPhoneDefinition
    }

    var usesPhoneDefinition: Bool { definitionFacts.isPhone }

    /// Narrow visual-shell identity for the bundled T9: gates the injected quick-symbol rail,
    /// the fixed Delete + separator rail and the fixed control row. Only rendered main-row
    /// long-press menus may differ from the preset.
    var isBuiltinPhonePad: Bool { definitionFacts.isBuiltinPhonePad }

    /// The known bundled phone9 primary gestures (first-key cycle, digit up-flick, declared
    /// alternates) without any shell assumption. Never use it to gate injected chrome.
    var isKnownPhone9Primary: Bool { definitionFacts.isKnownPhone9Primary }

    /// Structural main-shell identity of a bundled merged letter layout (14-key, 18-key): the
    /// shared merged pad + synthesized separator/Delete, while main-row faces/long-press menus are
    /// rendered from the definition. DIY/imported shapes without the builtin metadata do not match.
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

    /// The 123 rows, or the row-shaped #+= page's (the categorized page has no rows).
    var symbolRows: [KeyboardRow] {
        page == .symbols
            ? SymbolPageTable.symbolRows(ascii: effectiveUsesASCIIPunctuation)
            : SymbolPageTable.numericRows(ascii: effectiveUsesASCIIPunctuation)
    }

    /// Only the untouched bundled 26-key definitions receive the standard system-key shell.
    var usesStandardQwerty: Bool {
        // English always uses the built-in English shell; Chinese keeps it for the known 26-key
        // structure even after metadata edits (labels/LP), not only for the strict content identity.
        controller.isEnglishMode || definitionFacts.isBundledQwertyMainShell
    }

    private var standardQwertyKeypad: some View {
        KeyboardStandardQwertyPad(
            split: activeSplit,
            row: { index, metrics in standardQwertyRow(index, metrics: metrics) },
            shift: {
                ShiftKey(
                    state: controller.shiftState, isEnglishMode: controller.isEnglishMode,
                    tap: { keyFeedbackAfterEffect { controller.handleShiftTap() } },
                    doubleTap: { keyFeedbackAfterEffect { controller.handleShiftDoubleTap() } })
            },
            delete: { RepeatingDeleteKey { repeating in handleKey(.backspace, emitFeedback: !repeating) } })
    }

    @ViewBuilder
    private func standardQwertyRow(_ index: Int, metrics: StandardKeyRowGeometry) -> some View {
        if controller.isEnglishMode {
            WeightedKeyRow(
                caps: controller.englishLetterRows[index].caps, alternates: alternates,
                showsKeyPreview: true, split: activeSplit, rowIndex: index,
                fixedKeyWidth: CGFloat(metrics.keyWidth), splitGap: CGFloat(metrics.gap)
            ) { handleKey($0.action) }
        } else if definitionMainRows.indices.contains(index) {
            definitionRow(
                definitionMainRows[index], id: "row-\(index)",
                split: activeSplit, rowIndex: index, fixedKeyWidth: CGFloat(metrics.keyWidth),
                splitGap: CGFloat(metrics.gap))
        }
    }

    var cursorMovement: ((Int) -> Void)? {
        guard allowsCursorMovement else { return nil }
        return { controller.moveCursor(by: $0) }
    }
}
