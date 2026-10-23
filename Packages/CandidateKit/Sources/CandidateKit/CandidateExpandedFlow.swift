import Foundation
import KeyboardCore

// MARK: - Adaptive flow layout of expanded candidates (render-agnostic, unit-testable)
//
// The default expanded area lays candidates out left to right by their actual text width and wraps
// when they do not fit. (A fixed-column grid with equal-width cells left the right half empty after
// single-character candidates and squeezed long words into half-width cells.)
//   * Widths use the `CandidateTextMetrics` estimate (CJK ~ 1em, Latin ~ 0.62em).
//   * Each candidate takes its text/comment estimated width plus side padding, raised to the minimum touch width.
//   * A candidate over the threshold (character count, or 3x for comments) or wider than the available
//     width takes its own row, capped to the available width (long words stay readable and the list still scrolls vertically).
//   * User-configured `grid` (column count) and `list` (single column) are unaffected; only the default
//     `adaptive` mode uses this path.
//
// This is pure geometry/string measurement and does not import SwiftUI/UIKit, so bounds can be asserted without a device.

/// Estimated rendered width of candidate text (a layout budget, not exact typesetting).
public enum CandidateTextMetrics {
    /// CJK/full-width scalars count as 1em, everything else 0.62em; empty text or an invalid font size gives 0.
    public static func estimatedWidth(_ text: String, fontSize: Double) -> CGFloat {
        guard !text.isEmpty, fontSize.isFinite, fontSize > 0 else { return 0 }
        let unit = CGFloat(fontSize)
        var cjk = 0
        var latin = 0
        for scalar in text.unicodeScalars {
            if scalar.value > 0x2E80 { cjk += 1 } else { latin += 1 }
        }
        return CGFloat(cjk) * unit + CGFloat(latin) * unit * 0.62
    }
}

/// Adaptive flow layout of expanded candidates.
public enum CandidateExpandedFlow {
    /// Minimum touch width of a cell (same as the collapsed strip): short candidates keep a tappable area.
    public static let minimumCellWidth: CGFloat = 44
    /// Bottom safety inset of the expanded content: breathing room between the last row and the real bottom bar so touch areas do not hug it.
    public static let bottomInset: CGFloat = 8
    /// Top inset of the expanded content (matches the 2pt left/right): the first row's press pill does not touch the top-bar divider.
    public static let topInset: CGFloat = 2

    /// Total expanded height to scroll viewport height: the single bottom inset lies outside the viewport (not stacked again inside the scroll content).
    public static func viewportHeight(totalHeight: CGFloat) -> CGFloat {
        guard totalHeight.isFinite else { return 0 }
        return max(0, totalHeight - bottomInset)
    }

    /// Height available for whole rows inside the viewport (minus the top inset).
    public static func rowAreaHeight(totalHeight: CGFloat) -> CGFloat {
        max(0, viewportHeight(totalHeight: totalHeight) - topInset)
    }

    /// Fit ordinary 44pt rows without showing a fourth row with only its glyph tops.
    /// This changes row height, not configured inter-row spacing or candidate order.
    public static func fittedRowHeight(availableHeight: CGFloat, spacing: CGFloat) -> CGFloat {
        guard availableHeight.isFinite, availableHeight >= 44, spacing.isFinite else { return 44 }
        let gap = max(0, spacing)
        let count = max(1, floor((availableHeight + gap) / (44 + gap)))
        return max(44, (availableHeight - (count - 1) * gap) / count)
    }

    /// Same, then floored to device pixels: the sum of rows never exceeds the viewport (otherwise a list
    /// that fits on one screen would become draggable/bouncy from sub-pixel slack); slack is under one pixel per row.
    public static func fittedRowHeight(
        rowAreaHeight: CGFloat, spacing: CGFloat,
        displayScale: CGFloat
    ) -> CGFloat {
        let fitted = fittedRowHeight(availableHeight: max(44, rowAreaHeight), spacing: spacing)
        guard displayScale.isFinite, displayScale > 0 else { return fitted }
        // A 1e-4 px tolerance keeps an exact pixel value (e.g. 47⅓ @3x) from flooring a whole pixel.
        return max(44, floor(fitted * displayScale + 1e-4) / displayScale)
    }

    /// One row: candidates correspond one-to-one with their cell widths (same order as `entries`).
    public struct Row: Equatable, Sendable {
        public let entries: [BrowserCandidate]
        public let widths: [CGFloat]
        public init(entries: [BrowserCandidate], widths: [CGFloat]) {
            self.entries = entries
            self.widths = widths
        }
    }

    /// Preferred cell width of one candidate: the larger of the text/comment estimates plus side padding, raised to the minimum touch width.
    public static func cellWidth(
        for entry: BrowserCandidate,
        typography: CandidateTypography,
        cellPaddingX: Double
    ) -> CGFloat {
        let text = CandidateTextMetrics.estimatedWidth(entry.text, fontSize: typography.candidateSize)
        let badge =
            entry.selectionBadge.map {
                CandidateTextMetrics.estimatedWidth($0, fontSize: typography.secondarySize) + 4
            } ?? 0
        let comment = CandidateTextMetrics.estimatedWidth(entry.comment, fontSize: typography.secondarySize)
        let pad = cellPaddingX.isFinite ? max(0, CGFloat(cellPaddingX)) : 0
        return max(minimumCellWidth, max(text + badge, comment) + pad * 2)
    }

    /// Whether the candidate takes its own row for readability: text length or comment length exceeds the threshold.
    public static func wantsOwnRow(_ entry: BrowserCandidate, fullRowTextLength: Int) -> Bool {
        let threshold = max(1, fullRowTextLength)
        return entry.text.count > threshold || entry.comment.count > threshold * 3
    }

    /// Greedy line breaking: fill left to right and wrap when a candidate does not fit; long or over-wide
    /// candidates take their own row, capped to the available width.
    /// `availableWidth` is the usable content width of the expanded area; when non-finite or non-positive, nothing wraps.
    public static func layout(
        entries: [BrowserCandidate],
        expanded: CandidateBarDefinition.Expanded,
        typography: CandidateTypography,
        cellPaddingX: Double,
        availableWidth: CGFloat
    ) -> [Row] {
        guard !entries.isEmpty else { return [] }
        let spacing = expanded.columnSpacing.isFinite ? max(0, CGFloat(expanded.columnSpacing)) : 0
        let available =
            availableWidth.isFinite && availableWidth > 0
            ? availableWidth : CGFloat.greatestFiniteMagnitude
        let cap = available.isFinite ? available : 0

        var rows: [Row] = []
        var currentEntries: [BrowserCandidate] = []
        var currentWidths: [CGFloat] = []
        var currentWidth: CGFloat = 0

        func flush() {
            guard !currentEntries.isEmpty else { return }
            rows.append(Row(entries: currentEntries, widths: currentWidths))
            currentEntries = []
            currentWidths = []
            currentWidth = 0
        }

        for entry in entries {
            let estimated = cellWidth(for: entry, typography: typography, cellPaddingX: cellPaddingX)
            let ownRow =
                wantsOwnRow(entry, fullRowTextLength: expanded.fullRowTextLength)
                || estimated > available + 0.5
            if ownRow {
                flush()
                rows.append(Row(entries: [entry], widths: [cap > 0 ? cap : estimated]))
                continue
            }
            let projected = currentEntries.isEmpty ? estimated : currentWidth + spacing + estimated
            if !currentEntries.isEmpty && projected > available + 0.5 {
                flush()
            }
            currentEntries.append(entry)
            currentWidths.append(estimated)
            currentWidth = currentEntries.count == 1 ? estimated : currentWidth + spacing + estimated
        }
        flush()
        return rows
    }
}
