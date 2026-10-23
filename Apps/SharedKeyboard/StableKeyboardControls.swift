import LayoutKit
import SwiftUI

/// Slots, not their changing titles/actions, own view identity and width.
/// The host supplies existing skinned/accessible keys and the real engine actions.
struct StableKeyboardControlRow<Content: View>: View {
    @Environment(\.keyboardKeyHeight) private var keyHeight
    let policy: KeyboardControlPolicy
    @ViewBuilder var content: (KeyboardControlPolicy.Slot) -> Content

    var body: some View {
        GeometryReader { proxy in
            let metrics = policy.metrics(width: Double(proxy.size.width))
            HStack(spacing: metrics.spacing) {
                ForEach(policy.slots, id: \.self) { slot in
                    content(slot)
                        .frame(width: metrics[slot], height: keyHeight)
                }
            }
        }
        .frame(height: keyHeight)
    }
}

/// The one phone-keypad shell. It owns **all** of the T9 geometry:
///
///  * width — `PhoneKeypadMetrics.resolve` splits the proposed width into
///    leading rail + gap + 3×3 pad + gap + trailing rail under an explicit
///    identity, so the grid and the bottom control row always share one content
///    edge. The whole shell is centred as one unit only when the device is wider
///    than the design maximum; the rails are never widened to fake alignment.
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
    @ViewBuilder var leading: (PhoneKeypadMetrics) -> Leading
    @ViewBuilder var main: (PhoneKeypadMetrics) -> Main
    @ViewBuilder var trailing: (PhoneKeypadMetrics) -> Trailing
    @ViewBuilder var bottom: (PhoneKeypadMetrics) -> Bottom

    var body: some View {
        GeometryReader { proxy in
            let metrics = PhoneKeypadMetrics.resolve(
                width: Double(proxy.size.width),
                rowHeight: Double(keyHeight))
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
                                        width: CGFloat(metrics.mainWidth),
                                        height: CGFloat(metrics.mainHeight), alignment: .top)
                            }
                            .frame(height: CGFloat(metrics.mainHeight))
                            bottom(metrics)
                                .frame(
                                    width: CGFloat(metrics.controlRowRectBesideTrailingRail().width),
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
                                    width: CGFloat(metrics.mainWidth),
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
                            .frame(width: CGFloat(metrics.contentWidth), height: CGFloat(metrics.rowHeight))
                    }
                }
            }
            // One explicit margin around the *whole* shell (grid and control row
            // together), never a gap inserted between them.
            .padding(.horizontal, CGFloat(metrics.outerInset))
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
