import KeyboardCore
import LayoutKit
import SwiftUI

extension KeyboardPanelView {
    private var compositionMemoKey: PageResolutionMemo.CompositionKey {
        PageResolutionMemo.CompositionKey(
            controller: ObjectIdentifier(controller), registry: layoutRegistry,
            inputsRevision: controller.definitionInputsRevision)
    }

    /// The pairing for the running input method × layout (keyed like `UserKeyboard.id`).
    var selectedComposition: KeyboardComposition? {
        pageMemo.composition(for: compositionMemoKey) {
            layoutRegistry?.compositions["\(controller.selectedSchemaID):\(controller.layout.rawValue)"]
        }
    }

    /// The page kind this visit can take from a pairing. The ABC page only applies in English
    /// mode: Chinese input keeps its own configured key area.
    private var pairedPageKind: KeyboardPageKind? {
        switch page {
        case .letters: return controller.isEnglishMode ? .english : nil
        case .numeric: return .numeric
        case .symbols: return .symbols
        }
    }

    private var pairedPageMemoKey: PageResolutionMemo.PairedKey {
        PageResolutionMemo.PairedKey(
            composition: compositionMemoKey, kind: pairedPageKind,
            needsSwitchEntry: systemKeyboardSwitch != nil)
    }

    private func pairedPage(for key: PageResolutionMemo.PairedKey) -> PageResolutionMemo.Paired {
        pageMemo.paired(for: key) {
            guard let kind = key.kind, let composition = selectedComposition,
                let page = layoutRegistry?.page(id: composition.pageID(for: kind))
            else { return PageResolutionMemo.Paired(page: nil, missingSwitchEntry: false) }
            // An authored page without a reachable system-switch entry would hide the only way to
            // another keyboard when the host needs one.
            return PageResolutionMemo.Paired(
                page: page,
                missingSwitchEntry: key.needsSwitchEntry && page.chrome != nil && !page.hasInputModeSwitchKey)
        }
    }

    /// The page the current pairing selects for this visit, before any automatic fallback. Used
    /// both for rendering and for the page-local symbol default; never recurse through
    /// `pageResolution` here (the resolution itself reads the effective symbol state).
    var selectedPairedPage: KeyboardPageDefinition? { pairedPage(for: pairedPageMemoKey).page }

    /// The page's declared initial symbol branch, if any.
    var selectedPageDefaultSymbolMarks: KeyboardNumericMarks? {
        selectedPairedPage?.defaultSymbolMarks
    }

    /// Effective symbol language for this visit: panel override > selected page default > the
    /// controller's real punctuation state. Runtime-only; never written back to the controller.
    var effectiveSymbolMarks: KeyboardNumericMarks {
        if let symbolMarksOverride { return symbolMarksOverride }
        if let selectedPageDefaultSymbolMarks { return selectedPageDefaultSymbolMarks }
        return controller.usesASCIIPunctuation ? .ascii : .chinese
    }

    var effectiveUsesASCIIPunctuation: Bool { effectiveSymbolMarks == .ascii }

    /// Flip only the panel symbol branch. Leaves the page, symbol lock, category selection, input
    /// mode and current composition untouched; the next real symbol key keeps the normal commit
    /// semantics.
    func togglePanelSymbolMarks() {
        symbolMarksOverride = effectiveSymbolMarks == .ascii ? .chinese : .ascii
    }

    func clearSymbolMarksOverride() {
        symbolMarksOverride = nil
    }

    /// What the key area draws for the page the pairing selects: an authored page, the built-in
    /// 123 page (language marks, or a phone keypad's number pad), the built-in symbol page, or the
    /// built-in letters page. The single decision point for every page branch.
    private var pageFacts: PageResolutionMemo.Resolution {
        let pairedKey = pairedPageMemoKey
        let key = PageResolutionMemo.ResolutionKey(
            paired: pairedKey, usesASCIIPunctuation: effectiveUsesASCIIPunctuation,
            mainLayoutIsPhoneKeypad: usesPhoneDefinition)
        return pageMemo.resolution(for: key) {
            guard let kind = pairedKey.kind else {
                return PageResolutionMemo.Resolution(resolution: .builtIn, readsComposition: false)
            }
            let paired = pairedPage(for: pairedKey)
            // The stored page and pairing stay untouched; the editor is where a globe key gets added.
            let resolution =
                paired.missingSwitchEntry
                ? .builtIn
                : KeyboardPageResolver.resolve(
                    page: paired.page, kind: kind,
                    input: .init(
                        usesASCIIPunctuation: key.usesASCIIPunctuation,
                        mainLayoutIsPhoneKeypad: key.mainLayoutIsPhoneKeypad))
            return PageResolutionMemo.Resolution(
                resolution: resolution,
                readsComposition: resolution.page.map(Self.pageReadsComposition) ?? false)
        }
    }

    var pageResolution: KeyboardPageResolution { pageFacts.resolution }

    /// Whether the authored page draws a live Return title or clear-input enabled state.
    var pageDefinitionReadsComposition: Bool { pageFacts.readsComposition }

    /// True when the paired authored page is skipped for this visit because it has no reachable
    /// system-switch entry while the host needs one. The saved pairing is untouched; this only
    /// lets the panel tell the user why a built-in page appeared.
    var authoredPageMissingInputModeSwitchFallback: Bool {
        pairedPage(for: pairedPageMemoKey).missingSwitchEntry
    }

    /// The saved pairing's main layout, else the same default the host app shows for this keyboard.
    var preferredDefinitionID: String? {
        if let id = selectedComposition?.mainLayoutID { return id }
        guard let builtin = LayoutInput.Builtin(rawValue: controller.layout.rawValue) else { return nil }
        let key = KeyboardCompositionKey(inputMethodID: controller.selectedSchemaID, layout: builtin)
        return layoutRegistry?.defaultMainLayoutID(for: key) ?? BuiltinLayouts.preset(for: builtin).id
    }

    /// The authored page to draw, or nil when the built-in page area draws this page.
    var pageDefinition: KeyboardPageDefinition? { pageResolution.page }

    /// The split actually rendered here. Activation is settled once against the whole keyboard
    /// width (never per row or per rail); an inactive split becomes nil, so every renderer draws
    /// one continuous row with a single space and no gutter.
    var activeSplit: ActiveLayoutSplit? {
        KeyboardPanelRules.activeSplit(
            main: activeDefinition?.split, mainWidth: widthBox.mainSplitWidth,
            showsMainLetters: page == .letters && !controller.isEnglishMode,
            pageSplit: pageDefinition?.split, contentWidth: widthBox.contentWidth)
    }

    /// Tells the user why the built-in page replaced their authored one for this visit: the page
    /// still lacks the system-switch entry the host requires. Reuses the transient key hint.
    func showAuthoredPageNeedsGlobeHint() {
        let token = UUID()
        layoutHintToken = token
        layoutHintName = "这一页缺少地球键，先显示默认页面"
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if layoutHintToken == token { layoutHintName = nil }
        }
    }

    /// A category grid carries its own split; settle it against the same real keyboard width so
    /// the inner grid and the outer page agree on whether the surface is split.
    func resolvedCategorySplit(_ categorySplit: LayoutSplitConfiguration?) -> ActiveLayoutSplit? {
        ActiveLayoutSplit.resolving(nested: categorySplit, parent: activeSplit, width: widthBox.contentWidth)
    }

    func authoredPage(_ definition: KeyboardPageDefinition) -> some View {
        KeyboardPageRows(
            page: definition, split: activeSplit, showsGlobe: systemKeyboardSwitch != nil,
            key: { key, row, index in
                authoredPageKey(key, id: "page-\(definition.id)-\(row)-\(index)", kind: definition.kind)
            },
            shift: {
                ShiftKey(
                    state: controller.shiftState, isEnglishMode: true,
                    tap: { keyFeedbackAfterEffect { controller.handleShiftTap() } },
                    doubleTap: { keyFeedbackAfterEffect { controller.handleShiftDoubleTap() } })
            },
            delete: {
                RepeatingDeleteKey { repeating in handleKey(.backspace, emitFeedback: !repeating) }
            })
    }

    @ViewBuilder
    func authoredPageKey(
        _ key: LayoutKey, id: String, kind: KeyboardPageKind, onSelect: ((KeyAction, Bool) -> Void)? = nil
    ) -> some View {
        if key.action.type != .literal {
            definitionKey(key, id: id, onAction: onSelect)
        } else {
            let cap = pageCap(key, id: id, kind: kind)
            // Authored long-press lists are user data: keep every declared option even in an
            // ASCII field, and resolve only explicit literal pairs against the effective branch.
            let options = (key.longPress ?? []).enumerated().map { index, option in
                pageCap(
                    LayoutKey(label: option.label, action: option.action),
                    id: "\(id)-option-\(index)", kind: kind, alternate: true)
            }
            // pageCap can only build an engine face, so a page-level UI option would otherwise be
            // flattened to .cycleLayout by keyAction. Keep the original action by the stable cap id
            // and dispatch it through the page/controller layer; literal/code options and the
            // English single-letter heuristic stay on the existing pageCap path.
            let pageUIOptions: [String: LayoutAction] = Dictionary(
                uniqueKeysWithValues: (key.longPress ?? []).enumerated().compactMap {
                    index, option -> (String, LayoutAction)? in
                    guard option.action.type.isPageUI else { return nil }
                    return ("\(id)-option-\(index)", option.action)
                })
            AlternateCharacterKey(cap: cap, alternates: options, showsKeyPreview: true) { selected in
                if let action = pageUIOptions[selected.id] {
                    performAuthoredPageAction(action, isAlternate: true)
                } else if let onSelect {
                    onSelect(selected.action, true)
                } else {
                    handleKey(selected.action)
                }
            }
        }
    }

    private func pageCap(_ key: LayoutKey, id: String, kind: KeyboardPageKind, alternate: Bool = false) -> KeyCap {
        KeyboardPanelRules.pageCap(
            key, id: id, kind: kind, alternate: alternate,
            usesASCIIPunctuation: effectiveUsesASCIIPunctuation, shiftActive: controller.shiftState.isActive)
    }
}

// MARK: - Authored pages (chrome != nil)

extension KeyboardPanelView {
    /// A page that carries authored chrome draws ONLY its data: no Shift, Delete, footer, space or
    /// rail is ever synthesized for a deleted or empty region.
    ///
    /// The page renders inside the key-area gate, so the parts that change without a token change
    /// re-render on their own model: the expanded candidate list on the controller, the category
    /// grid and rail on the symbol library (recents load after the page opens).
    @ViewBuilder
    func authoredChromePage(_ definition: KeyboardPageDefinition) -> some View {
        // A categorized page keeps browser rows as backup data; the presentation decides.
        if definition.symbolPresentation == .categorized {
            KeyboardAuthoredPageView(
                page: definition, split: activeSplit,
                state: authoredPageState(definition), actions: authoredPageActions(),
                expandedCandidates: authoredExpandedCandidates(),
                categoryMain: { metrics in
                    ObservedModelSlot(model: symbolLibrary) { authoredCategoryMain(definition, metrics: metrics) }
                },
                categoryLeading: { metrics in
                    ObservedModelSlot(model: symbolLibrary) { authoredCategoryLeading(metrics) }
                }
            )
            .onAppear { authoredCategoryAppear() }
            .onDisappear { authoredCategoryDisappear() }
        } else {
            KeyboardAuthoredPageView(
                page: definition, split: activeSplit,
                state: authoredPageState(definition), actions: authoredPageActions(),
                expandedCandidates: authoredExpandedCandidates(),
                categoryMain: { _ in EmptyView() },
                categoryLeading: { _ in EmptyView() }
            )
        }
    }

    /// The expanded candidate list replaces the authored main area, as on every built-in page.
    /// Whether it shows is part of the gate token; its content follows every controller publish.
    func authoredExpandedCandidates() -> AnyView? {
        guard showsExpandedCandidates else { return nil }
        return AnyView(ObservedModelSlot(model: controller) { expandedCandidates })
    }

    var showsExpandedCandidates: Bool { showsAllCandidates && !controller.snapshot.candidates.isEmpty }

    func authoredPageState(_ definition: KeyboardPageDefinition) -> KeyboardPageAuthoredState {
        KeyboardPageAuthoredState(
            page: page, kind: definition.kind, isEnglishMode: controller.isEnglishMode,
            shiftState: controller.shiftState, returnTitle: controller.returnKeyTitle,
            isReturnEnabled: controller.isReturnKeyEnabled, symbolLocked: symbolPageLocked,
            isComposing: controller.snapshot.isComposing, hasGlobe: systemKeyboardSwitch != nil,
            isPhoneStyled: !(definition.chrome?.trailing.isEmpty ?? true),
            usesASCIIPunctuation: effectiveUsesASCIIPunctuation,
            usesCategorySymbolPage: definition.symbolPresentation == .categorized)
    }

    func authoredPageActions() -> KeyboardPageAuthoredActions {
        KeyboardPageAuthoredActions(
            perform: { _, action, alternate in
                performAuthoredPageAction(action, isAlternate: alternate)
            },
            performShiftDoubleTap: { _ in keyFeedbackAfterEffect { controller.handleShiftDoubleTap() } },
            moveCursor: cursorMovement,
            systemKeyboardSwitch: systemKeyboardSwitch,
            spaceLayoutName: controller.isEnglishMode ? nil : currentKeyboardTitle,
            spaceHintName: layoutHintName,
            spaceHintToken: layoutHintToken,
            languageMenuAlternates: userKeyboardAlternates,
            handleLanguageMenu: { cap in handleLanguageMenuCap(cap) },
            // A repeating delete gives feedback on its first step only, as the native key does.
            performNativeDelete: { _, repeating in
                handleKey(.backspace, emitFeedback: !repeating)
            })
    }

    /// Page UI actions stay in the UI/controller layer and never become an engine KeyAction;
    /// only modeSwitch keeps its engine layout cycling.
    func performAuthoredPageAction(_ action: LayoutAction, isAlternate: Bool = false) {
        switch action.type {
        case .shift:
            keyFeedbackAfterEffect { controller.handleShiftTap() }
        case .pageSwitch:
            guard let target = action.pageSwitchTarget else { return }
            emitKeyFeedback()
            switch target {
            case .letters: page = .letters
            case .numeric: page = .numeric
            case .symbols: page = .symbols
            }
            showsAllCandidates = false
        case .languageSwitch:
            switch controlPolicy.languageAction(for: action.languageSwitchBehavior) {
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
        case .symbolLock:
            emitKeyFeedback()
            symbolPageLocked.toggle()
        case .clearInput:
            keyFeedbackAfterEffect { _ = controller.discardComposition() }
        case .modeSwitch:
            handleDefinitionAction(.cycleLayout)
        case .space:
            handleKey(.space)
        case .backspace:
            handleKey(.backspace)
        case .enter:
            handleKey(.enter)
        case .literal:
            // Explicit pairs resolve the effective branch before the English single-letter
            // semantics; an English page may pair arbitrary text (a/★ is a literal, never A).
            if let value = action.literalValue(usesASCIIPunctuation: effectiveUsesASCIIPunctuation) {
                if !action.isPairedLiteral, let letter = action.singleASCIILetter,
                    pageDefinition?.kind == .english
                {
                    _ = handleKey(isAlternate ? .letterVariant(letter) : .code(letter.lowercased()))
                } else {
                    _ = handleKey(.literal(value))
                }
            }
        case .globe:
            controller.handle(.switchKeyboard)
        case .code:
            break
        }
    }

    // MARK: Categorized authored page

    private var authoredOpenCategory: SymbolPageTable.PhoneSymbolCategory? {
        let categories = phoneSymbolCategories
        return categories.first { $0.id == phoneSymbolCategoryID } ?? categories.first
    }

    private func authoredCategoryAppear() {
        phoneSymbolCategoryID = phoneSymbolCategories.first?.id ?? phoneSymbolCategoryID
        symbolLibrary.reload()
    }

    private func authoredCategoryDisappear() {
        for text in pendingSymbolUses { symbolLibrary.recordUse(text) }
        pendingSymbolUses = []
    }

    @ViewBuilder
    func authoredCategoryMain(_ definition: KeyboardPageDefinition, metrics: KeyboardAuthoredPageMetrics) -> some View {
        if let open = authoredOpenCategory {
            let categorySplit = resolvedCategorySplit(open.split)
            KeyboardCategoryGrid(keys: open.keys, columns: open.columns, split: categorySplit) { key, index in
                if open.authoredKeys != nil {
                    authoredCategoryItem(key, definition: definition)
                } else {
                    AlternateCharacterKey(cap: open.caps[index], alternates: [], showsKeyPreview: true) { cap in
                        recordCategoryAction(cap.action)
                    }
                }
            }
            .id(open.id)
        } else {
            Color.clear
        }
    }

    /// A category's authored content key keeps the same faces and titleMode semantics as any other
    /// page key; only the dispatch path differs (recent symbols and the symbol-lock return).
    func authoredCategoryItem(_ key: LayoutKey, definition: KeyboardPageDefinition) -> some View {
        let path = KeyboardPageKeyPath.chrome(.bottom, key: 0)
        let table = KeyboardPageAuthoredActionTable(singleKey: key, path: path)
        // Reuse the page actions so native space cursor-pan and the language long-press menu stay
        // intact; only the action sink changes to the category recorder.
        var actions = authoredPageActions()
        actions.perform = { _, action, alternate in
            performCategoryItemAction(action, isAlternate: alternate)
        }
        actions.performNativeDelete = { _, repeating in
            recordCategoryAction(.backspace, emitFeedback: !repeating)
        }
        return KeyboardAuthoredPageKey(
            key: key, path: path, state: authoredPageState(definition),
            actions: actions, actionTable: table)
    }

    func performCategoryItemAction(_ action: LayoutAction, isAlternate: Bool = false) {
        switch action.type {
        case .shift:
            keyFeedbackAfterEffect { controller.handleShiftTap() }
        case .pageSwitch, .languageSwitch, .symbolLock, .clearInput:
            performAuthoredPageAction(action, isAlternate: isAlternate)
        case .modeSwitch:
            recordCategoryAction(.cycleLayout)
        case .literal:
            if let value = action.literalValue(usesASCIIPunctuation: effectiveUsesASCIIPunctuation) {
                recordCategoryAction(.literal(value))
            }
        case .space, .backspace, .enter, .globe:
            recordCategoryAction(keyAction(action))
        case .code:
            break
        }
    }

    @ViewBuilder
    func authoredCategoryLeading(_ metrics: KeyboardAuthoredPageMetrics) -> some View {
        let categories = phoneSymbolCategories
        if let open = categories.first(where: { $0.id == phoneSymbolCategoryID }) ?? categories.first {
            KeyboardAuthoredCategoryRail(
                categories: categories, open: open.id, mainHeight: CGFloat(metrics.rowsHeight),
                spacing: CGFloat(KeyboardAuthoredPageMetrics.spacing),
                onSelect: { id in
                    emitKeyFeedback()
                    phoneSymbolCategoryID = id
                })
        }
    }
}

/// Pairing and page facts, memoized on exactly the values they read (compare
/// `DefinitionResolutionMemo`). The panel reads them dozens of times per render; resolving them
/// built a composition key string, searched the registry and scanned the page's keys per read.
final class PageResolutionMemo {
    struct CompositionKey: Equatable {
        let controller: ObjectIdentifier
        let registry: LayoutRegistry?
        /// Assignment count of the controller's `layout` / `selectedSchemaID`.
        let inputsRevision: UInt64
    }

    struct PairedKey: Equatable {
        let composition: CompositionKey
        let kind: KeyboardPageKind?
        let needsSwitchEntry: Bool
    }

    struct Paired {
        let page: KeyboardPageDefinition?
        /// The authored page lacks the system-switch entry the host requires, so the built-in
        /// page stands in for this visit.
        let missingSwitchEntry: Bool
    }

    struct ResolutionKey: Equatable {
        let paired: PairedKey
        let usesASCIIPunctuation: Bool
        let mainLayoutIsPhoneKeypad: Bool
    }

    struct Resolution {
        let resolution: KeyboardPageResolution
        let readsComposition: Bool
    }

    private var compositionKey: CompositionKey?
    private var composition: KeyboardComposition?
    private var pairedKey: PairedKey?
    private var paired: Paired?
    private var resolutionKey: ResolutionKey?
    private var resolved: Resolution?

    func composition(for key: CompositionKey, resolve: () -> KeyboardComposition?) -> KeyboardComposition? {
        if compositionKey == key { return composition }
        let value = resolve()
        compositionKey = key
        composition = value
        return value
    }

    func paired(for key: PairedKey, resolve: () -> Paired) -> Paired {
        if let paired, pairedKey == key { return paired }
        let value = resolve()
        pairedKey = key
        paired = value
        return value
    }

    func resolution(for key: ResolutionKey, resolve: () -> Resolution) -> Resolution {
        if let resolved, resolutionKey == key { return resolved }
        let value = resolve()
        resolutionKey = key
        resolved = value
        return value
    }
}

/// Re-runs `content` whenever `model` publishes, even while an enclosing `KeyAreaRenderGate`
/// skips its body. `content` must read live state (the controller, `@State` storage).
struct ObservedModelSlot<Model: ObservableObject, Content: View>: View {
    @ObservedObject var model: Model
    @ViewBuilder let content: () -> Content

    var body: some View { content() }
}
