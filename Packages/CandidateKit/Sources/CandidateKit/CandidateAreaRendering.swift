import KeyboardCore
import SwiftUI
import os

#if canImport(UIKit)
    import UIKit
#else
    import AppKit
#endif

#if canImport(UIKit)
    private typealias CandidatePlatformColor = UIColor
#else
    private typealias CandidatePlatformColor = NSColor
#endif

extension CandidatePlatformColor {
    fileprivate static var controlAccent: CandidatePlatformColor {
        #if canImport(UIKit)
            return UIColor { $0.userInterfaceStyle == .dark ? UIColor.white : UIColor.darkGray }
        #else
            return NSColor.controlAccentColor
        #endif
    }
    fileprivate static var windowBackground: CandidatePlatformColor {
        #if canImport(UIKit)
            return UIColor.systemBackground
        #else
            return NSColor.windowBackgroundColor
        #endif
    }
}

// MARK: - Renderer extension point (source-level; user JSON can only choose parameters within the schema)

/// A candidate area renderer: provides the two views, the collapsed strip (including the composition row layout rules) and the expanded area.
/// The default implementation ships with the package (`DefaultCandidateAreaRenderer`); downstream developers register
/// their own at compile time, replacing rendering without touching EngineBackend/InputSession.
public protocol CandidateAreaRendering {
    /// Renderer ID (referenced by host code; v1 registers only "default" with the package).
    static var rendererID: String { get }
    /// Collapsed candidate strip (including the composition row and paging/expand controls).
    @MainActor func collapsedView(context: CandidateAreaContext) -> AnyView
    /// Expanded current page candidates (used when replacing the main key area).
    @MainActor func expandedView(context: CandidateAreaContext) -> AnyView
}

/// Renderer descriptor registered as a type-erased view (keeps protocol generics from spreading to the host).
public struct CandidateRendererDescriptor: Sendable {
    public let id: String
    public let makeCollapsed: @MainActor @Sendable (CandidateAreaContext) -> AnyView
    public let makeExpanded: @MainActor @Sendable (CandidateAreaContext) -> AnyView
    public init(
        id: String,
        makeCollapsed: @escaping @MainActor @Sendable (CandidateAreaContext) -> AnyView,
        makeExpanded: @escaping @MainActor @Sendable (CandidateAreaContext) -> AnyView
    ) {
        self.id = id
        self.makeCollapsed = makeCollapsed
        self.makeExpanded = makeExpanded
    }
}

/// Compile-time registry. App/extension main each register the renderers they need at startup; thread safety is
/// just a lightweight lock, and registration happens before rendering.
public enum CandidateRendererRegistry {
    private static let renderers = OSAllocatedUnfairLock(initialState: [String: CandidateRendererDescriptor]())

    public static func register(_ descriptor: CandidateRendererDescriptor) {
        renderers.withLock { $0[descriptor.id] = descriptor }
    }

    /// An unknown ID falls back to default (an unregistered renderer referenced by the host neither crashes nor renders nothing).
    @available(macOS 14.0, iOS 17.0, *)
    public static func renderer(id: String) -> CandidateRendererDescriptor {
        renderers.withLock { renderers in
            renderers[id] ?? renderers[DefaultCandidateAreaRenderer.rendererID] ?? .plainText
        }
    }

    public static var availableIDs: [String] {
        renderers.withLock { Array($0.keys).sorted() }
    }
}

// MARK: - Default renderer (the current UX as a parameterized implementation; the skin is injected via the environment)

/// Default renderer (macOS 14+ / iOS 17+):
///   - the composition row shows per `compositionRow.visible` (default: hidden without input);
///   - collapsed = a single horizontal row + paging/expand control placement per config;
///   - expanded current page = list/grid (columns/spacing/long-sentence rows configurable);
///   - colors/sizes come from the skin environment injected by the host (`CandidateSkinToken`);
///     this renderer carries no colors of its own, avoiding a third skin.
@available(macOS 14.0, iOS 17.0, *)
public struct DefaultCandidateAreaRenderer: CandidateAreaRendering {
    public static let rendererID = "default"
    public init() {}

    @MainActor public func collapsedView(context: CandidateAreaContext) -> AnyView {
        AnyView(DefaultCollapsedCandidateBar(context: context))
    }

    @MainActor public func expandedView(context: CandidateAreaContext) -> AnyView {
        AnyView(DefaultExpandedCandidates(context: context))
    }
}

// MARK: Skin bridge (the host brings in KeyboardAppearance values; values only, no types)

/// Color/font values the renderer needs. Resolved from SkinKit by the host and injected.
public struct CandidateSkinToken: Sendable {
    public var candidateColor: Color
    public var secondaryColor: Color
    public var accentColor: Color
    public var panelColor: Color
    public var fontFamily: String  // system/rounded/serif/monospaced
    public var fontWeight: String  // regular/medium/semibold
    public init(
        candidateColor: Color, secondaryColor: Color, accentColor: Color,
        panelColor: Color, fontFamily: String = "system", fontWeight: String = "medium"
    ) {
        self.candidateColor = candidateColor
        self.secondaryColor = secondaryColor
        self.accentColor = accentColor
        self.panelColor = panelColor
        self.fontFamily = fontFamily
        self.fontWeight = fontWeight
    }
}

private struct CandidateSkinTokenKey: EnvironmentKey {
    static let defaultValue = CandidateSkinToken(
        candidateColor: .primary, secondaryColor: .secondary,
        accentColor: Color(CandidatePlatformColor.controlAccent),
        panelColor: Color(CandidatePlatformColor.windowBackground))
}

extension EnvironmentValues {
    /// Skin values consumed by the default renderer; the host injects them in the keyboard environment (same source, SkinKit).
    public var candidateSkinToken: CandidateSkinToken {
        get { self[CandidateSkinTokenKey.self] }
        set { self[CandidateSkinTokenKey.self] = newValue }
    }
}

extension CandidateSkinToken {
    func font(_ size: Double) -> Font {
        let weight: Font.Weight = fontWeight == "semibold" ? .semibold : fontWeight == "regular" ? .regular : .medium
        switch fontFamily {
        case "rounded": return .system(size: size, weight: weight, design: .rounded)
        case "serif": return .system(size: size, weight: weight, design: .serif)
        case "monospaced": return .system(size: size, weight: weight, design: .monospaced)
        default: return .system(size: size, weight: weight)
        }
    }
}

// MARK: Collapsed strip

@available(macOS 14.0, iOS 17.0, *)
private struct CandidateLoadingActions: ViewModifier {
    let context: CandidateAreaContext

    @ViewBuilder
    func body(content: Content) -> some View {
        if context.hasMoreEntries {
            content.accessibilityAction(
                named: Text(
                    context.visibleEntries == nil && context.browser.needsEarlier
                        ? "加载更早候选" : "加载更多候选")
            ) {
                context.actions.perform(.loadMore)
            }
        } else {
            content
        }
    }
}

@available(macOS 14.0, iOS 17.0, *)
extension CandidateAreaContext {
    var hasMoreEntries: Bool { visibleHasMore ?? browser.hasMore }
    var entryFrontier: Int? { visibleFrontier ?? browser.nextPageToLoad }
    /// Accumulated candidates for continuous display: used when the host has fed `browser` (cross-page), otherwise falls back to the single-page snapshot.
    var displayEntries: [BrowserCandidate] {
        if let visibleEntries { return visibleEntries }
        if !browser.isEmpty { return browser.entries }
        return state.candidates.map {
            BrowserCandidate(pageIndex: state.pageIndex, pageLocalIndex: $0.index, candidate: $0)
        }
    }

    /// The select action carries real page ownership; the host commits by absolute index from it and never uses a concatenated position as an index.
    func selectAction(_ entry: BrowserCandidate) -> CandidateAreaAction {
        .selectOnPage(page: entry.pageIndex, index: entry.pageLocalIndex)
    }

    func isHighlighted(_ entry: BrowserCandidate) -> Bool {
        entry.pageIndex == state.pageIndex && entry.pageLocalIndex == state.highlightedIndex
    }

    var scrollIdentity: CandidateScrollIdentity {
        CandidateScrollIdentity(
            generation: browser.generation, rawInput: state.rawInput,
            isFiltered: visibleEntries != nil,
            filteredLeadingEntryID: visibleEntries?.first?.id)
    }
}

/// When the candidate scroll position returns to the start (the strip to the far left, the expanded list to the top).
///
/// On a real composition change (`generation`: changes on every real state recomputation through the engine) or when the
/// front-end reading filter toggles, the old scroll offset is meaningless: keeping it would leave the new composition's
/// first candidate off screen. Read-only appends within one composition (loading forward, filling earlier pages) do **not**
/// reset, so the user is not pulled back to the start mid-scroll. Filter results only append, so the first item
/// distinguishes "switched to another reading" only while filtering.
struct CandidateScrollIdentity: Hashable {
    let generation: CandidateGeneration?
    let rawInput: String
    let isFiltered: Bool
    let filteredLeadingEntryID: String?
}

/// Fixed anchor of the scrolled content (the content view carries this id; resetting = scrolling to the content start).
private enum CandidateScrollAnchor: Hashable { case content }

@available(macOS 14.0, iOS 17.0, *)
private struct CandidateScrollReset: ViewModifier {
    let identity: CandidateScrollIdentity
    let proxy: ScrollViewProxy
    let anchor: UnitPoint

    func body(content: Content) -> some View {
        // Keep the ScrollView's identity (no rebuild, no transition, the tail
        // sentinel is not re-fired) and jump without animation.
        content.onChange(of: identity) {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(CandidateScrollAnchor.content, anchor: anchor)
            }
        }
    }
}

@available(macOS 14.0, iOS 17.0, *)
private struct DefaultCollapsedCandidateBar: View {
    let context: CandidateAreaContext
    @Environment(\.candidateSkinToken) private var skin

    private var state: CandidatePresentationState { context.state }
    private var bar: CandidateBarDefinition { context.bar }
    private var entries: [BrowserCandidate] { context.displayEntries }

    private var stripDefinition: CandidateBarDefinition.Collapsed { bar.collapsed }
    private var effectiveHeaderHeight: CGFloat {
        CGFloat(
            CandidateBarDefinition.Collapsed.effectiveHeight(
                stripDefinition.height, candidateSize: context.typography.candidateSize))
    }

    var body: some View {
        HStack(spacing: 0) {
            if context.visibleEntries == nil && context.browser.needsEarlier {
                let retrying = context.browser.hasIncompleteEarlierPage
                pageButton(
                    retrying ? "arrow.clockwise" : "chevron.left",
                    label: retrying ? "重试加载更早候选" : "加载更早候选",
                    disabled: false, action: .loadMore)
            }
            if context.isExpanded {
                Text("候选")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(skin.secondaryColor)
                    .padding(.leading, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
            } else {
                // Read-only entry for earlier pages (not engine paging): shown when unloaded pages exist before the real current
                // page; reads them by offset without changing the engine page/highlight/marked text. If the frontier is stopped on an
                // "incompletely read" earlier page, a retry icon and label tell the user they can retry read-only.
                if entries.isEmpty && context.visibleEntries == nil {
                    Text("继续输入，或按回车确认")
                        .font(.caption)
                        .foregroundStyle(skin.secondaryColor)
                        .frame(maxWidth: .infinity, minHeight: effectiveHeaderHeight, alignment: .leading)
                        .padding(.horizontal, 8)
                } else if !entries.isEmpty {
                    GeometryReader { geometry in
                        strip(width: geometry.size.width)
                    }
                }
            }
            // Scrolling loads naturally. A retry is shown only after an actual failed read.
            if context.visibleEntries == nil && context.browser.hasIncompletePage && !context.browser.needsEarlier {
                pageButton(
                    "arrow.clockwise", label: "重试加载候选",
                    disabled: false, action: .loadMore)
            }
            if bar.controls.showsExpand, !entries.isEmpty {
                pageButton(
                    context.isExpanded ? "chevron.down" : "chevron.up",
                    label: context.isExpanded ? "收起候选" : "展开候选",
                    disabled: false, action: context.isExpanded ? .collapse : .expand)
            }
        }
        .frame(height: effectiveHeaderHeight)
        // Same fixed header budget, immediate replacement: never retain the old
        // horizontal candidates alongside the expanded browser during a transition.
        // The candidate strip deliberately owns NO transition of its own: it stays
        // fully opaque; page changes do not animate either the candidate strip
        // or an ancestor key-area surface.
    }

    /// The collapsed strip of candidates. With few short candidates, cells are even-width and fill the row (no half-screen of
    /// blank space); otherwise they follow the **intrinsic text width**. A cell **may exceed the viewport**: a long candidate
    /// shows its full text in the same horizontal ScrollView, and **normal words are never shrunk/elided to fit a fixed screen width**.
    /// The paging/expand controls sit outside the scroll area, always visible and tappable; taps still resolve by the entry's page ownership (absolute).
    /// The tail sentinel triggers a **read-only** load of the next unloaded page by "composition identity + frontier": when
    /// content is shorter than one screen or scrolled to the loaded tail it keeps appending until earlier and last pages are covered.
    /// The sentinel id includes the composition identity, so a new composition with the same frontier retriggers too; the last page removes it to avoid an onAppear loop.
    @ViewBuilder
    private func strip(width: CGFloat) -> some View {
        let spacing = max(0, stripDefinition.cellSpacing)
        // Content has 2pt padding on each side (see `.padding(.horizontal, 2)` below), deducted from the available width.
        let available = max(0, width - 4)
        let layout = CandidateCollapsedFlow.layout(
            entries: entries, collapsed: stripDefinition,
            typography: context.typography, availableWidth: available,
            fillsAvailableWidth: stripDefinition.fillsAvailableWidth ?? true)
        // Candidate widths change as pages arrive; switching container types at
        // the overflow threshold remounts every cell and the load sentinel.
        // At rest the viewport ends on a cell boundary instead of halving a glyph.
        let viewport =
            layout.scrolls
            ? CandidateCollapsedFlow.wholeCellViewportWidth(
                cellWidths: layout.cellWidths,
                spacing: spacing, availableWidth: available) + 4
            : width
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                CollapsedCandidateRow(
                    context: context, entries: entries,
                    cellWidths: layout.cellWidths, spacing: spacing
                )
                .padding(.horizontal, 2)
                .frame(minWidth: viewport, alignment: .leading)
                .id(CandidateScrollAnchor.content)
            }
            .scrollBounceBehavior(.basedOnSize)
            .sharpCandidateScrollEdges()
            // Native horizontal scrolling is the browsing: no DragGesture triggers engine paging, so nothing is committed and
            // the engine highlight does not move; cross-page appending is done read-only by tailSentinel.
            // A new composition starts at its first candidate, not at the
            // previous composition's horizontal offset.
            .modifier(
                CandidateScrollReset(
                    identity: context.scrollIdentity,
                    proxy: proxy, anchor: .leading)
            )
            .frame(width: viewport)
            .frame(width: width, alignment: .leading)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("候选")
        .modifier(CandidateLoadingActions(context: context))
    }

}

/// Production cells and the load sentinel stay mounted across width changes.
@available(macOS 14.0, iOS 17.0, *)
struct CollapsedCandidateRow: View {
    let context: CandidateAreaContext
    let entries: [BrowserCandidate]
    let cellWidths: [CGFloat]
    let spacing: CGFloat

    @Environment(\.candidateSkinToken) private var skin
    @Environment(\.colorSchemeContrast) private var contrast

    private var stripDefinition: CandidateBarDefinition.Collapsed { context.bar.collapsed }
    private var effectiveHeaderHeight: CGFloat {
        CGFloat(
            CandidateBarDefinition.Collapsed.effectiveHeight(
                stripDefinition.height, candidateSize: context.typography.candidateSize))
    }

    var body: some View {
        LazyHStack(spacing: spacing) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                cell(entry, width: cellWidths.indices.contains(index) ? cellWidths[index] : 44)
            }
            tailSentinel
        }
    }

    /// Tail read-only loading sentinel: identity = structured (composition identity + frontier + view kind), present only
    /// while unloaded pages exist. A structured Hashable removes string-concatenation ambiguity; on an incomplete read the
    /// frontier is unchanged and the sentinel identity stable, so `onAppear` does not retrigger without bound (the user can retry manually).
    @ViewBuilder
    private var tailSentinel: some View {
        if context.hasMoreEntries, entries.count > 0 {
            Color.clear
                .frame(width: 1, height: 1)
                .id(
                    CandidateSentinelIdentity(
                        generation: context.browser.generation,
                        frontier: context.entryFrontier,
                        kind: .collapsedTail)
                )
                .onAppear { context.actions.perform(.loadMore) }
        }
    }

    @ViewBuilder
    private func cell(_ entry: BrowserCandidate, width: CGFloat) -> some View {
        let highlighted = context.isHighlighted(entry)
        // Narrow cells (about 50pt when five items fill the row) shrink their padding automatically so text keeps fidelity and a
        // two-character candidate is not truncated to an ellipsis for padding; wide cells restore the configured cellPaddingX.
        let padX = min(stripDefinition.cellPaddingX, max(4, (width - 40) / 2))
        let maxText = max(20, width - padX * 2)
        // The collapsed state keeps only the primary candidate and the highlight line. Scaling candidate + comment as
        // one block with `scaleEffect` to fit a limited header budget triggers offscreen resampling and turns the whole
        // row into a blurry smear. Comments stay in the expanded area and the accessibility value; the primary candidate
        // is always rasterized directly at its own size, and the layout box is clamped into the budget by the shared policy, never scaled as a whole.
        let budget = effectiveHeaderHeight
        let blockHeight = CandidateCollapsedFlow.fittedBlockHeight(
            blockHeight: CandidateCollapsedFlow.estimatedBlockHeight(
                typography: context.typography, hasComment: false),
            budget: budget)
        let lift = CandidateCollapsedFlow.clampedLift(context.contentLift, blockHeight: blockHeight, budget: budget)
        Button {
            context.actions.perform(context.selectAction(entry))
        } label: {
            VStack(spacing: 1) {
                HStack(spacing: 4) {
                    if let badge = entry.selectionBadge {
                        Text(badge)
                            .font(skin.font(context.typography.secondarySize))
                            .foregroundStyle(skin.secondaryColor)
                            .lineLimit(1)
                    }
                    Text(entry.text)
                        .font(skin.font(context.typography.candidateSize))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                // Reserve the same baseline for every candidate, including the underline.
                Group {
                    Capsule()
                        .fill(
                            highlighted
                                ? skin.candidateColor.opacity(
                                    CandidateTouchMetrics.indicatorOpacity(increasedContrast: contrast == .increased))
                                : .clear
                        )
                        .frame(width: underlineWidth(entry.text, maxWidth: maxText), height: 2)
                }
            }
            .foregroundStyle(skin.candidateColor)
            // Never scaleEffect the candidate content as a whole; keep the native font size and native glyph rasterization.
            .frame(height: blockHeight)
            // A layout offset (not a render transform): the block sits `lift`
            // above centre while the cell below keeps the full-height hit area.
            .padding(.bottom, lift * 2)
            .padding(.horizontal, padX)
            .frame(width: width)
            // The hit target keeps the 44pt horizontal minimum while matching the exact header height.
            .frame(minWidth: 44, minHeight: effectiveHeaderHeight)
            .contentShape(Rectangle())
        }
        // Touch-down paints an inset backing *under* the glyphs; the glyphs never move or fade.
        .buttonStyle(CandidateTapStyle(tint: skin.candidateColor, extraBottomInset: lift * 2))
        .candidateAccessibility(entry, highlighted: highlighted)
    }

    /// The underline width fits the candidate text (CJK about 1em) and is capped inside the cell, never crossing it.
    private func underlineWidth(_ text: String, maxWidth: CGFloat) -> CGFloat {
        let unit = context.typography.candidateSize
        let cjk = text.filter { $0.unicodeScalars.first.map { $0.value > 0x2E80 } ?? false }.count
        let latin = max(0, text.count - cjk)
        let approx = CGFloat(cjk) * unit + CGFloat(latin) * unit * 0.62 + 8
        return min(max(14, approx), maxWidth)
    }

}

@available(macOS 14.0, iOS 17.0, *)
private extension DefaultCollapsedCandidateBar {
    private func pageButton(
        _ symbol: String, label: String, disabled: Bool,
        action: CandidateAreaAction
    ) -> some View {
        // Follows the candidates' lift: the chip keeps its top inset and gives up
        // the lifted amount at the bottom, so arrow and glyphs share one centre.
        let pill = CandidateTouchMetrics.pillHeight(hitHeight: effectiveHeaderHeight)
        let block = CandidateCollapsedFlow.fittedBlockHeight(
            blockHeight: CandidateCollapsedFlow.estimatedBlockHeight(
                typography: context.typography,
                hasComment: false),
            budget: effectiveHeaderHeight)
        let lift = CandidateCollapsedFlow.clampedLift(
            context.contentLift, blockHeight: block,
            budget: effectiveHeaderHeight)
        return Button {
            context.actions.perform(action)
        } label: {
            KeyboardControlSymbol(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                // The arrow uses a high-contrast foreground (candidate primary color) + a distinct faint fill, so it is not
                // "nearly invisible" under light skins; the disabled state stays legible but clearly weaker.
                .foregroundStyle(disabled ? skin.secondaryColor.opacity(0.45) : skin.candidateColor)
                // The visible plate matches the candidate press pill's height and corner radius (default 40pt top bar -> 32x32),
                // with 4pt above and below; the hit region is still the full 44pt x top-bar-height cell.
                .frame(width: CandidateTouchMetrics.controlChipWidth, height: pill - lift * 2)
                .background(
                    RoundedRectangle(cornerRadius: CandidateTouchMetrics.cornerRadius, style: .continuous)
                        .fill(skin.candidateColor.opacity(disabled ? 0.03 : 0.05))
                )
                .padding(.bottom, lift * 2)
                .frame(width: 44, height: effectiveHeaderHeight)
                .contentShape(Rectangle())
        }
        // The press backing coincides with the visible chip.
        .buttonStyle(
            CandidateTapStyle(
                tint: skin.candidateColor,
                horizontalInset: CandidateTouchMetrics.controlHorizontalInset,
                extraBottomInset: lift * 2)
        )
        .disabled(disabled)
        .accessibilityLabel(label)
    }
}

@available(macOS 14.0, iOS 17.0, *)
extension View {
    /// Shared accessibility description of candidate cells: label = selection marker + candidate; value = selection key + real comment/reading;
    /// the hint describes the result, not the gesture (HIG); Voice Control can speak the candidate text directly.
    fileprivate func candidateAccessibility(_ entry: BrowserCandidate, highlighted: Bool) -> some View {
        let label = [entry.selectionBadge, entry.text].compactMap { $0 }.joined(separator: "，")
        // The visible candidate text comes first: it is what Voice Control shows and matches.
        let inputLabels = label == entry.text ? [entry.text] : [entry.text, label]
        return accessibilityLabel(label)
            .accessibilityValue(candidateAccessibilityValue(entry))
            .accessibilityHint("上屏此候选")
            .accessibilityInputLabels(inputLabels.map { Text(verbatim: $0) })
            .accessibilityAddTraits(highlighted ? .isSelected : [])
    }
}

// MARK: Expanded candidates (default adaptive text-width flow; user-configurable list / grid; cross-page scroll loading)

@available(macOS 14.0, iOS 17.0, *)
private struct DefaultExpandedCandidates: View {
    let context: CandidateAreaContext
    @Environment(\.candidateSkinToken) private var skin
    @Environment(\.displayScale) private var displayScale

    private var state: CandidatePresentationState { context.state }
    private var bar: CandidateBarDefinition { context.bar }
    private var entries: [BrowserCandidate] { context.displayEntries }

    var body: some View {
        // The expanded area's width is decided by host geometry (the panel gives a fixed height); the outer GeometryReader
        // supplies the available width so `adaptive` can break rows by **actual text width**. ScrollView + LazyVStack
        // stays lazy: the sentinel's onAppear fires only when scrolled to the bottom, keeping the read-only loadMore contract.
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    ExpandedCandidateRows(
                        context: context,
                        // -4 = 2pt horizontal content padding on each side, so row width does not exceed the visible area.
                        availableWidth: max(0, geometry.size.width - 4),
                        // Fill the real scroll viewport with whole touch rows.
                        // Otherwise the fixed keyboard budget exposes only the
                        // glyph tops of the next row before the user scrolls.
                        rowHeight: CandidateExpandedFlow.fittedRowHeight(
                            rowAreaHeight: CandidateExpandedFlow.rowAreaHeight(totalHeight: geometry.size.height),
                            spacing: CGFloat(context.bar.expandedRowSpacing),
                            displayScale: displayScale)
                    )
                    .padding(.horizontal, 2)
                    .padding(.top, CandidateExpandedFlow.topInset)
                    // No bottom padding inside the scroll content: the one bottom
                    // inset lives outside the viewport. Whole rows then fill the
                    // viewport exactly, so a list that fits does not scroll/bounce
                    // by a stray inset, and the last row still clears the bottom bar.
                    .id(CandidateScrollAnchor.content)
                }
                .sharpCandidateScrollEdges()
                .scrollBounceBehavior(.basedOnSize)
                // One system flash says "this list scrolls" without any decoration.
                .scrollIndicatorsFlash(onAppear: true)
                .modifier(
                    CandidateScrollReset(
                        identity: context.scrollIdentity,
                        proxy: proxy, anchor: .top))
            }
            .accessibilityLabel(context.hasMoreEntries ? "候选列表，滚动可加载更多" : "候选列表")
            .accessibilityElement(children: .contain)
            .modifier(CandidateLoadingActions(context: context))
            // Expanded candidates must not fade the bottom with a gradient `mask` or translucent overlay (that would
            // dim real candidate text and may trigger offscreen resampling). Scroll affordance comes from the content itself
            // and the tail sentinel; candidate text is always fully opaque and natively rasterized, identically for **all layouts** (26/14/9).
            // Bottom inset: breathing room between the last row and the real bottom bar so touch areas do not hug it.
            .padding(.bottom, CandidateExpandedFlow.bottomInset)
            // Opening the browser is an explicit opportunity to read one more page,
            // even when a short lazy stack never produces a useful scroll gesture.
            .task(id: context.browser.generation) {
                guard !Task.isCancelled, context.hasMoreEntries else { return }
                context.actions.perform(.loadMore)
            }
        }
        // The outer candidate surface owns the inherited scroll-edge policy;
        // a leaf-level modifier alone may be bypassed by nested GeometryReader.
        .sharpCandidateScrollEdges()
    }

}

/// The **real row content** of the expanded area (adaptive / list / grid + cells + tail sentinel). `ScrollView`
/// is only its scroll container; production and tests use this **same** view so tests do not copy a drifting layout
/// (and to work around `ImageRenderer` being unable to rasterize `ScrollView` content offscreen).
@available(macOS 14.0, iOS 17.0, *)
struct ExpandedCandidateRows: View {
    let context: CandidateAreaContext
    let availableWidth: CGFloat
    let rowHeight: CGFloat
    @Environment(\.candidateSkinToken) private var skin
    @Environment(\.colorSchemeContrast) private var contrast

    private var bar: CandidateBarDefinition { context.bar }
    private var entries: [BrowserCandidate] { context.displayEntries }

    var body: some View {
        Group {
            if bar.expanded.isAdaptive {
                adaptiveContent(availableWidth: availableWidth, rowHeight: rowHeight)
            } else {
                fixedContent(rowHeight: rowHeight)
            }
        }
    }

    /// Tail read-only loading sentinel: at the end of the content; LazyVStack ensures onAppear fires only when scrolled near it;
    /// identity = composition identity + frontier, so on failure the frontier is unchanged, the sentinel id is stable and it does not retrigger without bound.
    @ViewBuilder
    private var tailSentinel: some View {
        if context.hasMoreEntries, !entries.isEmpty {
            Color.clear.frame(height: 1)
                .task(
                    id: CandidateSentinelIdentity(
                        generation: context.browser.generation,
                        frontier: context.entryFrontier,
                        kind: .expandedTail)
                ) {
                    guard !Task.isCancelled,
                        (context.visibleEntries != nil || !context.browser.hasIncompletePage)
                    else { return }
                    context.actions.perform(.loadMore)
                }
        }
    }

    // MARK: Fixed columns (explicit user list / grid config; behavior unchanged)

    /// Grid mode uses a uniform column width (long words wrap instead of jumping to their own row); list mode has one per row and may wrap.
    private var fixedRows: [[BrowserCandidate]] {
        let columns = bar.expandedEffectiveColumns
        if bar.expanded.mode == .list || columns <= 1 {
            return entries.map { [$0] }
        }
        var result: [[BrowserCandidate]] = []
        var current: [BrowserCandidate] = []
        for entry in entries {
            current.append(entry)
            if current.count == columns {
                result.append(current)
                current = []
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    @ViewBuilder
    private func fixedContent(rowHeight: CGFloat) -> some View {
        LazyVStack(spacing: bar.expandedRowSpacing) {
            ForEach(Array(fixedRows.enumerated()), id: \.offset) { _, row in
                fixedRow(row, rowHeight: rowHeight)
            }
            tailSentinel
        }
    }

    @ViewBuilder
    private func fixedRow(_ row: [BrowserCandidate], rowHeight: CGFloat) -> some View {
        let columns = bar.expanded.mode == .list ? 1 : bar.expandedEffectiveColumns
        let reservesComment = Self.reservesCommentLine(row)
        // Cells share one structure per row (see `reservesCommentLine`), so top
        // alignment keeps one text line without baseline offsets inflating the row.
        HStack(alignment: .top, spacing: bar.expandedColumnSpacing) {
            ForEach(row) { entry in
                cell(entry, minimumHeight: rowHeight, reservesCommentLine: reservesComment)
            }
            // Pad the last row with empty columns to keep two equal-width columns aligned (long words do not change the grid).
            if row.count < columns {
                ForEach(0..<(columns - row.count), id: \.self) { _ in
                    Color.clear.frame(maxWidth: .infinity)
                }
            }
        }
    }

    // MARK: Adaptive (default; flows by actual text width)

    @ViewBuilder
    private func adaptiveContent(availableWidth: CGFloat, rowHeight: CGFloat) -> some View {
        let rows = CandidateExpandedFlow.layout(
            entries: entries,
            expanded: bar.expanded,
            typography: context.typography,
            cellPaddingX: bar.collapsed.cellPaddingX,
            availableWidth: availableWidth)
        LazyVStack(spacing: bar.expandedRowSpacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                adaptiveRow(row, rowHeight: rowHeight)
            }
            tailSentinel
        }
    }

    /// One adaptive row: each candidate gets a fixed cell width from its estimated width (single characters do not spread across the row), left-aligned.
    @ViewBuilder
    private func adaptiveRow(_ row: CandidateExpandedFlow.Row, rowHeight: CGFloat) -> some View {
        let reservesComment = Self.reservesCommentLine(row.entries)
        HStack(alignment: .top, spacing: bar.expandedColumnSpacing) {
            ForEach(row.entries.indices, id: \.self) { index in
                cell(row.entries[index], minimumHeight: rowHeight, reservesCommentLine: reservesComment)
                    .frame(width: row.widths[index], alignment: .topLeading)
            }
            Spacer(minLength: 0)
        }
    }

    /// When any cell in a row carries a real comment/reading, the other cells keep a same-height **blank** comment slot:
    /// every cell's content block has the same height and is vertically centered, so candidate text sits on one line,
    /// press pills align top and bottom, and baseline misalignment does not inflate the row height. The blank slot holds no text and never invents a reading.
    static func reservesCommentLine(_ entries: [BrowserCandidate]) -> Bool {
        entries.contains { !$0.comment.isEmpty }
    }

    // MARK: Cells

    @ViewBuilder
    private func cell(
        _ entry: BrowserCandidate, minimumHeight: CGFloat = 44,
        reservesCommentLine: Bool = false
    ) -> some View {
        let highlighted = context.isHighlighted(entry)
        Button {
            context.actions.perform(context.selectAction(entry))
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if let badge = entry.selectionBadge {
                        Text(badge)
                            .font(skin.font(context.typography.secondarySize))
                            .foregroundStyle(skin.secondaryColor)
                            .lineLimit(1)
                    }
                    Text(entry.text)
                        .font(skin.font(context.typography.candidateSize))
                        .lineLimit(nil)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !entry.comment.isEmpty {
                    Text(entry.comment)
                        .font(skin.font(context.typography.secondarySize))
                        .foregroundStyle(skin.secondaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                } else if reservesCommentLine {
                    // One blank line box in the comment font; nothing is drawn or announced.
                    Text(verbatim: " ")
                        .font(skin.font(context.typography.secondarySize))
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(skin.candidateColor)
            .padding(.horizontal, bar.collapsed.cellPaddingX)
            .padding(.vertical, 6)
            .frame(minWidth: 44, minHeight: minimumHeight, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                if highlighted {
                    Capsule().fill(
                        skin.candidateColor.opacity(
                            CandidateTouchMetrics.indicatorOpacity(increasedContrast: contrast == .increased))
                    )
                    .frame(width: 2, height: 18)
                    .padding(.leading, 1)
                }
            }
            .contentShape(Rectangle())
        }
        // Same inset backing as the collapsed strip: each cell shows its own
        // boundary on touch-down while the glyphs stay native and opaque.
        .buttonStyle(CandidateTapStyle(tint: skin.candidateColor))
        .candidateAccessibility(entry, highlighted: highlighted)
    }
}

private func candidateAccessibilityValue(_ entry: BrowserCandidate) -> String {
    var parts: [String] = []
    if let key = entry.selectKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
        parts.append("选词键 \(key)")
    }
    if !entry.comment.isEmpty { parts.append(entry.comment) }
    return parts.joined(separator: "，")
}

extension CandidateRendererDescriptor {
    /// Minimal fallback renderer: real candidate text only (used when the registry is empty).
    public static let plainText = CandidateRendererDescriptor(
        id: "plain-text",
        makeCollapsed: { context in
            AnyView(Text(context.state.candidates.map(\.text).joined(separator: " ")))
        },
        makeExpanded: { context in
            AnyView(Text(context.state.candidates.map(\.text).joined(separator: " ")))
        }
    )
}
