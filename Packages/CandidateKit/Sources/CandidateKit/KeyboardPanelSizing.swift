import OSLog
import SwiftUI

/// Process-lifetime deduplication plus a rolling rate limit. Keys are only retained
/// when emitted; no eviction can make alternating fitting queries noisy again.
struct KeyboardGeometryLogLimiter {
    static let capacity = 128
    static let windowLimit = 20
    static let windowSeconds: TimeInterval = 10
    private(set) var keys: Set<String> = []
    private var timestamps: [TimeInterval] = []

    mutating func admit(_ key: String, now: TimeInterval) -> Bool {
        guard now.isFinite, !keys.contains(key), keys.count < Self.capacity else { return false }
        timestamps.removeAll { now - $0 >= Self.windowSeconds }
        guard timestamps.count < Self.windowLimit else { return false }
        keys.insert(key)
        timestamps.append(now)
        return true
    }
}

@MainActor
public enum KeyboardGeometryDiagnostics {
    /// Opt in before launching the extension. Read once, avoiding preferences I/O
    /// in layout/fitting loops. Off by default, including normal release launches.
    public static let isEnabled = UserDefaults.standard.bool(forKey: "keyboard.geometryDiagnosticsEnabled")
    public static let isPlacementTracingEnabled =
        isEnabled && UserDefaults.standard.bool(forKey: "keyboard.geometryPlacementTracingEnabled")
    private static var placementLines = 0
    private static let placementLogger = Logger(subsystem: "app.songyan.ime", category: "KeyboardPlacement")
    private static var limiter = KeyboardGeometryLogLimiter()
    private static let logger = Logger(subsystem: "app.songyan.ime", category: "KeyboardGeometry")

    public static func emit(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        // A bounded key also bounds retained diagnostic text (128 * 1024 chars).
        let key = String(message().prefix(1024))
        guard limiter.admit(key, now: ProcessInfo.processInfo.systemUptime) else { return }
        logger.debug("\(key, privacy: .public)")
    }

    static func placement(_ message: @autoclosure () -> String) {
        guard isPlacementTracingEnabled, placementLines < 128 else { return }
        placementLines += 1
        let line = String(message().prefix(1024))
        placementLogger.debug("\(line, privacy: .public)")
    }
}

public extension View {
    /// Constrain the complete state surface, not only its ready branch. Loading
    /// and error views may fill this proposal but cannot request the host's entire
    /// available screen height. No clipping, delayed display or transition mask.
    func keyboardPanelHeight(_ height: CGFloat) -> some View {
        frame(maxWidth: .infinity)
            .frame(height: height, alignment: .top)
    }
}

/// Requested heights and deferred receipts belong to one presentation, not the view lifetime.
public struct KeyboardPanelHeightState: Sendable {
    public private(set) var panelHeight: Double
    public private(set) var revision: UInt64 = 0
    public private(set) var isActive = false
    public private(set) var requestedHeights: [Double] = []
    private static let capacity = 8

    public init(height: Double) {
        panelHeight = height
    }

    public mutating func beginPresentation(height: Double) {
        guard height.isFinite, height > 0 else { return }
        revision &+= 1
        isActive = true
        requestedHeights.removeAll(keepingCapacity: true)
        panelHeight = height
        record(height)
    }

    public mutating func endPresentation() {
        isActive = false
        requestedHeights.removeAll(keepingCapacity: true)
    }

    @discardableResult
    public mutating func setPanelHeight(_ height: Double) -> Bool {
        guard height.isFinite, height > 0, panelHeight != height else { return false }
        panelHeight = height
        if isActive { record(height) }
        return true
    }

    public func accepts(revision: UInt64) -> Bool {
        isActive && self.revision == revision
    }

    public func retainedHeight(boundsHeight: Double, attachedToWindow: Bool) -> Double? {
        guard isActive, attachedToWindow, boundsHeight.isFinite,
            abs(boundsHeight - panelHeight) >= 0.5,
            requestedHeights.contains(where: { abs($0 - boundsHeight) < 0.5 })
        else { return nil }
        return boundsHeight
    }

    private mutating func record(_ height: Double) {
        requestedHeights.removeAll { abs($0 - height) < 0.5 }
        requestedHeights.append(height)
        if requestedHeights.count > Self.capacity {
            requestedHeights.removeFirst(requestedHeights.count - Self.capacity)
        }
    }
}

#if canImport(UIKit)
    import UIKit

    /// The system's self-sizing query and Auto Layout read the same explicit budget.
    /// Child hosting content (including an unbounded loading view) never chooses the
    /// external keyboard height. UIKit still owns horizontal placement and transitions.
    @MainActor
    open class KeyboardPanelInputView: UIInputView {
        private var heightState: KeyboardPanelHeightState
        public var panelHeight: CGFloat { CGFloat(heightState.panelHeight) }
        public private(set) var budgetHeightConstraint: NSLayoutConstraint!
        public var requestedPanelHeights: [CGFloat] { heightState.requestedHeights.map { CGFloat($0) } }
        public var presentationRevision: UInt64 { heightState.revision }

        public func acceptsPresentation(_ revision: UInt64) -> Bool {
            heightState.accepts(revision: revision)
        }

        /// Only an earlier request from this presentation can be a retained height.
        public var retainedPresentedHeight: CGFloat? {
            heightState.retainedHeight(boundsHeight: Double(bounds.height), attachedToWindow: window != nil)
                .map { CGFloat($0) }
        }
        private var recordedOversizedHeights: Set<Int> = []

        open override var frame: CGRect {
            didSet { recordOversizedPlacement("setFrame") }
        }

        open override var bounds: CGRect {
            didSet { recordOversizedPlacement("setBounds") }
        }

        open override func layoutSubviews() {
            super.layoutSubviews()
            recordOversizedPlacement("layoutSubviews")
        }

        /// Bounded dump of this view's own layer tree: class, frame, hidden state,
        /// opacity and background colour. Diagnostic only (opt-in, ≤ 24 lines);
        /// reads nothing but view state and never mutates layout.
        public func dumpInputViewHierarchy(_ reason: String) {
            var lines = 0
            func describe(_ node: UIView, depth: Int) {
                guard lines < 24, depth < 4 else { return }
                lines += 1
                let color = node.backgroundColor.map { "\($0)" } ?? "nil"
                KeyboardGeometryDiagnostics.placement(
                    "hierarchy[\(reason)] d=\(depth) \(type(of: node)) frame=\(node.frame) hidden=\(node.isHidden) alpha=\(node.alpha) opaque=\(node.isOpaque) bg=\(color) clips=\(node.clipsToBounds)"
                )
                for child in node.subviews { describe(child, depth: depth + 1) }
            }
            describe(self, depth: 0)
        }

        private func recordOversizedPlacement(_ event: String) {
            guard KeyboardGeometryDiagnostics.isPlacementTracingEnabled, window != nil,
                bounds.height > panelHeight + 50, recordedOversizedHeights.count < 4
            else { return }
            let height = Int(bounds.height.rounded())
            guard recordedOversizedHeights.insert(height).inserted else { return }
            dumpInputViewHierarchy("oversized\(height)")
            var ancestor: UIView? = self
            var depth = 0
            while let node = ancestor, depth < 9 {
                let ancestorColor = node.backgroundColor.map { "\($0)" } ?? "nil"
                let prefix =
                    "oversized=\(height) event=\(event) depth=\(depth) type=\(type(of: node)) frame=\(node.frame) bg=\(ancestorColor) hidden=\(node.isHidden) alpha=\(node.alpha) translates=\(node.translatesAutoresizingMaskIntoConstraints) autoresize=\(node.autoresizingMask.rawValue)"
                KeyboardGeometryDiagnostics.placement(prefix)
                for constraint in node.constraints.filter({
                    $0.firstAttribute == .height || $0.firstAttribute == .top || $0.firstAttribute == .bottom
                }).prefix(8) {
                    KeyboardGeometryDiagnostics.placement("\(prefix) constraint=\(constraint)")
                }
                ancestor = node.superview
                depth += 1
            }
            KeyboardGeometryDiagnostics.placement(
                "oversized=\(height) affected=\(constraintsAffectingLayout(for: .vertical))")
            for (index, frame) in Thread.callStackSymbols.prefix(24).enumerated() {
                KeyboardGeometryDiagnostics.placement("oversized=\(height) stack[\(index)]=\(frame)")
            }
        }

        public override init(frame: CGRect, inputViewStyle: UIInputView.Style) {
            heightState = KeyboardPanelHeightState(height: Double(frame.height))
            super.init(frame: frame, inputViewStyle: inputViewStyle)
            configureSizing()
        }

        public required init?(coder: NSCoder) {
            heightState = KeyboardPanelHeightState(height: 0)
            super.init(coder: coder)
            heightState = KeyboardPanelHeightState(height: Double(bounds.height))
            configureSizing()
        }

        private func configureSizing() {
            allowsSelfSizing = true
            budgetHeightConstraint = heightAnchor.constraint(equalToConstant: panelHeight)
            budgetHeightConstraint.identifier = "KeyboardPanel.externalBudget"
            // UIKit may retain its required encapsulated height during a keyboard transition.
            budgetHeightConstraint.priority = UILayoutPriority(999)
            budgetHeightConstraint.isActive = true
            setContentHuggingPriority(UILayoutPriority(999), for: .vertical)
            setContentCompressionResistancePriority(UILayoutPriority(999), for: .vertical)
        }

        public func beginPresentation(height: CGFloat) {
            guard height.isFinite, height > 0 else { return }
            heightState.beginPresentation(height: Double(height))
            budgetHeightConstraint.constant = panelHeight
            // Re-measure even when a warm presentation has an unchanged budget.
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }

        public func endPresentation() {
            heightState.endPresentation()
        }

        public func setPanelHeight(_ height: CGFloat) {
            guard heightState.setPanelHeight(Double(height)) else { return }
            budgetHeightConstraint.constant = panelHeight
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }

        open override var intrinsicContentSize: CGSize {
            CGSize(width: UIView.noIntrinsicMetric, height: panelHeight)
        }

        open override func systemLayoutSizeFitting(_ targetSize: CGSize) -> CGSize {
            fittingSize(targetSize, source: "systemLayoutSizeFitting")
        }

        open override func systemLayoutSizeFitting(
            _ targetSize: CGSize,
            withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
            verticalFittingPriority: UILayoutPriority
        ) -> CGSize {
            fittingSize(
                targetSize,
                source:
                    "systemLayoutSizeFitting h=\(horizontalFittingPriority.rawValue) v=\(verticalFittingPriority.rawValue)"
            )
        }

        open override func sizeThatFits(_ size: CGSize) -> CGSize {
            fittingSize(size, source: "sizeThatFits")
        }

        private func fittingSize(_ proposed: CGSize, source: String) -> CGSize {
            let result = CGSize(width: proposed.width, height: panelHeight)
            KeyboardGeometryDiagnostics.emit("\(source) proposed=\(proposed) returned=\(result)")
            return result
        }
    }
#endif
