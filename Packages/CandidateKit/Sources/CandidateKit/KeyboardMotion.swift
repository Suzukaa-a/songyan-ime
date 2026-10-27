import SwiftUI

/// Shared presentation-only timing. Never wrap engine actions, marked text, or panel
/// height changes in these animations: only the leaf visual property is animated.
///
/// A keycap's travel is a critically damped spring of `KeyboardPressPhysics.releaseDuration`
/// (SwiftUI `spring(duration:bounce:)`, UIKit `CASpringAnimation(perceptualDuration:bounce:)`),
/// played for its natural settling time. Colour and shadow have no mass, so they ease out
/// over `KeyboardPressPhysics.fadeDuration` instead of springing.
public enum KeyboardMotion {
    public static var releaseDuration: TimeInterval { KeyboardPressPhysics.releaseDuration }

    public static func release(reduceMotion: Bool) -> Animation? {
        KeyboardPressPhysics.releaseAnimation(reduceMotion: reduceMotion)
    }

    /// Chrome settle (disclosure / expand / collapse). Same spring as a key release,
    /// so the tools page has no private `easeInOut` duration; immediate under Reduce Motion.
    public static func disclosure(reduceMotion: Bool) -> Animation? {
        release(reduceMotion: reduceMotion)
    }
}

/// The one physical press vocabulary shared by every keycap: SwiftUI keys
/// (`KeyboardPressFeedback` / `KeyboardSelectionPressStyle`) and UIKit keycaps
/// (`KeyboardKeyReleaseAnimator` for letters, digits, side function keys, space,
/// shift, globe and repeating delete) read these constants, so a press feels the
/// same everywhere.
///
/// Contract:
///  - the press is immediate: `pressInAnimation` is nil, the pressed state is
///    applied in the same transaction as touch-down;
///  - letting go is a critically damped spring for movement and an ease-out for
///    colour (movement is immediate under Reduce Motion);
///  - only the keycap scale / vertical sink / shadow and a translucent overlay
///    move. The key and its text are never drawn at a lower opacity, no
///    `compositingGroup()` is used, and the modifier is render-only: the layout
///    frame, the hit region and the alternate popup geometry are untouched.
public enum KeyboardPressPhysics {
    /// Slightly smaller keycap on press.
    public static let pressedScale: CGFloat = 0.955
    /// How far the pressed keycap sinks, in points.
    public static let pressedSink: CGFloat = 1
    /// Darkening overlay drawn over the keycap on press (never over the text
    /// opacity itself; the overlay is its own non-hit-testable layer).
    public static let overlayOpacity: Double = 0.12
    /// The shadow tightens on press: opacity and offset scale by these factors.
    public static let pressedShadowOpacityFactor: Double = 0.35
    public static let pressedShadowOffsetFactor: Double = 0.5
    /// Response of the release spring. Lifting a finger gives the key no momentum,
    /// so the spring is critically damped: it returns without overshoot, and it is
    /// played for its natural settling time so its velocity stays continuous.
    public static let releaseDuration: TimeInterval = 0.12
    public static let releaseDesignBounce: Double = 0
    /// Colour and shadow return with an ease-out of this length.
    public static let fadeDuration: TimeInterval = 0.12
    /// Touch-down is never animated.
    public static let pressInAnimation: Animation? = nil

    /// The one release curve. Prefers the public `spring(duration:bounce:)`; the
    /// `#available` fallback is the same critically damped spring for the package's
    /// macOS 13 floor / Mac Catalyst 16.
    public static func releaseAnimation(reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        if #available(iOS 17.0, macOS 14.0, *) {
            return .spring(duration: releaseDuration, bounce: releaseDesignBounce, blendDuration: 0)
        }
        return .spring(response: releaseDuration, dampingFraction: 1)
    }

    /// The colour/overlay return. Kept under Reduce Motion: a fade is not movement.
    public static let fadeAnimation: Animation = .easeOut(duration: fadeDuration)

    public static func scale(pressed: Bool, reduceMotion: Bool = false) -> CGFloat {
        (pressed && !reduceMotion) ? pressedScale : 1
    }

    public static func sink(pressed: Bool, reduceMotion: Bool = false) -> CGFloat {
        (pressed && !reduceMotion) ? pressedSink : 0
    }

    /// Render-only transform for one UIKit keycap layer pressed inside a shared
    /// container (the button). The layer is scaled about its own centre and
    /// translated so the *container's* centre is the scale anchor:
    ///
    ///     p' = containerCentre + scale * (p - containerCentre) + (0, sink)
    ///
    /// expressed about the layer's own centre for `CALayer.transform`. Only the
    /// layer's `transform` is written — never `frame`, `bounds` or `position` —
    /// so the button's own hit testing, touch tracking, key geometry and the
    /// alternate popup placement are untouched.
    public static func visualTransform(
        pressed: Bool, reduceMotion: Bool,
        containerCenter: CGPoint,
        layerCenter: CGPoint,
        scales: Bool = true
    ) -> CGAffineTransform {
        guard pressed, !reduceMotion else { return .identity }
        let s = scales ? pressedScale : 1
        let dx = containerCenter.x + s * (layerCenter.x - containerCenter.x) - layerCenter.x
        let dy = containerCenter.y + s * (layerCenter.y - containerCenter.y) - layerCenter.y + pressedSink
        return CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: dx, ty: dy)
    }

    public static func shadowOpacity(from rest: Float) -> Float {
        rest * Float(pressedShadowOpacityFactor)
    }

    public static func shadowOffsetY(from rest: CGFloat) -> CGFloat {
        rest * pressedShadowOffsetFactor
    }
}

/// The production panel does not animate the whole key area on page/language
/// changes: an ancestor `keyframeAnimator` / `visualEffect` would also wrap UIKit
/// key views, while their touch owners would not move with the rendered caps.
/// Only individual keycap releases animate; candidate glyphs and the full key
/// area never pass through an animated ancestor surface.

/// Render-only press movement shared by every keycap: immediate sink + scale on
/// touch-down, critically damped spring on release, nothing at all under Reduce Motion.
/// It touches no layout, no opacity and no compositing group; `KeyboardPressStyle`
/// pairs it with the keycap-shaped overlay and `keyboardPressFeedback` with a
/// full-bounds overlay.
private struct KeyboardPressMovement: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let pressed: Bool

    func body(content: Content) -> some View {
        content
            // The sink is applied *before* the scale so the SwiftUI result
            // matches `KeyboardPressPhysics.visualTransform` exactly.
            .offset(y: KeyboardPressPhysics.sink(pressed: pressed, reduceMotion: reduceMotion))
            .scaleEffect(KeyboardPressPhysics.scale(pressed: pressed, reduceMotion: reduceMotion))
            .animation(
                pressed
                    ? KeyboardPressPhysics.pressInAnimation
                    : KeyboardPressPhysics.releaseAnimation(reduceMotion: reduceMotion),
                value: pressed)
    }
}

private struct KeyboardPressFeedback: ViewModifier {
    let pressed: Bool

    func body(content: Content) -> some View {
        // The label itself is never drawn at a lower opacity: the darkening is
        // its own non-hit-testable overlay, and no compositing group is created.
        content
            .overlay {
                Color.primary.opacity(pressed ? KeyboardPressPhysics.overlayOpacity : 0)
                    .allowsHitTesting(false)
                    .animation(pressed ? nil : KeyboardPressPhysics.fadeAnimation, value: pressed)
            }
            .modifier(KeyboardPressMovement(pressed: pressed))
    }
}

public extension View {
    /// iOS 26 adds an automatic soft scroll-edge blur. Candidate and spelling
    /// glyphs must remain fully legible through a drag, including at the edge.
    @ViewBuilder
    func sharpCandidateScrollEdges() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.scrollEdgeEffectHidden(true, for: .all)
        } else {
            self
        }
    }

    /// Apply to a label with its intended clipping shape, never to a whole keyboard.
    /// The label is never faded: the darkening overlay and the sink/scale are
    /// render-only.
    func keyboardPressFeedback(isPressed: Bool) -> some View {
        modifier(KeyboardPressFeedback(pressed: isPressed))
    }

    /// The shared sink/scale press movement without any overlay, for callers that
    /// draw their own keycap-shaped highlight (e.g. `KeyboardPressStyle`).
    func keyboardPressMovement(isPressed: Bool) -> some View {
        modifier(KeyboardPressMovement(pressed: isPressed))
    }
}

/// Up/down controls share a single SF Symbol identity. iOS symbol replacement
/// must not crossfade the two diagonals into an ×, even under an ancestor animation.
/// Direction is intentionally immediate in both normal and Reduce Motion modes.
@available(iOS 17.0, macOS 14.0, *)
public struct KeyboardControlSymbol: View {
    public let systemName: String

    public init(systemName: String) { self.systemName = systemName }

    public var body: some View {
        Image(systemName: systemName == "chevron.down" ? "chevron.up" : systemName)
            .symbolEffectsRemoved()
            .rotationEffect(.degrees(systemName == "chevron.down" ? 180 : 0))
            .transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
    }
}

/// Chrome (non-keycap) press **timing**: the same immediate touch-down, the same
/// short release spring and the same Reduce Motion rule as the keycaps. It
/// deliberately paints no visual — the shared layer must not force one highlight
/// shape or colour onto controls whose local shape/corner radius/skin colour
/// differ. A caller that wants the shared darkening amount adds
/// `keyboardPressHighlight(...)` with its own shape and `ShapeStyle`.
private struct KeyboardChromePressTiming: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let pressed: Bool

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .animation(
                pressed
                    ? KeyboardPressPhysics.pressInAnimation
                    : KeyboardMotion.release(reduceMotion: reduceMotion),
                value: pressed)
    }
}

/// The shared pressed-highlight **amount**, drawn in the caller's own shape and
/// colour (skin `pressed`/`selected` colour, the keycap or chip corner radius).
/// Non-hit-testable, so it can never move the control's touch region.
private struct KeyboardPressHighlight<S: ShapeStyle>: ViewModifier {
    let pressed: Bool
    let cornerRadius: CGFloat
    let style: S

    func body(content: Content) -> some View {
        content.overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(style)
                .opacity(pressed ? KeyboardPressPhysics.overlayOpacity : 0)
                .allowsHitTesting(false)
                .animation(pressed ? nil : KeyboardPressPhysics.fadeAnimation, value: pressed)
        }
    }
}

public extension View {
    /// Apply to a chrome control's label (tools row, chip, toolbar button).
    /// Timing and hit shape only — no visual, so the control keeps its local
    /// rounded shape and skin colour.
    func keyboardChromePressTiming(isPressed: Bool) -> some View {
        modifier(KeyboardChromePressTiming(pressed: isPressed))
    }

    /// The shared pressed-darkening amount in the caller's own rounded shape and
    /// `ShapeStyle` (e.g. `appearance.color("pressed")`), so a rounded card/chip is
    /// never covered by a square overlay.
    func keyboardPressHighlight<S: ShapeStyle>(
        isPressed: Bool,
        cornerRadius: CGFloat,
        style: S
    ) -> some View {
        modifier(KeyboardPressHighlight(pressed: isPressed, cornerRadius: cornerRadius, style: style))
    }
}

/// The one press style for chrome controls: shared timing, no forced visual.
/// Callers pair it with `keyboardPressHighlight(...)` when they want the shared
/// amount, or with their own pressed background.
public struct KeyboardChromePressStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label.keyboardChromePressTiming(isPressed: configuration.isPressed)
    }
}

/// Candidate/menu rows get the same immediate-down, short-release vocabulary.
public struct KeyboardSelectionPressStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label.keyboardPressFeedback(isPressed: configuration.isPressed)
    }
}
