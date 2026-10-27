import CandidateKit
import Combine
import KeyboardCore
import LayoutKit
import QuickContentKit
import SwiftUI

extension KeyboardPanelView {
    /// One rail slot equals one number row (`metrics.rowHeight`), so the left
    /// column and the 3×3 grid start every row on the same line.
    private func t9RailSlotHeight(_ metrics: PhoneKeypadMetrics) -> CGFloat { CGFloat(metrics.rowHeight) }

    /// The engine-backed choices a phone rail shows while composing: spelling
    /// locks (or their undo) first, then the reading filter's undo and readings.
    typealias T9RailChoices = SpellingRailChoices

    private var liveT9RailChoices: T9RailChoices { controller.spellingRailChoices }

    /// The live choices once settled (nil otherwise); feeds `heldT9RailChoices`.
    var settledT9RailChoices: T9RailChoices? {
        guard compactSpellingCapability, controller.snapshot.isComposing, t9RailChoicesSettled else { return nil }
        return liveT9RailChoices
    }

    /// The rail's engine queries for the live composition have settled: the
    /// ambiguity report and the first reading page both arrived (or will not).
    var t9RailChoicesSettled: Bool {
        !controller.ambiguityQueryPending && !controller.awaitsFirstReadingPage
    }

    /// What the rail shows and whether it may act on it. Each key resets the
    /// engine-backed choices and re-queries them ~50ms later. Showing the reset
    /// state in between flashed the rail back to punctuation (a tap meant for a
    /// reading then committed the composition with a symbol) and let a late
    /// spelling report shift the readings under the finger. Until the queries
    /// settle, the previous choices stay on screen; spelling/reading taps are
    /// deferred and checked against the live result, while undo remains inert.
    var displayedT9RailChoices: (choices: T9RailChoices, interactive: Bool) {
        if t9RailChoicesSettled || !controller.snapshot.isComposing { return (liveT9RailChoices, true) }
        return (heldT9RailChoices ?? T9RailChoices(), false)
    }

    /// Readings/spelling choices get a readable size instead of the 14pt control
    /// label size; long spellings still shrink to fit the rail width.
    private static let t9RailChoiceTitleSize: Double = 17

    /// Three fixed punctuation slots; only engine-backed reading choices scroll.
    private func t9LeadingSidebar(_ metrics: PhoneKeypadMetrics) -> some View {
        let displayed = displayedT9RailChoices
        let showsReadingChoices =
            controller.snapshot.isComposing
            // Interactive means `displayed.choices` are the live ones; resolving them
            // again here and in `t9ReadingChoices` cost two more passes per render.
            && (displayed.interactive ? !displayed.choices.isEmpty : heldT9RailChoices != nil)
        return ZStack {
            if showsReadingChoices {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: CGFloat(metrics.spacing)) { t9ReadingChoices(metrics, displayed: displayed) }
                }
                .sharpCandidateScrollEdges()
            } else {
                // The first three type directly; from the fourth on, there is no long press here: tapping the main-area first key cycles through them.
                KeyboardPhoneSymbolRail(
                    caps: SymbolPageTable.quickRail(
                        symbols: quickSymbols.symbols,
                        ascii: controller.usesASCIIPunctuation), metrics: metrics,
                    onSelect: { handleKey($0.action) })
            }
        }
        .id(showsReadingChoices)
        // Readings rarely fill all three slots. The rail reads as one column of
        // choices on a side-key surface instead of keys with an empty hole below.
        .background {
            if showsReadingChoices {
                RoundedRectangle(cornerRadius: appearance.skin.keycap.cornerRadius)
                    .fill(appearance.color("control"))
                    .padding(.horizontal, appearance.skin.spacing.visualInsetX)
                    .padding(.vertical, appearance.skin.spacing.visualInsetY)
            }
        }
        // Outside the identity switch above: entering or leaving a composition
        // must not re-read the shared quick-symbol store every time.
        .onAppear { quickSymbols.reload() }
        .onChange(of: hostBindingTick) { quickSymbols.reload() }
    }

    /// One action owner for engine-backed spelling/undo, reused by the bundled
    /// quick-symbol rail and imported phone definitions. Imports keep every
    /// declared rail key below these options in the same vertical scroller.
    ///
    /// Spelling and reading choices use the same UIKit key (`AlternateCharacterKey`)
    /// as the quick symbols in this scroller: the drawn cap and the tracked control
    /// are one view, so the visible slot is exactly the hit slot, and a tap is not
    /// arbitrated differently from the neighbouring keys. Every slot keeps the digit
    /// row pitch (no divider), so the rail and the 3×3 grid stay on the same lines.
    @ViewBuilder
    private func t9ReadingChoices(
        _ metrics: PhoneKeypadMetrics, displayed resolved: (choices: T9RailChoices, interactive: Bool)? = nil
    ) -> some View {
        if controller.snapshot.isComposing {
            let displayed = resolved ?? displayedT9RailChoices
            let choices = displayed.choices
            // Undo is the delete key (`KeyboardController.handleBackspaceTap`): the rail
            // only offers choices, never a separate back button.
            Group {
                // What is already chosen stays visible (accent, not tappable), so the
                // rail never goes blank once every typed syllable has a reading.
                if let locked = choices.lockedOption {
                    t9RailSelection(locked, metrics: metrics)
                        .accessibilityLabel("已锁定组合 \(locked)")
                }
                if choices.isFiltering {
                    t9RailSelection(choices.readingPrefix.joined(separator: " "), metrics: metrics)
                        .accessibilityLabel("已选读音 \(choices.readingPrefix.joined(separator: " "))")
                }
                if !choices.canUndoLock {
                    ForEach(Array(choices.lockOptions.enumerated()), id: \.offset) { index, option in
                        t9RailChoiceKey(
                            option, id: "lock-\(option)", slot: "lock-\(index)", hint: "锁定组合",
                            metrics: metrics
                        ) {
                            controller.selectRailSpelling(option)
                        }
                    }
                }
                ForEach(Array(choices.readings.enumerated()), id: \.offset) { index, reading in
                    t9RailChoiceKey(
                        reading, id: "reading-\(index)-\(reading)", slot: "reading-\(index)",
                        hint: "选择读音", metrics: metrics
                    ) {
                        controller.selectRailReading(reading, expectedPrefix: choices.readingPrefix)
                    }
                }
            }
            if displayed.interactive && controller.readingFilter.hasMore
                && !controller.readingFilter.readFailed && !controller.readingPrefetchSatisfied
            {
                Color.clear.frame(height: 1)
                    .task(id: controller.readingFilter.nextIndex) {
                        if !Task.isCancelled { controller.loadMoreReadings() }
                    }
            }
        }
    }

    /// An applied choice in the rail slot rhythm; the delete key undoes it.
    private func t9RailSelection(_ text: String, metrics: PhoneKeypadMetrics) -> some View {
        Text(text)
            .font(appearance.font(Self.t9RailChoiceTitleSize))
            .foregroundStyle(appearance.accentForeground)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
            .frame(height: t9RailSlotHeight(metrics))
            .accessibilityHint("按删除键撤销")
    }

    /// A trusted engine choice drawn and tracked by the rail's UIKit key.
    private func t9RailChoiceKey(
        _ title: String, id: String, slot: String, hint: String,
        metrics: PhoneKeypadMetrics,
        perform: @escaping () -> Void
    ) -> some View {
        AlternateCharacterKey(
            cap: KeyCap(id: id, title: title, subtitle: hint, action: .literal(title)),
            alternates: [], phoneKey: true, phoneSideKey: true,
            titleSize: Self.t9RailChoiceTitleSize,
            accessibilityID: "t9.spelling.\(slot)",
            onSelect: { _ in selectionFeedbackAfterEffect(perform) }
        )
        // The UIKit control belongs to its rail slot, so typing updates it in place
        // instead of building a new one per key. A changed cap id (another choice,
        // or a lock turning into a reading) abandons a press still held on it and
        // `configure` swaps in the new action.
        .id(slot)
        .frame(height: t9RailSlotHeight(metrics))
    }

    private func t9ImportedReadingRail(_ metrics: PhoneKeypadMetrics) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: CGFloat(metrics.spacing)) {
                t9ReadingChoices(metrics)
            }
            .buttonStyle(KeyboardPressStyle())
        }
        .sharpCandidateScrollEdges()
    }

    /// A secondary rail built from the definition's auxiliary keys, laid out in
    /// deterministic row slots via `PhoneKeypadMetrics.slotSpans` — never an
    /// independent `VStack` whose `maxHeight` guesses at the grid.
    private func t9AuxiliaryRail(
        _ metrics: PhoneKeypadMetrics,
        position: LayoutAuxiliaryArea.Position
    ) -> some View {
        KeyboardPhoneDeclaredRail(
            keys: t9AuxiliaryKeys(position), position: position, metrics: metrics,
            readings: { t9ReadingChoices(metrics) },
            key: { key, index in definitionKey(key, id: "\(position.rawValue)-\(index)") })
    }

    /// The rail keys a phone keypad definition contributes on one side. This is used
    /// **only** for an imported definition (`PhoneKeypadRailPolicy.declared`); the
    /// bundled T9 is `bundledAuthored` and renders its own rail, so nothing declared
    /// here is used for it. Return is never filtered out — an import keeps exactly
    /// what it declared.
    func t9AuxiliaryKeys(_ position: LayoutAuxiliaryArea.Position) -> [LayoutKey] {
        guard let definition = activeDefinition else { return [] }
        return visibleKeys(PhoneKeypadRailPolicy.declaredKeys(in: definition, position: position))
    }

    var standardT9Keypad: some View {
        StablePhoneKeypadShell(
            trailingSpansControlRow: isBuiltinPhonePad,
            expandsForSplit: activeSplit != nil,
            leading: { metrics in
                t9Rail(.leading, metrics: metrics)
            },
            main: { metrics in
                VStack(spacing: CGFloat(metrics.spacing)) {
                    if showsAllCandidates && !controller.snapshot.candidates.isEmpty {
                        expandedCandidates
                    } else {
                        // Per-key candidate/reading publishes re-ran and re-laid out the
                        // whole grid; it only changes with the key-area inputs.
                        KeyAreaRenderGate(token: keyAreaRenderToken(phone: metrics)) {
                            VStack(spacing: CGFloat(metrics.spacing)) {
                                ForEach(Array(definitionMainRows.enumerated()), id: \.offset) { index, row in
                                    definitionRow(
                                        row, id: "row-\(index)", spacing: CGFloat(metrics.spacing),
                                        split: activeSplit, rowIndex: index)
                                }
                            }
                        }.equatable()
                    }
                }
                // Candidate expand/collapse replaces the same area in place; page and
                // language switches likewise have no ancestor key-area animation.
            },
            trailing: { metrics in
                // An imported trailing rail may carry reading choices; only the bundled
                // editing rail is static.
                if isBuiltinPhonePad {
                    KeyAreaRenderGate(token: keyAreaRenderToken(phone: metrics)) {
                        t9Rail(.trailing, metrics: metrics)
                    }.equatable()
                } else {
                    t9Rail(.trailing, metrics: metrics)
                }
            },
            bottom: { metrics in
                // The bundled T9 keeps the shared standard control row. An imported
                // phone keypad keeps the DIY bottom bar it declared (its own control
                // row plus globe/layout switch), so importing a layout never silently
                // rewrites its information architecture.
                KeyAreaRenderGate(token: keyAreaRenderToken(phone: metrics)) {
                    if isBuiltinPhonePad { phoneControlRow(metrics) } else { layoutUtilityBar }
                }.equatable()
            })
    }

    /// A phone letter definition gets a phone digit pad on 123: 1–9 in the 3×3
    /// grid, 0 in the bottom utility slot, the page's punctuation in the rail.
    /// #+= stays the shared full symbol page.
    var phoneSymbolKeypad: some View {
        KeyboardPhoneDigitPad(
            usesASCIIPunctuation: effectiveUsesASCIIPunctuation, split: activeSplit,
            trailingSpansControlRow: isBuiltinPhonePad,
            showsExpanded: showsAllCandidates && !controller.snapshot.candidates.isEmpty,
            alternates: alternates, onKey: { handleKey($0.action) },
            expanded: { expandedCandidates },
            trailing: { metrics in
                if isBuiltinPhonePad { t9FixedEditingRail(metrics) } else { t9Rail(.trailing, metrics: metrics) }
            },
            bottom: { metrics in
                phoneControlRow(metrics)
            })
    }

    /// The symbol page of every layout (#+= on 26/14/18-key, 符号 on 9-key):
    /// categories in the leading rail, the open category's symbols in a grid of
    /// digit-pad-height keys (four columns, two for kaomoji) that scrolls
    /// vertically, the ⌫ / 重输 / ⏎ column and the phone-pad control row, so a
    /// thumb reaches every symbol without hunting through rows of narrow keys.
    ///
    /// Like Sogou and iFlytek, one symbol returns to the page the user types on
    /// unless 锁定 is on; the lock lasts for this keyboard session.
    var phoneCategorySymbolKeypad: some View {
        let categories = phoneSymbolCategories
        let open = categories.first { $0.id == phoneSymbolCategoryID } ?? categories[0]
        let categorySplit = resolvedCategorySplit(open.split)
        return KeyboardCategorySymbolPad(
            categories: categories, open: open, split: categorySplit,
            trailingSpansControlRow: usesFixedEditingRail,
            onSelectCategory: { id in
                emitKeyFeedback()
                phoneSymbolCategoryID = id
            },
            key: { key, index in
                if open.authoredKeys != nil {
                    authoredPageKey(
                        key, id: "category-\(open.id)-\(index)", kind: .symbols,
                        onSelect: { action, feedback in recordCategoryAction(action, emitFeedback: feedback) })
                } else {
                    AlternateCharacterKey(cap: open.caps[index], alternates: [], showsKeyPreview: true) { cap in
                        recordCategoryAction(cap.action)
                    }
                }
            },
            trailing: { metrics in
                if usesFixedEditingRail { t9FixedEditingRail(metrics) } else { t9Rail(.trailing, metrics: metrics) }
            },
            bottom: { metrics in
                phoneControlRow(metrics, splitOverride: categorySplit?.withoutRowBreaks)
            }
        )
        // Every visit opens on 常用. Also picks up library edits made in the app
        // and recents from the symbol panel.
        .onAppear {
            phoneSymbolCategoryID = categories[0].id
            symbolLibrary.reload()
        }
        // Uses are recorded when the page closes, so 最近 never reorders under the
        // finger while several symbols are typed in a row.
        .onDisappear {
            for text in pendingSymbolUses { symbolLibrary.recordUse(text) }
            pendingSymbolUses = []
        }
    }

    /// Full-width marks lead in Chinese punctuation, half-width ones in English or
    /// ASCII punctuation, matching what the letter page's punctuation types.
    func recordCategoryAction(_ action: KeyAction, emitFeedback: Bool = true) {
        if action == .cycleLayout {
            handleDefinitionAction(action)
            return
        }
        guard handleKey(action, emitFeedback: emitFeedback), case .literal(let text) = action else { return }
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { pendingSymbolUses.append(text) }
        if !symbolPageLocked { page = controller.hostPreferredInput == .numeric ? .numeric : .letters }
    }

    var phoneSymbolCategories: [SymbolPageTable.PhoneSymbolCategory] {
        symbolLibrary.pageCategories(
            authored: pageDefinition?.categories,
            ascii: controller.isEnglishMode || controller.usesASCIIPunctuation,
            showsGlobe: systemKeyboardSwitch != nil)
    }

    /// Both rails go through the one policy: only the bundled T9 gets the
    /// shell-authored static keys. An import keeps all declared keys; verified
    /// reading choices are added only to its leading scroller while composing.
    /// Delete/return are never fabricated for an import.
    @ViewBuilder
    private func t9Rail(_ position: LayoutAuxiliaryArea.Position, metrics: PhoneKeypadMetrics) -> some View {
        let keys = t9AuxiliaryKeys(position)
        switch PhoneKeypadRailPolicy.content(isBuiltinPhonePad: isBuiltinPhonePad, declaredKeyCount: keys.count) {
        case .bundledAuthored:
            if position == .leading {
                t9LeadingSidebar(metrics)
            } else {
                t9FixedEditingRail(metrics)
            }
        case .declared:
            t9AuxiliaryRail(metrics, position: position)
        case .empty:
            if position == .leading && controller.snapshot.isComposing {
                t9ImportedReadingRail(metrics)
            } else {
                Color.clear
            }
        }
    }

    /// No pinyin-cycle key on the right: real readings are picked directly in the left scrolling rail.
    /// Only reachable for the bundled definition and the categorised symbol page.
    private func t9FixedEditingRail(_ metrics: PhoneKeypadMetrics) -> some View {
        KeyboardFixedEditingRail(
            metrics: metrics, returnTitle: controller.returnKeyTitle,
            isReturnEnabled: controller.isReturnKeyEnabled, isComposing: controller.snapshot.isComposing,
            onDelete: { isRepeating in handleKey(.backspace, emitFeedback: !isRepeating) },
            onReset: { keyFeedbackAfterEffect { _ = controller.discardComposition() } },
            onReturn: { handleDefinitionAction($0.action) })
    }
}
