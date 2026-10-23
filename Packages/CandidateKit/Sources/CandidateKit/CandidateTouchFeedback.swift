import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

// MARK: - Candidate touch feedback (shared by the collapsed strip, expanded list and top-bar controls)
//
// A candidate cell gets an inset rounded fill beneath the glyphs while pressed. Pressing the glyphs
// themselves with scale/opacity re-samples them offscreen during scroll drags and darkens the row,
// so the fill is the only touch feedback:
//   * it appears immediately on touch-down (same `pressInAnimation = nil` as key caps) and fades out
//     with the shared release timing; immediately under Reduce Motion;
//   * it is drawn only in `background`: glyphs stay natively rasterized, fully opaque, unscaled and
//     outside any compositing group;
//   * it is inset within the hit region, which (`.frame` + `.contentShape`) never changes;
//   * strength follows the key-cap press darkening and increases under Increase Contrast.

/// Geometry and strength of candidate touch feedback and its visual pill (render-agnostic, unit-testable).
public enum CandidateTouchMetrics {
    /// Corner radius of the press fill and control chip (matches the existing 8pt radius of top-bar controls).
    public static let cornerRadius: CGFloat = 8
    /// Gap between pill and hit region top/bottom: 40pt word row -> 32pt pill; 32pt reading row -> 24pt.
    public static let verticalInset: CGFloat = 4
    /// Left/right gap between a candidate pill and its hit region: adjacent pressed candidates stay distinguishable.
    public static let horizontalInset: CGFloat = 1
    /// Visible chip width of the top-bar icon controls (expand/collapse/retry); the hit region stays 44pt.
    public static let controlChipWidth: CGFloat = 32
    /// Hit width (minimum touch width) of the top-bar icon controls.
    public static let controlHitWidth: CGFloat = 44

    /// Hit height to visible pill height (always <= the hit region; 0 for invalid input).
    public static func pillHeight(hitHeight: CGFloat) -> CGFloat {
        guard hitHeight.isFinite, hitHeight > 0 else { return 0 }
        return max(0, hitHeight - verticalInset * 2)
    }

    /// Horizontal inset of a control's press fill so it coincides exactly with the visible chip.
    public static var controlHorizontalInset: CGFloat {
        max(0, (controlHitWidth - controlChipWidth) / 2)
    }

    /// Press fill strength: the press-darkening amount shared with key caps; doubled under Increase Contrast.
    public static func pressedOpacity(increasedContrast: Bool) -> Double {
        KeyboardPressPhysics.overlayOpacity * (increasedContrast ? 2 : 1)
    }

    /// Strength of the highlight indicator line (the candidate the space bar would commit); opaque under Increase Contrast.
    public static func indicatorOpacity(increasedContrast: Bool) -> Double {
        increasedContrast ? 1 : 0.65
    }

    /// No animation on press; release follows the key-cap release timing; immediate under Reduce Motion.
    public static func highlightAnimation(pressed: Bool, reduceMotion: Bool) -> Animation? {
        pressed ? KeyboardPressPhysics.pressInAnimation : KeyboardMotion.release(reduceMotion: reduceMotion)
    }
}

/// Press style for candidate/reading choices: an inset rounded fill beneath the glyphs.
///
/// Changes drawing only, not layout: the caller's label decides the hit region (`.frame` + `.contentShape`).
@available(iOS 17.0, macOS 14.0, *)
public struct CandidatePressStyle: ButtonStyle {
    public var tint: Color
    public var horizontalInset: CGFloat
    public var extraTopInset: CGFloat
    public var extraBottomInset: CGFloat

    /// - Parameters:
    ///   - tint: base color of the fill (usually the skin's candidate foreground, lightened by the shared strength);
    ///   - horizontalInset: horizontal inset of the fill relative to the hit region;
    ///   - extraTopInset / extraBottomInset: extra top/bottom inset when content shifts down/up, so the
    ///     fill follows the moved glyphs while the hit region stays put.
    public init(
        tint: Color, horizontalInset: CGFloat = CandidateTouchMetrics.horizontalInset,
        extraTopInset: CGFloat = 0, extraBottomInset: CGFloat = 0
    ) {
        self.tint = tint
        self.horizontalInset = horizontalInset
        self.extraTopInset = extraTopInset
        self.extraBottomInset = extraBottomInset
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label.candidatePressHighlight(
            isPressed: configuration.isPressed, tint: tint,
            horizontalInset: horizontalInset,
            extraTopInset: extraTopInset,
            extraBottomInset: extraBottomInset)
    }
}

@available(iOS 17.0, macOS 14.0, *)
private struct CandidatePressHighlight: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    let pressed: Bool
    let tint: Color
    let horizontalInset: CGFloat
    var extraTopInset: CGFloat = 0
    var extraBottomInset: CGFloat = 0

    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: CandidateTouchMetrics.cornerRadius, style: .continuous)
                .fill(
                    tint.opacity(
                        pressed
                            ? CandidateTouchMetrics.pressedOpacity(increasedContrast: contrast == .increased) : 0)
                )
                .padding(.top, CandidateTouchMetrics.verticalInset + max(0, extraTopInset))
                .padding(.bottom, CandidateTouchMetrics.verticalInset + max(0, extraBottomInset))
                .padding(.horizontal, max(0, horizontalInset))
                // Only this backing animates; the glyph above it never changes.
                .animation(
                    CandidateTouchMetrics.highlightAnimation(
                        pressed: pressed,
                        reduceMotion: reduceMotion),
                    value: pressed
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

@available(iOS 17.0, macOS 14.0, *)
extension View {
    /// The press fill (the drawing core of `CandidatePressStyle`; tests drive `isPressed` directly).
    func candidatePressHighlight(
        isPressed: Bool, tint: Color,
        horizontalInset: CGFloat = CandidateTouchMetrics.horizontalInset,
        extraTopInset: CGFloat = 0, extraBottomInset: CGFloat = 0
    ) -> some View {
        modifier(
            CandidatePressHighlight(
                pressed: isPressed, tint: tint, horizontalInset: horizontalInset,
                extraTopInset: extraTopInset, extraBottomInset: extraBottomInset))
    }
}

// MARK: - Tap confirmation flash (independent of content lifetime)
//
// Committing a candidate, advancing to the next segment or narrowing readings usually replaces the
// tapped cell in the same pass, and the scroll container delays the pressed state, so a quick tap
// may never show the press fill. The flash is drawn on the panel's own non-interactive overlay at
// the tapped cell's press-fill geometry and fades out by itself; layout and hit regions are untouched.

private struct KeyboardFlashSurfaceKey: EnvironmentKey {
    static var defaultValue: AnyObject? { nil }
}

public extension EnvironmentValues {
    /// Panel overlay (a UIKit `UIView`); when nil there is no flash and the press fill is unchanged.
    var keyboardFlashSurface: AnyObject? {
        get { self[KeyboardFlashSurfaceKey.self] }
        set { self[KeyboardFlashSurfaceKey.self] = newValue }
    }
}

/// Candidate/reading selection style: `CandidatePressStyle`'s press fill plus a confirmation flash after the tap.
@available(iOS 17.0, macOS 14.0, *)
public struct CandidateTapStyle: PrimitiveButtonStyle {
    public var press: CandidatePressStyle

    public init(
        tint: Color, horizontalInset: CGFloat = CandidateTouchMetrics.horizontalInset,
        extraTopInset: CGFloat = 0, extraBottomInset: CGFloat = 0
    ) {
        press = CandidatePressStyle(
            tint: tint, horizontalInset: horizontalInset,
            extraTopInset: extraTopInset, extraBottomInset: extraBottomInset)
    }

    public func makeBody(configuration: Configuration) -> some View {
        CandidateTapBody(configuration: configuration, press: press)
    }
}

@available(iOS 17.0, macOS 14.0, *)
private struct CandidateTapBody: View {
    let configuration: PrimitiveButtonStyleConfiguration
    let press: CandidatePressStyle
    @Environment(\.keyboardFlashSurface) private var surface
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var anchor = KeyboardTapFlash.Anchor()

    var body: some View {
        Button {
            anchor.flash(
                on: surface, tint: press.tint,
                opacity: KeyboardTapFlash.opacity(increasedContrast: contrast == .increased),
                insets: .init(
                    top: CandidateTouchMetrics.verticalInset + max(0, press.extraTopInset),
                    leading: max(0, press.horizontalInset),
                    bottom: CandidateTouchMetrics.verticalInset + max(0, press.extraBottomInset),
                    trailing: max(0, press.horizontalInset)))
            configuration.trigger()
        } label: {
            configuration.label.background(KeyboardTapFlash.AnchorView(anchor: anchor))
        }
        .buttonStyle(press)
    }
}

public enum KeyboardTapFlash {
    /// The flash holds briefly before fading: long enough to be seen after the content is replaced, short enough not to slow successive taps.
    public static let holdDuration: TimeInterval = 0.07
    public static let fadeDuration: TimeInterval = 0.2

    /// Slightly stronger than the press fill: it confirms independently of the cell, not a held state.
    public static func opacity(increasedContrast: Bool) -> Double {
        CandidateTouchMetrics.pressedOpacity(increasedContrast: increasedContrast) * 1.5
    }

    /// Remembers the tapped cell's position in UIKit; read only at tap time, not part of rendering.
    @MainActor
    public final class Anchor {
        #if canImport(UIKit)
            weak var view: UIView?
        #endif
        public init() {}

        func flash(on surface: AnyObject?, tint: Color, opacity: Double, insets: EdgeInsets) {
            #if canImport(UIKit)
                guard let view else { return }
                let bounds = view.bounds.inset(
                    by: UIEdgeInsets(
                        top: insets.top, left: insets.leading,
                        bottom: insets.bottom, right: insets.trailing))
                KeyboardTapFlash.flash(
                    bounds, from: view, on: surface as? UIView,
                    color: UIColor(tint).withAlphaComponent(CGFloat(opacity)))
            #endif
        }
    }

    #if canImport(UIKit)
        struct AnchorView: UIViewRepresentable {
            let anchor: Anchor
            func makeUIView(context: Context) -> UIView {
                let view = UIView()
                view.isUserInteractionEnabled = false
                view.isAccessibilityElement = false
                anchor.view = view
                return view
            }
            func updateUIView(_ view: UIView, context: Context) { anchor.view = view }
        }

        /// Adds a non-interactive rounded flash at `rect` (in `source` coordinates)
        /// to the panel overlay and removes it after it fades.
        @MainActor
        public static func flash(
            _ rect: CGRect, from source: UIView, on surface: UIView?, color: UIColor,
            cornerRadius: CGFloat = CandidateTouchMetrics.cornerRadius
        ) {
            guard let surface, let window = surface.window, source.window === window,
                rect.width > 0, rect.height > 0
            else { return }
            let flash = UIView(frame: source.convert(rect, to: surface))
            flash.isUserInteractionEnabled = false
            flash.isAccessibilityElement = false
            flash.backgroundColor = color
            flash.layer.cornerRadius = cornerRadius
            flash.layer.cornerCurve = .continuous
            surface.addSubview(flash)
            UIView.animate(
                withDuration: fadeDuration, delay: holdDuration,
                options: [.curveEaseOut, .allowUserInteraction]
            ) {
                flash.alpha = 0
            } completion: { _ in
                flash.removeFromSuperview()
            }
        }
    #else
        struct AnchorView: View {
            let anchor: Anchor
            var body: some View { Color.clear }
        }
    #endif
}
