import LayoutKit
import SwiftUI

/// Slots, not their changing titles/actions, own view identity and width.
/// The host supplies existing skinned/accessible keys and the real engine actions.
struct StableKeyboardControlRow<Content: View>: View {
    @Environment(\.keyboardKeyHeight) private var keyHeight
    let policy: KeyboardControlPolicy
    var split: ActiveLayoutSplit? = nil
    var splitRowIndex = 3
    @ViewBuilder var content: (KeyboardControlPolicy.Slot) -> Content

    var body: some View {
        if let split {
            let boundary = split.breakIndex(row: splitRowIndex, keyCount: policy.slots.count)
            let left = Array(policy.slots.prefix(boundary)).filter { $0 != .space }
            let right = Array(policy.slots.dropFirst(boundary)).filter { $0 != .space }
            let widths = policy.metrics(width: SplitSpaceRowBudget.controlRowWidth)
            SplitSpaceKeyboardRow(
                leftKeys: left, rightKeys: right, leftWidths: left.map { widths[$0] },
                rightWidths: right.map { widths[$0] }, split: split,
                key: { content($0) }, space: { content(.space) }, fallback: { singleSpaceRow })
        } else {
            singleSpaceRow
        }
    }

    private var singleSpaceRow: some View {
        GeometryReader { proxy in
            let metrics = policy.metrics(width: Double(proxy.size.width))
            HStack(spacing: metrics.spacing) {
                ForEach(policy.slots, id: \.self) { slot in
                    content(slot).frame(width: metrics[slot], height: keyHeight)
                }
            }
        }.frame(height: keyHeight)
    }
}

/// Split control rows size their controls as the compact control row would at this width; the two
/// space bars share the rest.
enum SplitSpaceRowBudget {
    static let controlRowWidth: Double = 320
}

/// The one split row with a space bar in each half; each native space control owns its own
/// touch and cursor-pan session.
struct SplitSpaceKeyboardRow<Key: Hashable, KeyContent: View, Space: View, Fallback: View>: View {
    @Environment(\.keyboardKeyHeight) private var keyHeight
    let leftKeys: [Key]
    let rightKeys: [Key]
    let leftWidths: [Double]
    let rightWidths: [Double]
    let split: ActiveLayoutSplit
    var spaceWidthMultiplier = 3.0
    /// The gutter to request; nil asks the split at this row's own width.
    var requestedGap: Double? = nil
    var spacing: Double = 4
    @ViewBuilder var key: (Key) -> KeyContent
    @ViewBuilder var space: () -> Space
    /// Drawn instead of the built-in scrolling row when the surface is too narrow for two usable
    /// spaces, only if `narrowUsesFallback` is set.
    @ViewBuilder var fallback: () -> Fallback
    var narrowUsesFallback = false

    var body: some View {
        GeometryReader { proxy in
            let requested =
                requestedGap
                ?? split.gap(
                    width: Double(proxy.size.width), keyCount: max(2, leftKeys.count + rightKeys.count + 1),
                    minimumKeyWidth: 44)
            let letterWidth = StandardKeyRowGeometry(width: Double(proxy.size.width), split: split).keyWidth
            if let geometry = SplitSpaceRowGeometry(
                width: Double(proxy.size.width), requestedGap: requested,
                leftKeyWidths: leftWidths, rightKeyWidths: rightWidths, spacing: spacing,
                preferredSpaceWidth: letterWidth * spaceWidthMultiplier)
            {
                HStack(spacing: 0) {
                    HStack(spacing: geometry.spacing) {
                        ForEach(Array(leftKeys.enumerated()), id: \.element) { index, item in
                            key(item).frame(width: leftWidths[index], height: keyHeight)
                        }
                        space().id("left-space").frame(width: geometry.leftSpaceWidth, height: keyHeight)
                    }.frame(width: geometry.leftWidth)
                    KeyboardSplitGap().frame(width: geometry.gap + geometry.spacing, height: keyHeight)
                    HStack(spacing: geometry.spacing) {
                        space().id("right-space").frame(width: geometry.rightSpaceWidth, height: keyHeight)
                        ForEach(Array(rightKeys.enumerated()), id: \.element) { index, item in
                            key(item).frame(width: rightWidths[index], height: keyHeight)
                        }
                    }.frame(width: geometry.rightWidth)
                }
            } else if narrowUsesFallback {
                fallback()
            } else {
                // The user asked for a split and the surface is too narrow for two usable spaces:
                // keep both spaces and scroll the row instead of silently dropping one.
                let spaceWidth = CGFloat(max(44, letterWidth * spaceWidthMultiplier))
                let gutter = max(CGFloat(24), CGFloat(requested))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(leftKeys.enumerated()), id: \.element) { index, item in
                            key(item)
                                .frame(width: CGFloat(max(44, leftWidths[index])), height: keyHeight)
                        }
                        space().id("left-space").frame(width: spaceWidth, height: keyHeight)
                        KeyboardSplitGap().frame(width: max(0, gutter - 4), height: keyHeight)
                        space().id("right-space").frame(width: spaceWidth, height: keyHeight)
                        ForEach(Array(rightKeys.enumerated()), id: \.element) { index, item in
                            key(item)
                                .frame(width: CGFloat(max(44, rightWidths[index])), height: keyHeight)
                        }
                    }
                }
                .sharpCandidateScrollEdges()
            }
        }.frame(height: keyHeight)
    }
}

/// The one phone-keypad shell. It owns **all** of the T9 geometry:
///
///  * width — `PhoneKeypadMetrics.resolve` splits the proposed width into
///    leading rail + gap + 3×3 pad + gap + trailing rail under an explicit
///    identity, so the grid and the bottom control row always share one content
///    edge. Without a split, the compact shell is centered as one unit on wide
///    surfaces. Splitting keeps the rail dimensions and expands the gap across
///    the available width so both hands can reach their keys.
///  * height — digit row *i*, every rail slot and the control row are derived
///    from the same `metrics.rowHeight` and `metrics.spacing`, so a rail slot and
///    a digit row start on exactly the same line.
///  * vertical alignment — the main `HStack` aligns `.top`, so the first rail
///    slot and the first digit row both begin at y = 0 with no centring guess.
///
/// By default the editing rail is confined to the three main rows and the bottom
/// control row spans the same `contentWidth` outside the grid. The bundled T9
/// sets `trailingSpansControlRow`: its trailing column (Delete, 重输, Return) runs
/// down beside the control row so Return fills the bottom-right corner, and the
/// control row ends one gap before it and omits Return
/// (`KeyboardControlPolicy.includesBottomEnter`). Imported keypads keep whatever
/// their own control row / rail declared.
///
/// Every region receives the resolved metrics, so slots take
/// `metrics.rowHeight` / `metrics.spanHeight(_:)` directly instead of guessing
/// with an independent `VStack(maxHeight:)`.
struct StablePhoneKeypadShell<Leading: View, Main: View, Trailing: View, Bottom: View>: View {
    @Environment(\.keyboardKeyHeight) private var keyHeight
    var trailingSpansControlRow = false
    var expandsForSplit = false
    @ViewBuilder var leading: (PhoneKeypadMetrics) -> Leading
    @ViewBuilder var main: (PhoneKeypadMetrics) -> Main
    @ViewBuilder var trailing: (PhoneKeypadMetrics) -> Trailing
    @ViewBuilder var bottom: (PhoneKeypadMetrics) -> Bottom

    var body: some View {
        GeometryReader { proxy in
            let metrics = PhoneKeypadMetrics.resolve(
                width: Double(proxy.size.width),
                rowHeight: Double(keyHeight))
            let contentWidth = expandsForSplit ? Double(proxy.size.width) : metrics.contentWidth
            let mainWidth =
                expandsForSplit
                ? max(0, contentWidth - 2 * (metrics.railWidth + metrics.spacing)) : metrics.mainWidth
            let bottomWidthBesideRail =
                expandsForSplit
                ? max(0, contentWidth - metrics.railWidth - metrics.spacing)
                : metrics.controlRowRectBesideTrailingRail().width
            Group {
                if trailingSpansControlRow {
                    HStack(alignment: .top, spacing: CGFloat(metrics.spacing)) {
                        VStack(spacing: CGFloat(metrics.spacing)) {
                            HStack(alignment: .top, spacing: CGFloat(metrics.spacing)) {
                                leading(metrics)
                                    .frame(
                                        width: CGFloat(metrics.railWidth),
                                        height: CGFloat(metrics.mainHeight), alignment: .top)
                                main(metrics)
                                    .frame(
                                        width: CGFloat(mainWidth),
                                        height: CGFloat(metrics.mainHeight), alignment: .top)
                            }
                            .frame(height: CGFloat(metrics.mainHeight))
                            bottom(metrics)
                                .frame(
                                    width: CGFloat(bottomWidthBesideRail),
                                    height: CGFloat(metrics.rowHeight))
                        }
                        trailing(metrics)
                            .frame(
                                width: CGFloat(metrics.railWidth),
                                height: CGFloat(metrics.totalHeight), alignment: .top)
                    }
                } else {
                    VStack(spacing: CGFloat(metrics.spacing)) {
                        HStack(alignment: .top, spacing: CGFloat(metrics.spacing)) {
                            leading(metrics)
                                .frame(
                                    width: CGFloat(metrics.railWidth),
                                    height: CGFloat(metrics.mainHeight), alignment: .top)
                            main(metrics)
                                .frame(
                                    width: CGFloat(mainWidth),
                                    height: CGFloat(metrics.mainHeight), alignment: .top)
                            trailing(metrics)
                                .frame(
                                    width: CGFloat(metrics.railWidth),
                                    height: CGFloat(metrics.mainHeight), alignment: .top)
                        }
                        .frame(height: CGFloat(metrics.mainHeight))
                        // The bottom row spans exactly the grid's content width and is
                        // deliberately outside the three-row main grid.
                        bottom(metrics)
                            .frame(width: CGFloat(contentWidth), height: CGFloat(metrics.rowHeight))
                    }
                }
            }
            // One explicit margin around the *whole* shell (grid and control row
            // together), never a gap inserted between them.
            .padding(.horizontal, expandsForSplit ? 0 : CGFloat(metrics.outerInset))
            .frame(width: proxy.size.width, alignment: .center)
        }
        .frame(height: totalHeight)
    }

    /// Height depends only on the row height, so the shell can reserve its full
    /// budget before the width is known and the panel height never jumps.
    private var totalHeight: CGFloat {
        let spacing = CGFloat(PhoneKeypadMetrics.spacing)
        return keyHeight * CGFloat(PhoneKeypadMetrics.mainRowCount + 1)
            + spacing * CGFloat(PhoneKeypadMetrics.mainRowCount)
    }
}
