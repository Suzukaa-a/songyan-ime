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

    private var hasT9ReadingChoices: Bool { !liveT9RailChoices.isEmpty }

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
    private static let t9QuickSymbolTitleSize: Double = 19

    /// Three fixed punctuation slots; only engine-backed reading choices scroll.
    private func t9LeadingSidebar(_ metrics: PhoneKeypadMetrics) -> some View {
        let displayed = displayedT9RailChoices
        let showsReadingChoices =
            controller.snapshot.isComposing
            && (displayed.interactive ? hasT9ReadingChoices : heldT9RailChoices != nil)
        return ZStack {
            if showsReadingChoices {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: CGFloat(metrics.spacing)) { t9ReadingChoices(metrics) }
                }
                .sharpCandidateScrollEdges()
            } else {
                // The first three type directly; from the fourth on, there is no long press here: tapping the main-area first key cycles through them.
                fixedPhoneSymbolRail(
                    SymbolPageTable.quickRail(
                        symbols: quickSymbols.symbols,
                        ascii: controller.usesASCIIPunctuation), metrics: metrics)
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

    /// The three left-rail slots.
    ///
    /// `firstKeyAlternates` is for callers whose **only reachable path is still long press** (currently only the 123 page's
    /// punctuation rail). T9 letter-page quick symbols are "first three direct + the rest cycled by tapping the main-area first key",
    /// so they pass an empty array: no redundant long-press menu, and no visible-but-unreachable hint.
    private func fixedPhoneSymbolRail(
        _ caps: [KeyCap], metrics: PhoneKeypadMetrics,
        firstKeyAlternates: [KeyCap] = []
    ) -> some View {
        VStack(spacing: CGFloat(metrics.spacing)) {
            ForEach(Array(caps.prefix(3).enumerated()), id: \.element.id) { index, cap in
                AlternateCharacterKey(
                    cap: cap,
                    alternates: index == 0 ? firstKeyAlternates : [],
                    phoneKey: true, phoneSideKey: true,
                    titleSize: Self.t9QuickSymbolTitleSize,
                    onSelect: { handleKey($0.action) }
                )
                .frame(height: t9RailSlotHeight(metrics))
                .accessibilityHint(
                    index == 0 && !firstKeyAlternates.isEmpty
                        ? "长按输入更多符号" : "")
            }
        }
        .buttonStyle(KeyboardPressStyle())
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
    private func t9ReadingChoices(_ metrics: PhoneKeypadMetrics) -> some View {
        if controller.snapshot.isComposing {
            let displayed = displayedT9RailChoices
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
        let keys = t9AuxiliaryKeys(position)
        let spans = PhoneKeypadMetrics.slotSpans(
            keyCount: keys.count,
            rowCount: PhoneKeypadMetrics.mainRowCount)
        let slots = metrics.railSlots(position == .leading ? .leading : .trailing, spans: spans)
        return ScrollView(.vertical) {
            LazyVStack(spacing: CGFloat(metrics.spacing)) {
                if position == .leading { t9ReadingChoices(metrics) }
                ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                    definitionKey(key, id: "\(position.rawValue)-\(index)")
                        .frame(height: CGFloat(slots[index].height))
                }
            }
            .buttonStyle(KeyboardPressStyle())
        }
        .sharpCandidateScrollEdges()
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
                                    definitionRow(row, id: "row-\(index)", spacing: CGFloat(metrics.spacing))
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
    private var phoneSymbolMainRows: [[KeyCap]] {
        let digits = symbolRows.first?.caps ?? []
        return (0..<3).map { row in
            Array(digits.dropFirst(row * 3).prefix(3))
        }
    }

    private var phoneSymbolRailCaps: [KeyCap] {
        SymbolPageTable.phoneNumericRail(ascii: controller.usesASCIIPunctuation)
    }

    var phoneSymbolKeypad: some View {
        StablePhoneKeypadShell(
            trailingSpansControlRow: isBuiltinPhonePad,
            leading: { metrics in
                // The 123 punctuation rail keeps its original reachability: this page has no first-key cycling, so extra punctuation is still reached by long press.
                fixedPhoneSymbolRail(
                    phoneSymbolRailCaps, metrics: metrics,
                    firstKeyAlternates: Array(phoneSymbolRailCaps.dropFirst(3)))
            },
            main: { metrics in
                VStack(spacing: CGFloat(metrics.spacing)) {
                    if showsAllCandidates && !controller.snapshot.candidates.isEmpty {
                        expandedCandidates
                    } else {
                        ForEach(Array(phoneSymbolMainRows.enumerated()), id: \.offset) { _, caps in
                            WeightedKeyRow(caps: caps, alternates: alternates) { handleKey($0.action) }
                                .frame(height: CGFloat(metrics.rowHeight))
                        }
                    }
                }
            },
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
        return StablePhoneKeypadShell(
            trailingSpansControlRow: usesFixedEditingRail,
            leading: { metrics in
                phoneSymbolCategoryRail(categories, open: open.id, metrics: metrics)
            },
            main: { metrics in
                let columns = open.columns
                let rows = stride(from: 0, to: open.caps.count, by: columns).map {
                    Array(open.caps[$0..<min($0 + columns, open.caps.count)])
                }
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: CGFloat(metrics.spacing)) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, caps in
                            // A short last row keeps the grid's cell width.
                            GeometryReader { geometry in
                                let spacing = CGFloat(metrics.spacing)
                                let cell = (geometry.size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
                                HStack(spacing: 0) {
                                    // No long press here: every form a key could offer has a
                                    // cell of its own in some category.
                                    WeightedKeyRow(caps: caps, showsKeyPreview: true) { cap in
                                        if handleKey(cap.action), case .literal(let text) = cap.action {
                                            pendingSymbolUses.append(text)
                                            if !symbolPageLocked {
                                                page = controller.hostPreferredInput == .numeric ? .numeric : .letters
                                            }
                                        }
                                    }
                                    .frame(width: cell * CGFloat(caps.count) + spacing * CGFloat(caps.count - 1))
                                    Spacer(minLength: 0)
                                }
                            }
                            .frame(height: CGFloat(metrics.rowHeight))
                            .environment(\.keyboardKeyHeight, CGFloat(metrics.rowHeight))
                        }
                    }
                }
                .sharpCandidateScrollEdges()
                // A new category starts at its top.
                .id(open.id)
            },
            trailing: { metrics in
                if usesFixedEditingRail { t9FixedEditingRail(metrics) } else { t9Rail(.trailing, metrics: metrics) }
            },
            bottom: { metrics in
                phoneControlRow(metrics)
            }
        )
        // Every visit opens on 常用. Also picks up library edits made in the app
        // and recents from the symbol panel.
        .onAppear {
            phoneSymbolCategoryID = SymbolPageTable.commonCategoryID
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
    private var phoneSymbolCategories: [SymbolPageTable.PhoneSymbolCategory] {
        let catalog = symbolLibrary.catalog
        return SymbolPageTable.phoneSymbolCategories(
            ascii: controller.isEnglishMode || controller.usesASCIIPunctuation,
            recents: symbolLibrary.recents.map(\.text),
            library: catalog.orderedCategories.map { category in
                SymbolPageTable.LibraryCategory(
                    id: category.id, title: category.name,
                    symbols: catalog.items(in: category.id).map(\.text))
            })
    }

    /// Three and a half categories per main-area height, each taller than the minimum
    /// touch target; the cut-off one shows the list scrolls to the rest. The open one
    /// is marked, like the rail's applied reading choice.
    private func phoneSymbolCategoryRail(
        _ categories: [SymbolPageTable.PhoneSymbolCategory], open: String,
        metrics: PhoneKeypadMetrics
    ) -> some View {
        let slot = (CGFloat(metrics.mainHeight) - CGFloat(metrics.spacing) * 3) / 3.5
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                phoneSymbolCategoryList(categories, open: open, slot: slot, spacing: CGFloat(metrics.spacing))
            }
            // A tab chosen at the cut-off edge scrolls fully into view; a tab
            // already visible stays put.
            .onChange(of: open) { _, id in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id) }
            }
        }
        .sharpCandidateScrollEdges()
        .background {
            RoundedRectangle(cornerRadius: appearance.skin.keycap.cornerRadius)
                .fill(appearance.color("control"))
                .padding(.horizontal, appearance.skin.spacing.visualInsetX)
                .padding(.vertical, appearance.skin.spacing.visualInsetY)
        }
    }

    private func phoneSymbolCategoryList(
        _ categories: [SymbolPageTable.PhoneSymbolCategory], open: String,
        slot: CGFloat, spacing: CGFloat
    ) -> some View {
        VStack(spacing: spacing) {
            ForEach(categories, id: \.id) { category in
                let selected = category.id == open
                Button {
                    emitKeyFeedback()
                    phoneSymbolCategoryID = category.id
                } label: {
                    Text(category.title)
                        .font(appearance.font(KeyboardToolsStyle.categoryRailTitleSize))
                        .foregroundStyle(
                            selected
                                ? appearance.accentForeground
                                : Color(uiColor: appearance.text(on: "control"))
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: slot)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: appearance.skin.keycap.cornerRadius)
                                    .fill(appearance.color("key"))
                                    .padding(.horizontal, appearance.skin.spacing.visualInsetX + 2)
                                    .padding(.vertical, appearance.skin.spacing.visualInsetY + 2)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(KeyboardPressStyle())
                .accessibilityLabel("\(category.title)符号")
                .accessibilityAddTraits(selected ? .isSelected : [])
                .id(category.id)
            }
        }
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

    /// The bundled T9's authored trailing column, as on the system / mainstream
    /// pinyin 9-key pads: Delete (row 0), "重输" (row 1) and Return/Confirm across
    /// row 2 and the control row, in the bottom-right corner.
    ///
    /// Design constraints:
    ///  - No pinyin-cycle key on the right; real readings are picked directly in the left scrolling rail.
    ///  - The bottom row does not repeat a Return/Confirm (the bundled 9-key's
    ///    `KeyboardControlPolicy.includesBottomEnter` is false): confirm appears only once, here.
    /// Only reachable for the bundled definition.
    private func t9FixedEditingRail(_ metrics: PhoneKeypadMetrics) -> some View {
        let slots = metrics.railSlots(.trailing, spans: PhoneKeypadRailPolicy.bundledTrailingSpans)
        return VStack(spacing: CGFloat(metrics.spacing)) {
            RepeatingDeleteKey { isRepeating in handleKey(.backspace, emitFeedback: !isRepeating) }
                .frame(height: CGFloat(slots[0].height))
                .accessibilityLabel("删除")
            AlternateCharacterKey(
                cap: KeyCap(id: "t9-reset", title: "重输", action: .backspace),
                alternates: [], visualRole: "control",
                titleSize: appearance.controlTextSize
            ) { _ in
                keyFeedbackAfterEffect { _ = controller.discardComposition() }
            }
            .disabled(!controller.snapshot.isComposing)
            .frame(height: CGFloat(slots[1].height))
            .accessibilityLabel("重输")
            .accessibilityHint("清空当前输入")
            ReturnKey(title: controller.returnKeyTitle, isEnabled: controller.isReturnKeyEnabled) {
                handleDefinitionAction($0.action)
            }
            .frame(height: CGFloat(slots[2].height))
        }
    }
}
