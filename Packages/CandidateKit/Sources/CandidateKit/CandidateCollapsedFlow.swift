import Foundation
import KeyboardCore

// MARK: - Width policy for the collapsed candidate strip (render-agnostic, unit-testable)
//
// A fixed 44pt cell cannot hold a three-character word (about 60pt at 20pt font size); it would be
// truncated to a single character plus an ellipsis.
//
// Design:
//   * Few, short candidates are laid out in **even-width** cells (at most `maximumEvenCellWidth`), used only
//     when every candidate fits completely **by total width**.
//   * Otherwise cells follow the **intrinsic width of the text/selection marker actually drawn**; a cell
//     **may exceed the viewport**, so a long candidate shows its full text in the same horizontal
//     ScrollView (controls stay fixed outside the scroll area; taps still resolve by the entry's page ownership).
//   * `scrolls` is true only when the **total width really exceeds the viewport** (not merely because the
//     ScrollView branch was taken).
//   * Cell width has a **finite guard rail** (a finite multiple of the available width) so extreme text cannot
//     produce pathological frames; normal words/phrases stay far below it. Infinite widths are never used.
//
// This file uses the **estimated budget** of `CandidateTextMetrics` (not real SwiftUI glyph measurement):
// a minimal implementation with fixed slack, not claiming "estimate = exact". Real font/size fidelity is checked with targeted screenshots.

/// Collapsed strip layout result: per-cell widths + whether horizontal scrolling is really needed.
public struct CandidateCollapsedLayout: Equatable, Sendable {
    /// Cell widths corresponding one-to-one with the input `entries`.
    public let cellWidths: [CGFloat]
    /// True when the total content width **actually exceeds** the viewport and horizontal scrolling is needed (accessibility relies on this).
    public let scrolls: Bool
    public init(cellWidths: [CGFloat], scrolls: Bool) {
        self.cellWidths = cellWidths
        self.scrolls = scrolls
    }
}

public enum CandidateCollapsedFlow {
    /// Minimum touch width of a cell (same as expanded cells).
    public static let minimumCellWidth: CGFloat = 44
    /// Upper bound of one cell in even-width fill (keeps the original collapsed-strip constraint so a single candidate does not needlessly fill the screen).
    public static let maximumEvenCellWidth: CGFloat = 120
    /// Per-cell width guard-rail factor: a single candidate may exceed the viewport so a horizontal drag shows
    /// the full text, but it is capped at a finite multiple of the available width to avoid pathological frames (normal words/phrases stay far below).
    public static let maximumCellWidthFactor: CGFloat = 4
    /// A little slack for candidate text so a font rounding does not truncate with an ellipsis when the estimate equals the available width exactly.
    static let textSlack: CGFloat = 4
    /// Floating-point tolerance (used in the total-width comparison; there is no per-cell 0.5pt tolerance anymore).
    static let fitEpsilon: CGFloat = 0.001

    /// Collapsed cell width is estimated only from the actually drawn candidate text / selection marker; comments stay in the expanded area and the accessibility value.
    public static func intrinsicCellWidth(
        text: String, comment _: String,
        selectionBadge: String? = nil,
        typography: CandidateTypography,
        cellPaddingX: Double
    ) -> CGFloat {
        let textWidth = CandidateTextMetrics.estimatedWidth(text, fontSize: typography.candidateSize)
        let badgeWidth =
            selectionBadge.map {
                CandidateTextMetrics.estimatedWidth($0, fontSize: typography.secondarySize) + 4
            } ?? 0
        let pad = cellPaddingX.isFinite ? max(0, CGFloat(cellPaddingX)) : 0
        return max(minimumCellWidth, textWidth + badgeWidth + pad * 2 + textSlack)
    }

    // MARK: Vertical budget (inside the fixed header surface)

    /// Base layout box height of a collapsed cell. For larger primary candidate sizes the effective header height makes up the difference.
    public static let minimumBlockHeight: CGFloat = 36

    /// Automatic layout box height: always <= budget (never exceeding the original block height).
    ///
    /// The collapsed state never scales as a whole: the primary candidate is always rasterized natively at its
    /// own size; the effective budget grows to fit the font size, and the secondary comment yields in the collapsed
    /// state (the expanded area and accessibility value keep it).
    public static func fittedBlockHeight(blockHeight: CGFloat, budget: CGFloat) -> CGFloat {
        guard blockHeight.isFinite, budget.isFinite, blockHeight > 0, budget > 0 else { return blockHeight }
        return min(blockHeight, budget)
    }

    /// Effective lift: non-negative and finite, and after lifting the content block (`blockHeight`) still
    /// fits inside the `budget`-tall row (lift <= the slack above the centered position).
    public static func clampedLift(_ lift: Double, blockHeight: CGFloat, budget: CGFloat) -> CGFloat {
        guard lift.isFinite, lift > 0, blockHeight.isFinite, budget.isFinite else { return 0 }
        return min(CGFloat(lift), max(0, (budget - blockHeight) / 2))
    }

    /// Estimated height of a collapsed candidate block: candidate text line + underline baseline + optional comment line.
    /// Shared by the production collapsed renderer and tests so the layout box matches the real VStack structure.
    public static func estimatedBlockHeight(
        typography: CandidateTypography,
        hasComment: Bool
    ) -> CGFloat {
        let text = typography.candidateSize.isFinite ? max(0, CGFloat(typography.candidateSize)) * 1.25 : 0
        let underline: CGFloat = 2
        let spacing: CGFloat = 1
        let comment =
            (hasComment && typography.secondarySize.isFinite)
            ? max(0, CGFloat(typography.secondarySize)) * 1.25 : 0
        return text + underline + spacing + comment
    }

    /// Per-cell width guard rail (finite): `max(44, available width * factor)`; falls back to the minimum width if the factor overflows.
    public static func maximumCellWidth(availableWidth: CGFloat) -> CGFloat {
        let base = availableWidth.isFinite ? max(0, availableWidth) : 0
        let scaled = base * maximumCellWidthFactor
        return max(minimumCellWidth, scaled.isFinite ? scaled : minimumCellWidth)
    }

    /// Visible viewport width when scrolling: shows only the cells that fit completely from the first cell, so the last
    /// cell is not cut in half at the edge (a viewport box rather than a mask). Uses the full available width when not
    /// scrolling or when the first cell is already wider.
    public static func wholeCellViewportWidth(
        cellWidths: [CGFloat], spacing: CGFloat,
        availableWidth: CGFloat
    ) -> CGFloat {
        let available = availableWidth.isFinite ? max(0, availableWidth) : 0
        let gap = spacing.isFinite ? max(0, spacing) : 0
        var used: CGFloat = 0
        for (index, width) in cellWidths.enumerated() {
            let next = used + (index == 0 ? 0 : gap) + width
            if next > available + fitEpsilon { return index == 0 ? available : used }
            used = next
        }
        return available
    }

    /// Collapsed strip layout: even-width fill (no scrolling) or intrinsic-width layout (scrolling when wider).
    ///
    /// Even-width fill is decided on **total width**: `widest*count + spacing*(count-1) <= available`
    /// (no per-cell 0.5pt tolerance, which would accumulate overflow). Otherwise cells use their candidates'
    /// intrinsic widths, each allowed to exceed the viewport (guard rail: a finite multiple of the available
    /// width); `scrolls` is decided by the **actual total width**.
    public static func layout(
        entries: [BrowserCandidate],
        collapsed: CandidateBarDefinition.Collapsed,
        typography: CandidateTypography,
        availableWidth: CGFloat,
        fillsAvailableWidth: Bool? = nil
    ) -> CandidateCollapsedLayout {
        guard !entries.isEmpty else { return CandidateCollapsedLayout(cellWidths: [], scrolls: false) }
        let spacing = collapsed.cellSpacing.isFinite ? max(0, CGFloat(collapsed.cellSpacing)) : 0
        // A non-finite available width means "unconstrained" (so even-width fill applies); zero or negative widths are treated as a finite 0.
        let available = availableWidth.isFinite ? max(0, availableWidth) : CGFloat.greatestFiniteMagnitude
        let intrinsic = entries.map {
            intrinsicCellWidth(
                text: $0.text, comment: $0.comment,
                selectionBadge: $0.selectionBadge,
                typography: typography, cellPaddingX: collapsed.cellPaddingX)
        }
        let count = entries.count
        let widest = intrinsic.max() ?? minimumCellWidth

        // Decide exactly by total width: even-width cells (>= the widest candidate) fill only when they fit. `evenTotal` must be finite;
        // otherwise (estimate overflow + unconstrained available width) fall back to the finite guard-rail branch, never an infinite cell width.
        let evenTotal = widest * CGFloat(count) + spacing * CGFloat(count - 1)
        if fillsAvailableWidth ?? collapsed.fillsAvailableWidth ?? true,
            evenTotal.isFinite, evenTotal <= available + fitEpsilon
        {
            let uniform = (available - spacing * CGFloat(count - 1)) / CGFloat(count)
            let even = max(widest, min(uniform, maximumEvenCellWidth))
            return CandidateCollapsedLayout(
                cellWidths: Array(repeating: even, count: count),
                scrolls: false)
        }

        // Lay out by intrinsic width: a cell may exceed the viewport (finite guard rail), so the same ScrollView can show the full text.
        let cap = maximumCellWidth(availableWidth: available)
        let widths = intrinsic.map { value -> CGFloat in
            guard value.isFinite else { return cap }
            return max(minimumCellWidth, min(value, cap))
        }
        let total = widths.reduce(0, +) + spacing * CGFloat(count - 1)
        return CandidateCollapsedLayout(cellWidths: widths, scrolls: total > available + fitEpsilon)
    }
}
