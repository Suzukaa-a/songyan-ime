import UIKit

/// The letter callout of a pressed key: a bubble joined to the keycap by curved
/// shoulders, filled and shadowed as one shape, like the system keyboard. One view per
/// panel overlay is reused for every press; it appears on touch-down without a fade and
/// stays at least `minimumVisible` after release, unless the next press takes it over.
final class KeyCalloutView: UIView {
    static let minimumVisible: CFTimeInterval = 0.05

    private let shape = CAShapeLayer()
    private let label = UILabel()
    private weak var owner: AnyObject?
    private var shownAt: CFTimeInterval = 0
    private var pendingHide: DispatchWorkItem?

    static func shared(in host: UIView) -> KeyCalloutView {
        if let existing = host.subviews.lazy.compactMap({ $0 as? KeyCalloutView }).first { return existing }
        let view = KeyCalloutView(frame: host.bounds)
        host.addSubview(view)
        return view
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        isHidden = true
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: 2)
        layer.addSublayer(shape)
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.6
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(
        _ text: String, bubble: CGRect, key: CGRect, keyRadius: CGFloat,
        fill: UIColor, textColor: UIColor, border: UIColor, borderWidth: CGFloat,
        font: UIFont, for owner: AnyObject
    ) {
        pendingHide?.cancel()
        pendingHide = nil
        self.owner = owner
        shownAt = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let host = superview {
            frame = host.bounds
            host.bringSubviewToFront(self)
        }
        let (path, joined) = Self.path(bubble: bubble, key: key, bubbleRadius: max(10, keyRadius), keyRadius: keyRadius)
        shape.path = path
        layer.shadowPath = path
        shape.fillColor = fill.cgColor
        // Two overlapping outlines would draw border lines across the overlap.
        shape.strokeColor = borderWidth > 0 && joined ? border.cgColor : nil
        shape.lineWidth = borderWidth
        label.text = text
        label.font = font
        label.textColor = textColor
        label.frame = bubble.insetBy(dx: 2, dy: 2)
        isHidden = false
        CATransaction.commit()
    }

    /// Only the key that showed the callout can hide it; a newer press already owns it.
    func hide(for owner: AnyObject, immediately: Bool) {
        guard self.owner === owner else { return }
        pendingHide?.cancel()
        let remaining = immediately ? 0 : shownAt + Self.minimumVisible - CACurrentMediaTime()
        guard remaining > 0 else {
            pendingHide = nil
            isHidden = true
            self.owner = nil
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.owner === owner else { return }
            self.isHidden = true
            self.owner = nil
            self.pendingHide = nil
        }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: work)
    }

    /// Bubble on top, keycap below, joined by curves that leave the bubble's lower
    /// corners and land on the keycap's sides. When the keyboard's top edge pushes the
    /// bubble down onto the key, the two are drawn as overlapping rounded rectangles.
    static func path(
        bubble: CGRect, key: CGRect, bubbleRadius: CGFloat,
        keyRadius: CGFloat
    ) -> (path: CGPath, joined: Bool) {
        let shoulder = min(8, bubble.height / 4)
        let keyRadius = min(keyRadius, key.width / 2, key.height / 2)
        guard bubble.maxY <= key.minY + 0.5,
            key.maxY - keyRadius >= bubble.maxY + shoulder
        else {
            let path = UIBezierPath(roundedRect: bubble, cornerRadius: bubbleRadius)
            path.append(UIBezierPath(roundedRect: key, cornerRadius: keyRadius))
            return (path.cgPath, false)
        }
        let r = min(bubbleRadius, bubble.width / 2, (bubble.height - shoulder) / 2)
        let neck = bubble.maxY
        let path = UIBezierPath()
        path.move(to: CGPoint(x: bubble.minX, y: bubble.minY + r))
        path.addArc(
            withCenter: CGPoint(x: bubble.minX + r, y: bubble.minY + r), radius: r,
            startAngle: .pi, endAngle: 1.5 * .pi, clockwise: true)
        path.addLine(to: CGPoint(x: bubble.maxX - r, y: bubble.minY))
        path.addArc(
            withCenter: CGPoint(x: bubble.maxX - r, y: bubble.minY + r), radius: r,
            startAngle: 1.5 * .pi, endAngle: 0, clockwise: true)
        path.addLine(to: CGPoint(x: bubble.maxX, y: neck - shoulder))
        path.addCurve(
            to: CGPoint(x: key.maxX, y: neck + shoulder),
            controlPoint1: CGPoint(x: bubble.maxX, y: neck),
            controlPoint2: CGPoint(x: key.maxX, y: neck))
        path.addLine(to: CGPoint(x: key.maxX, y: key.maxY - keyRadius))
        path.addArc(
            withCenter: CGPoint(x: key.maxX - keyRadius, y: key.maxY - keyRadius), radius: keyRadius,
            startAngle: 0, endAngle: 0.5 * .pi, clockwise: true)
        path.addLine(to: CGPoint(x: key.minX + keyRadius, y: key.maxY))
        path.addArc(
            withCenter: CGPoint(x: key.minX + keyRadius, y: key.maxY - keyRadius), radius: keyRadius,
            startAngle: 0.5 * .pi, endAngle: .pi, clockwise: true)
        path.addLine(to: CGPoint(x: key.minX, y: neck + shoulder))
        path.addCurve(
            to: CGPoint(x: bubble.minX, y: neck - shoulder),
            controlPoint1: CGPoint(x: key.minX, y: neck),
            controlPoint2: CGPoint(x: bubble.minX, y: neck))
        path.close()
        return (path.cgPath, true)
    }
}
