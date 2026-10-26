import CandidateKit
import UIKit

// The controller's view and inputView (same instance), created in KeyboardViewController.loadView.
// It does not adopt UIInputViewAudioFeedback: key clicks play through AVAudioPlayer
// (KeyboardFeedbackService), and the conformance only added one more system
// reference to every input view UIKit replaces.

/// Root container of the keyboard extension's input view; installed as both
/// `KeyboardViewController`'s view and inputView (same instance).
public final class FeedbackInputView: KeyboardPanelInputView {

    public override init(frame: CGRect, inputViewStyle: UIInputView.Style) {
        super.init(frame: frame, inputViewStyle: inputViewStyle)
        KeyboardLiveObjects.inputViews.increment()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        KeyboardLiveObjects.inputViews.increment()
    }

    deinit {
        KeyboardLiveObjects.inputViews.decrement()
    }

    // MARK: Touches in the gaps between keys

    /// Adjacent keys have 4pt of visual spacing; a touch in that gap must still reach a key.
    /// As on the system keyboard, a gap touch with keys on both sides (left/right or above/below) goes to the nearer key.
    private static let keyGapReach: CGFloat = 6
    /// At outer edges with a key on one side only: left/right margins and row indents (the ASDF row's half-key insets) go to the nearest key in the same row;
    /// the margin below the bottom row goes to the key above it; never extends upward (above the top row is the candidate bar, whose taps must not be stolen).
    private static let keyEdgeReach: CGFloat = 24
    private static let keyBottomReach: CGFloat = 10

    public override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        #if DEBUG
            if DebugProbe.touchRoutingEnabled {
                DebugProbe.touchRouting(point: point, hit: hit, nearKeys: [], routed: nil)
            }
        #endif
        // A transparent SwiftUI host may skip its native control away from the arrow.
        // Forward only to the registered, visible control in this same window.
        if let window {
            let windowPoint = convert(point, to: window)
            if let restore = KeyboardRoutedTouch.oneHandRestoreTarget(at: windowPoint, in: window) {
                #if DEBUG
                    if DebugProbe.touchRoutingEnabled {
                        DebugProbe.touchRouting(
                            point: point, hit: restore, nearKeys: [],
                            routed: restore.convert(restore.bounds, to: self))
                    }
                #endif
                return restore
            }
            if KeyboardRoutedTouch.pointIsInOneHandGutter(windowPoint) {
                if hit is SkinnedButton || hit is AlternateCharacterKey.CharacterButton { return self }
                return hit
            }
            // A docked wide keyboard owns only its real content frame. The blank side margins
            // must not become the nearest edge key; tools inside the frame still hit normally.
            if KeyboardRoutedTouch.pointIsOutsideWideContent(windowPoint, in: window) {
                return hit
            }
        }
        guard !(hit is UIControl), self.point(inside: point, with: event) else { return hit }
        // Inside a scroll view (the 9-key reading rail, a candidate strip) empty space
        // belongs to that view, not to a key beside it.
        var inScroll = false
        var ancestor = hit
        while let view = ancestor, view !== self, !inScroll {
            inScroll = view is UIScrollView
            ancestor = view.superview
        }
        let (key, near) = keyForGap(at: point, allowEdges: !inScroll)
        #if DEBUG
            if DebugProbe.touchRoutingEnabled {
                DebugProbe.touchRouting(
                    point: point, hit: hit, nearKeys: near.map(\.frame),
                    routed: key.map { $0.convert($0.bounds, to: self) })
            }
        #endif
        // Only hand off to keys that are hittable at their own center: keys covered by overlays such as the tools/symbol panels must not receive gap touches.
        guard let key else { return hit }
        let center = key.convert(CGPoint(x: key.bounds.midX, y: key.bounds.midY), to: self)
        guard let top = super.hitTest(center, with: event), top === key || top.isDescendant(of: key) else { return hit }
        if let window { KeyboardRoutedTouch.route(key, at: convert(point, to: window)) }
        return key
    }

    private func keyForGap(at point: CGPoint, allowEdges: Bool) -> (UIView?, [(view: UIView, frame: CGRect)]) {
        var keys: [(view: UIView, frame: CGRect)] = []
        collectKeys(in: self, into: &keys)
        let reach = Self.keyGapReach
        let near = keys.filter { $0.frame.insetBy(dx: -reach, dy: -reach).contains(point) }
        func overlapsRow(_ f: CGRect) -> Bool { f.minY <= point.y && point.y <= f.maxY }
        func overlapsColumn(_ f: CGRect) -> Bool { f.minX <= point.x && point.x <= f.maxX }
        func edge() -> UIView? { allowEdges ? edgeKey(at: point, keys: keys, overlapsRow, overlapsColumn) : nil }
        guard near.count >= 2 else { return (edge(), near) }
        let left = near.filter { overlapsRow($0.frame) && $0.frame.maxX <= point.x + 0.5 }
        let right = near.filter { overlapsRow($0.frame) && $0.frame.minX >= point.x - 0.5 }
        let above = near.filter { overlapsColumn($0.frame) && $0.frame.maxY <= point.y + 0.5 }
        let below = near.filter { overlapsColumn($0.frame) && $0.frame.minY >= point.y - 0.5 }
        let sides =
            (!left.isEmpty && !right.isEmpty ? left + right : [])
            + (!above.isEmpty && !below.isEmpty ? above + below : [])
        let gapKey = sides.min { distance(from: point, to: $0.frame) < distance(from: point, to: $1.frame) }?.view
        return (gapKey ?? edge(), near)
    }

    private func edgeKey(
        at point: CGPoint, keys: [(view: UIView, frame: CGRect)],
        _ overlapsRow: (CGRect) -> Bool, _ overlapsColumn: (CGRect) -> Bool
    ) -> UIView? {
        let inRow = keys.filter { overlapsRow($0.frame) && distance(from: point, to: $0.frame) <= Self.keyEdgeReach }
        if let key = inRow.min(by: { distance(from: point, to: $0.frame) < distance(from: point, to: $1.frame) }) {
            return key.view
        }
        let above = keys.filter {
            overlapsColumn($0.frame) && point.y > $0.frame.maxY && point.y - $0.frame.maxY <= Self.keyBottomReach
        }
        // Only the bottom strip: a key further down in the same column means this is
        // an inner gap, which the two-sided rule above already declined.
        guard !keys.contains(where: { overlapsColumn($0.frame) && $0.frame.minY >= point.y }) else { return nil }
        return above.min(by: { point.y - $0.frame.maxY < point.y - $1.frame.maxY })?.view
    }

    private func collectKeys(in view: UIView, into keys: inout [(view: UIView, frame: CGRect)]) {
        for subview in view.subviews where !subview.isHidden && subview.alpha > 0.01 && subview.isUserInteractionEnabled
        {
            // Class check instead of a Swift protocol `is`: a protocol check scans the conformance table the first time each new view class
            // is seen (SwiftUI has many internal classes), which can stall the first touch for tens of ms; a class check only walks the superclass chain.
            if subview is SkinnedButton || subview is AlternateCharacterKey.CharacterButton {
                if (subview as? UIControl)?.isEnabled != false {
                    keys.append((subview, subview.convert(subview.bounds, to: self)))
                }
            } else {
                collectKeys(in: subview, into: &keys)
            }
        }
    }

    private func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}
