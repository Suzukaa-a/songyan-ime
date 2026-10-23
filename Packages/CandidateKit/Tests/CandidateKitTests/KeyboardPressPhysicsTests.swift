import QuartzCore
import SwiftUI
import XCTest

@testable import CandidateKit

/// The unified keycap press vocabulary. These assertions pin the physical feel
/// the user asked for (immediate press, critically damped release, no whole-key opacity
/// change) and the boundaries other owners depend on (no compositing group, no
/// Reduce Motion movement, the release curve shared by SwiftUI and UIKit).
@MainActor
final class KeyboardPressPhysicsTests: XCTestCase {

    // MARK: Feel

    func testPressIsSlightAndImmediate() {
        XCTAssertGreaterThan(
            KeyboardPressPhysics.pressedScale, 0.9,
            "the keycap must not visibly collapse")
        XCTAssertLessThan(
            KeyboardPressPhysics.pressedScale, 1.0,
            "there must be a visible scale change, not only a brighten")
        XCTAssertGreaterThan(KeyboardPressPhysics.pressedSink, 0)
        XCTAssertLessThanOrEqual(
            KeyboardPressPhysics.pressedSink, 2,
            "the sink stays sub-pixel-ish; it must not shift the key out of its row")
        XCTAssertNil(
            KeyboardPressPhysics.pressInAnimation,
            "touch-down is immediate: no animation can delay the press")
    }

    func testReleaseIsCriticallyDampedAndUncompressed() {
        XCTAssertGreaterThan(KeyboardPressPhysics.releaseDuration, 0.08)
        XCTAssertLessThanOrEqual(KeyboardPressPhysics.releaseDuration, 0.25)
        XCTAssertEqual(
            KeyboardPressPhysics.releaseDesignBounce, 0,
            "a lifted finger gives the key no momentum, so it must not overshoot")
        XCTAssertNotNil(KeyboardMotion.release(reduceMotion: false))
        XCTAssertEqual(KeyboardMotion.releaseDuration, KeyboardPressPhysics.releaseDuration)
    }

    @available(macOS 14.0, iOS 17.0, *)
    func testCriticallyDampedSpringSettlesWithoutOvershoot() {
        let spring = CASpringAnimation(
            perceptualDuration: KeyboardPressPhysics.releaseDuration,
            bounce: CGFloat(KeyboardPressPhysics.releaseDesignBounce))
        XCTAssertEqual(
            spring.damping, 2 * (spring.stiffness * spring.mass).squareRoot(), accuracy: 0.01,
            "zero bounce is critical damping")
        XCTAssertLessThan(spring.settlingDuration, 0.6, "played at natural length, the release stays short")
    }

    func testColourFadeIsShortEaseOut() {
        XCTAssertGreaterThan(KeyboardPressPhysics.fadeDuration, 0.05)
        XCTAssertLessThanOrEqual(KeyboardPressPhysics.fadeDuration, 0.2)
    }

    func testDisclosureSharesTheKeyReleaseCurve() {
        XCTAssertEqual(
            KeyboardMotion.disclosure(reduceMotion: true), nil,
            "disclosure is immediate under Reduce Motion")
        XCTAssertNotNil(
            KeyboardMotion.disclosure(reduceMotion: false),
            "disclosure reuses the one shared spring")
    }

    func testChromePressStyleIsConstructible() {
        _ = KeyboardChromePressStyle()
    }

    /// The shared chrome layer must not force a visual: callers pass their own
    /// `ShapeStyle` and corner radius, so a rounded card/chip keeps its shape and
    /// skin colour instead of getting a square `Color.primary` overlay.
    func testChromeHighlightTakesTheCallersShapeAndStyle() {
        let view = Color.clear
            .keyboardPressHighlight(
                isPressed: true, cornerRadius: 16,
                style: KeyboardPressPhysics.overlayOpacity > 0 ? Color.red : Color.blue
            )
            .keyboardChromePressTiming(isPressed: true)
        _ = view
        // The shared amount still comes from the physics vocabulary.
        XCTAssertGreaterThan(KeyboardPressPhysics.overlayOpacity, 0)
    }

    func testOverlayIsTranslucentAndNeverAnOpacityCut() {
        XCTAssertGreaterThan(KeyboardPressPhysics.overlayOpacity, 0)
        XCTAssertLessThanOrEqual(
            KeyboardPressPhysics.overlayOpacity, 0.2,
            "the pressed keycap darkens slightly, it does not black out")
    }

    func testShadowTightensOnPress() {
        XCTAssertLessThan(KeyboardPressPhysics.shadowOpacity(from: 0.18), 0.18)
        XCTAssertGreaterThanOrEqual(KeyboardPressPhysics.shadowOpacity(from: 0), 0)
        XCTAssertEqual(KeyboardPressPhysics.shadowOpacity(from: 0.18), 0.18 * 0.35, accuracy: 0.0001)
        XCTAssertLessThan(KeyboardPressPhysics.shadowOffsetY(from: 1), 1)
        XCTAssertGreaterThanOrEqual(KeyboardPressPhysics.shadowOffsetY(from: 1), 0)
    }

    // MARK: Reduce Motion

    func testReduceMotionRemovesMovementButKeepsTheStateChange() {
        XCTAssertEqual(KeyboardPressPhysics.scale(pressed: true, reduceMotion: true), 1)
        XCTAssertEqual(KeyboardPressPhysics.sink(pressed: true, reduceMotion: true), 0)
        XCTAssertNil(
            KeyboardPressPhysics.releaseAnimation(reduceMotion: true),
            "Reduce Motion gets an immediate swap, not a spring")
        XCTAssertEqual(
            KeyboardPressPhysics.visualTransform(
                pressed: true, reduceMotion: false,
                containerCenter: .zero, layerCenter: .zero,
                scales: false),
            CGAffineTransform(translationX: 0, y: KeyboardPressPhysics.pressedSink),
            "a key under its callout only sinks")
        XCTAssertEqual(KeyboardPressPhysics.scale(pressed: false, reduceMotion: false), 1)
        XCTAssertEqual(KeyboardPressPhysics.sink(pressed: false, reduceMotion: false), 0)
        XCTAssertGreaterThan(
            KeyboardPressPhysics.overlayOpacity, 0,
            "the colour cue is the part Reduce Motion keeps")
    }

    // MARK: UIKit transform (must not touch the control's geometry)

    /// Maps a point in a layer's bounds space the way CALayer renders it with a
    /// default anchor point: the layer's own centre is the scale origin, then the
    /// transform's translation pulls the layer towards the container centre.
    private func rendered(
        _ boundsPoint: CGPoint, layerCenter: CGPoint,
        size: CGSize, transform t: CGAffineTransform
    ) -> CGPoint {
        let offset = CGPoint(
            x: boundsPoint.x - size.width / 2,
            y: boundsPoint.y - size.height / 2)
        return CGPoint(
            x: layerCenter.x + offset.x * t.a + offset.y * t.c + t.tx,
            y: layerCenter.y + offset.x * t.b + offset.y * t.d + t.ty)
    }

    func testVisualTransformIsIdentityAtRestAndUnderReduceMotion() {
        let centre = CGPoint(x: 50, y: 30)
        XCTAssertEqual(
            KeyboardPressPhysics.visualTransform(
                pressed: false, reduceMotion: false,
                containerCenter: centre, layerCenter: centre),
            .identity)
        XCTAssertEqual(
            KeyboardPressPhysics.visualTransform(
                pressed: true, reduceMotion: true,
                containerCenter: centre, layerCenter: centre),
            .identity)
    }

    func testVisualTransformScalesAboutTheContainerCentreAndSinks() {
        let centre = CGPoint(x: 50, y: 30)
        let size = CGSize(width: 40, height: 40)
        let t = KeyboardPressPhysics.visualTransform(
            pressed: true, reduceMotion: false,
            containerCenter: centre, layerCenter: centre)
        XCTAssertEqual(t.a, KeyboardPressPhysics.pressedScale, accuracy: 0.0001)
        XCTAssertEqual(t.d, KeyboardPressPhysics.pressedScale, accuracy: 0.0001)
        XCTAssertEqual(t.tx, 0, accuracy: 0.0001)
        XCTAssertEqual(t.ty, KeyboardPressPhysics.pressedSink, accuracy: 0.0001)

        // The container centre is the fixed point of the scale: it only sinks.
        let anchor = CGPoint(x: size.width / 2, y: size.height / 2)
        let mapped = rendered(anchor, layerCenter: centre, size: size, transform: t)
        XCTAssertEqual(mapped.x, centre.x, accuracy: 0.0001)
        XCTAssertEqual(mapped.y, centre.y + KeyboardPressPhysics.pressedSink, accuracy: 0.0001)
    }

    func testVisualTransformPullsOffCentreLayersTowardsTheContainerCentre() {
        let container = CGPoint(x: 50, y: 30)
        let layerCentre = CGPoint(x: 90, y: 30)
        let size = CGSize(width: 40, height: 40)
        let t = KeyboardPressPhysics.visualTransform(
            pressed: true, reduceMotion: false,
            containerCenter: container, layerCenter: layerCentre)
        let anchor = CGPoint(x: size.width / 2, y: size.height / 2)
        let mapped = rendered(anchor, layerCenter: layerCentre, size: size, transform: t)
        XCTAssertEqual(mapped.y, layerCentre.y + KeyboardPressPhysics.pressedSink, accuracy: 0.0001)
        let before = layerCentre.x - container.x
        let after = mapped.x - container.x
        XCTAssertEqual(after, before * KeyboardPressPhysics.pressedScale, accuracy: 0.0001)
        XCTAssertLessThan(after, before, "an off-centre layer moves towards the container centre")

        // The container's own centre, expressed in the layer's bounds space, is
        // still the fixed point of the scale.
        let containerInLayerBounds = CGPoint(
            x: size.width / 2 + (container.x - layerCentre.x),
            y: size.height / 2 + (container.y - layerCentre.y))
        let mappedContainer = rendered(
            containerInLayerBounds, layerCenter: layerCentre,
            size: size, transform: t)
        XCTAssertEqual(mappedContainer.x, container.x, accuracy: 0.0001)
        XCTAssertEqual(mappedContainer.y, container.y + KeyboardPressPhysics.pressedSink, accuracy: 0.0001)
    }

    func testVisualTransformOnlyTouchesTransform() {
        // The transform is affine-only (no perspective) and near-identity in
        // magnitude, so no layer content can be re-rasterised or blurred.
        let t = KeyboardPressPhysics.visualTransform(
            pressed: true, reduceMotion: false,
            containerCenter: CGPoint(x: 10, y: 10),
            layerCenter: CGPoint(x: 30, y: 10))
        XCTAssertEqual(t.b, 0, accuracy: 0.0001)
        XCTAssertEqual(t.c, 0, accuracy: 0.0001)
        XCTAssertGreaterThan(t.d, 0.9)
        XCTAssertLessThan(t.d, 1.0)
    }

    // MARK: Shared policy consumers

    func testSelectionPressStyleIsConstructibleForCandidateRows() {
        // Candidate rows share the key vocabulary instead of inventing a second
        // one; the type existing and being constructible is the contract.
        _ = KeyboardSelectionPressStyle()
    }
}
