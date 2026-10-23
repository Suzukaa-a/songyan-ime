#if canImport(UIKit)
    import UIKit

    /// Leaf-layer press feedback for UIKit keycaps. No transform, delayed action,
    /// gesture recognizer, display link, or change to the button's hit-test geometry.
    ///
    /// It carries the same physical vocabulary as the SwiftUI keys
    /// (`KeyboardPressPhysics`): the keycap's visual layers scale about the button
    /// centre, sink, and tighten their shadow on touch-down, then settle back with the
    /// shared critically damped spring while colour and shadow ease out. Only
    /// `transform` / `backgroundColor` / `shadowOpacity` / `shadowOffset` are written, and only on the layers handed
    /// in — never `frame`, `bounds` or `position` — so the control's own coordinate
    /// system, tracking containment and the popup geometry are untouched.
    @MainActor
    public final class KeyboardKeyReleaseAnimator {
        private var wasPressed = false
        private var wasPressedVisual = false
        private var pressedColor: CGColor?
        private var pressedShadowOpacity: Float?
        private var pressedShadowOffset: CGSize?
        private static let animationKey = "keyboard.keyRelease"
        private static let shadowOpacityKey = "keyboard.keyReleaseShadowOpacity"
        private static let shadowOffsetKey = "keyboard.keyReleaseShadowOffset"
        private static let pressVisualKey = "keyboard.keyPressVisual"

        public init() {}

        /// Call after applying the current skin to the cap layer. Repeated layout passes
        /// do not restart the release; another press interrupts it immediately.
        public func update(layer: CALayer, isPressed: Bool) {
            if isPressed {
                layer.removeAnimation(forKey: Self.animationKey)
                layer.removeAnimation(forKey: Self.shadowOpacityKey)
                layer.removeAnimation(forKey: Self.shadowOffsetKey)
                pressedColor = layer.backgroundColor
                pressedShadowOpacity = layer.shadowOpacity
                pressedShadowOffset = layer.shadowOffset
            } else if wasPressed {
                layer.removeAnimation(forKey: Self.animationKey)
                layer.removeAnimation(forKey: Self.shadowOpacityKey)
                layer.removeAnimation(forKey: Self.shadowOffsetKey)
                if !UIAccessibility.isReduceMotionEnabled {
                    animate(
                        layer, key: Self.animationKey, keyPath: "backgroundColor",
                        from: pressedColor, to: layer.backgroundColor)
                    animate(
                        layer, key: Self.shadowOpacityKey, keyPath: "shadowOpacity",
                        from: pressedShadowOpacity, to: layer.shadowOpacity)
                    animate(
                        layer, key: Self.shadowOffsetKey, keyPath: "shadowOffset",
                        from: pressedShadowOffset, to: layer.shadowOffset)
                }
                pressedColor = nil
                pressedShadowOpacity = nil
                pressedShadowOffset = nil
            }
            if UIAccessibility.isReduceMotionEnabled {
                layer.removeAnimation(forKey: Self.animationKey)
                layer.removeAnimation(forKey: Self.shadowOpacityKey)
                layer.removeAnimation(forKey: Self.shadowOffsetKey)
            }
            wasPressed = isPressed
        }

        /// Hard-reset the press transform of the given visual layers. Call this
        /// *before* the control lays its subviews out: a frame write while a layer is
        /// transformed is undefined, so every layout pass starts from identity and
        /// `updatePressVisual` re-applies the current state at the end. During a
        /// release the model transform is already identity, so the in-flight release
        /// animation is left alone.
        public func resetPressVisual(layers: [CALayer?]) {
            for layer in layers {
                guard let layer, !CATransform3DIsIdentity(layer.transform) else { continue }
                layer.removeAnimation(forKey: Self.pressVisualKey)
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.transform = CATransform3DIdentity
                CATransaction.commit()
            }
        }

        /// Apply the shared press physics to a keycap's visual layers (cap + labels).
        /// Immediate on touch-down (`KeyboardPressPhysics.pressInAnimation` is nil)
        /// and the shared critically damped spring on release, both driven by Reduce Motion.
        /// `scales == false` keeps the keycap at full size and only sinks it, for a key
        /// whose callout is drawn around its unscaled frame.
        public func updatePressVisual(
            container: CALayer, layers: [CALayer?], isPressed: Bool,
            scales: Bool = true
        ) {
            let reduceMotion = UIAccessibility.isReduceMotionEnabled
            let center = CGPoint(x: container.bounds.midX, y: container.bounds.midY)
            let releasing = wasPressedVisual && !isPressed
            for layer in layers {
                guard let layer else { continue }
                let target = KeyboardPressPhysics.visualTransform(
                    pressed: isPressed,
                    reduceMotion: reduceMotion,
                    containerCenter: center,
                    layerCenter: layer.position,
                    scales: scales)
                if isPressed {
                    layer.removeAnimation(forKey: Self.pressVisualKey)
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    layer.transform = CATransform3DMakeAffineTransform(target)
                    CATransaction.commit()
                } else if releasing {
                    let from = layer.presentation()?.transform ?? layer.transform
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    layer.transform = CATransform3DMakeAffineTransform(target)
                    CATransaction.commit()
                    guard !reduceMotion, !CATransform3DEqualToTransform(from, layer.transform) else { continue }
                    let animation = releaseSpring(keyPath: "transform")
                    animation.fromValue = NSValue(caTransform3D: from)
                    animation.toValue = NSValue(caTransform3D: layer.transform)
                    layer.add(animation, forKey: Self.pressVisualKey)
                }
            }
            wasPressedVisual = isPressed
        }

        private func animate(_ layer: CALayer, key: String, keyPath: String, from: Any?, to: Any?) {
            guard let from, let to else { return }
            let animation = CABasicAnimation(keyPath: keyPath)
            animation.duration = KeyboardPressPhysics.fadeDuration
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animation.fromValue = from
            animation.toValue = to
            layer.add(animation, forKey: key)
        }

        /// Core Animation counterpart of `KeyboardPressPhysics.releaseAnimation`: the same
        /// critically damped spring, played for its natural settling time.
        private func releaseSpring(keyPath: String) -> CASpringAnimation {
            let animation: CASpringAnimation
            if #available(iOS 17.0, macCatalyst 17.0, *) {
                animation = CASpringAnimation(
                    perceptualDuration: KeyboardPressPhysics.releaseDuration,
                    bounce: CGFloat(KeyboardPressPhysics.releaseDesignBounce))
                animation.keyPath = keyPath
            } else {
                let frequency = 2 * CGFloat.pi / CGFloat(KeyboardPressPhysics.releaseDuration)
                animation = CASpringAnimation(keyPath: keyPath)
                animation.mass = 1
                animation.stiffness = frequency * frequency
                animation.damping = 2 * frequency
            }
            animation.duration = animation.settlingDuration
            return animation
        }
    }
#endif
