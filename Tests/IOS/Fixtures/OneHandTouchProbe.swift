import Foundation
import UIKit

// ---------------------------------------------------------------------------
// Seams for production types too coupled to compile into one probe unit
// (KeyboardPanelSizing.swift's superclass, AlternateCharacterKey.swift's key class).
// ---------------------------------------------------------------------------

open class KeyboardPanelInputView: UIInputView {
    public override init(frame: CGRect, inputViewStyle: UIInputView.Style) {
        super.init(frame: frame, inputViewStyle: inputViewStyle)
    }
    public required init?(coder: NSCoder) { super.init(coder: coder) }
}

enum AlternateCharacterKey {
    /// Mirrors the production key's hit contract in AlternateCharacterKey.swift:
    /// its own bounds plus the single window point the router just routed to it.
    final class CharacterButton: UIControl, KeyboardKeyHitTarget {
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            super.point(inside: point, with: event) || KeyboardRoutedTouch.accepts(self, point)
        }
    }
}

class SkinnedButton: UIButton, KeyboardKeyHitTarget {}

enum DebugProbe {
    static var touchRoutingEnabled = false
    static func touchRouting(point: CGPoint, hit: UIView?, nearKeys: [CGRect], routed: CGRect?) {}
}

final class KeyboardFeedbackService {
    static let shared = KeyboardFeedbackService()
    func selectionChanged() {}
}

// ---------------------------------------------------------------------------
// Probe app
// ---------------------------------------------------------------------------

@main @MainActor final class OneHandTouchProbe: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    var checks: [[String: Any]] = []
    var failures: [String] = []

    /// Standard iPhone portrait panel; the production policy yields 331 content / 59 gutter.
    static let panelWidth: CGFloat = 390
    static let panelHeight: CGFloat = 276

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight))
        window.rootViewController = UIViewController()
        self.window = window
        window.makeKeyAndVisible()
        run()
        return true
    }

    func record(_ name: String, _ passed: Bool, _ detail: String = "") {
        checks.append(["name": name, "passed": passed, "detail": detail])
        if !passed { failures.append(name + (detail.isEmpty ? "" : ": " + detail)) }
    }

    func describe(_ view: UIView?) -> String {
        guard let view else { return "nil" }
        return String(describing: type(of: view))
    }

    func run() {
        guard let window, let host = window.rootViewController?.view else {
            record("probeWindowAvailable", false, "no window or host view")
            publish()
            return
        }
        host.frame = window.bounds

        // Real production policy decides the geometry.
        let plan = KeyboardOneHandLayoutPolicy.plan(
            mode: .left,
            panelWidth: Double(Self.panelWidth),
            isPhonePortrait: true)
        record(
            "planActiveAt390", plan.active && plan.contentWidth == 331 && plan.gutterWidth == 59,
            "active=\(plan.active) content=\(plan.contentWidth) gutter=\(plan.gutterWidth)")

        let root = FeedbackInputView(frame: host.bounds, inputViewStyle: .default)
        host.addSubview(root)
        window.layoutIfNeeded()

        // Three key rows on the content side, inset 8pt from the panel edge so their
        // right edge sits 8pt inside the gutter: exactly the band the router's
        // 24pt edge reach would otherwise hand to a character.
        let keyHeight: CGFloat = 54
        let keyInset: CGFloat = 8
        let keyWidth = CGFloat(plan.contentWidth) - keyInset * 2
        var keys: [UIView] = []
        for row in 0..<3 {
            let key = AlternateCharacterKey.CharacterButton(
                frame: CGRect(
                    x: keyInset,
                    y: CGFloat(row) * (keyHeight + 8),
                    width: keyWidth,
                    height: keyHeight))
            root.addSubview(key)
            keys.append(key)
        }
        window.layoutIfNeeded()

        // The restore control, installed the way the host installs it: the plan's
        // gutter width and the panel's full height.
        let gutterWidth = CGFloat(plan.gutterWidth)
        let gutterRect = CGRect(
            x: Self.panelWidth - gutterWidth, y: 0,
            width: gutterWidth, height: Self.panelHeight)
        let control = OneHandGutterControl {}
        control.frame = gutterRect
        root.addSubview(control)
        // Production layoutSubviews registers the exclusion zone; no hand-set state here.
        window.layoutIfNeeded()

        record(
            "controlCoversWholeGutter",
            control.bounds.width >= 44 && control.bounds.height >= 44 && control.window != nil,
            "bounds=\(control.bounds) window=\(control.window != nil)")

        // The window-space rect the control itself registers (captured while attached).
        let gutterWindowRect = control.convert(control.bounds, to: window)

        // Samples: both gutter edges at top / middle / bottom, plus one point per key
        // row at the content edge (the 24pt band) and at the outer edge.
        var samples: [(String, CGPoint)] = [
            ("topLeft", CGPoint(x: gutterRect.minX + 1.5, y: 1)),
            ("topRight", CGPoint(x: gutterRect.maxX - 1.5, y: 1)),
            ("midLeft", CGPoint(x: gutterRect.minX + 1.5, y: Self.panelHeight / 2)),
            ("midRight", CGPoint(x: gutterRect.maxX - 1.5, y: Self.panelHeight / 2)),
            ("bottomLeft", CGPoint(x: gutterRect.minX + 1.5, y: Self.panelHeight - 1)),
            ("bottomRight", CGPoint(x: gutterRect.maxX - 1.5, y: Self.panelHeight - 1)),
        ]
        for (index, key) in keys.enumerated() {
            samples.append(("row\(index)Inner", CGPoint(x: gutterRect.minX + 1, y: key.frame.midY)))
            samples.append(("row\(index)Outer", CGPoint(x: gutterRect.maxX - 1, y: key.frame.midY)))
        }

        // A. Whole gutter returns the restore control itself, and no key accepts the point.
        for (name, point) in samples {
            let hit = root.hitTest(point, with: nil)
            // Identity, plus the consequence UIKit draws from it: the view it returns is
            // the control, so no character key ever sees this touch.
            let isAKey =
                hit.map { candidate in
                    keys.contains { $0 === candidate || candidate.isDescendant(of: $0) }
                } ?? false
            record("gutterHitsRestoreControl/\(name)", hit === control, "hit=\(describe(hit))")
            record("gutterNeverReturnsAKey/\(name)", !isAKey, "hit=\(describe(hit))")
        }

        // B. Content keys still keep their own touches.
        for (index, key) in keys.enumerated() {
            let center = root.convert(CGPoint(x: key.bounds.midX, y: key.bounds.midY), from: key)
            let hit = root.hitTest(center, with: nil)
            record(
                "contentKeyKeepsItsCenter/row\(index)",
                hit === key || (hit?.isDescendant(of: key) ?? false), "hit=\(describe(hit))")
        }

        // C. Counterfactual: remove the control so only the registered zone can block,
        // then toggle that zone at the same points.
        KeyboardRoutedTouch.clear()
        control.removeFromSuperview()
        window.layoutIfNeeded()

        KeyboardRoutedTouch.setOneHandGutter(exposed: false)
        var loadBearing: [String] = []
        for (name, point) in samples {
            // Each sample starts from no recorded route, so the measured dispatch is the
            // router's own decision and never a leftover from the previous sample.
            KeyboardRoutedTouch.clear()
            let hit = root.hitTest(point, with: nil)
            if let hit, keys.contains(where: { $0 === hit }) { loadBearing.append(name) }
        }
        record(
            "routerReallyDispatchesCharactersHere", loadBearing.count >= 3,
            "loadBearing=\(loadBearing.count) [\(loadBearing.joined(separator: ","))]")

        KeyboardRoutedTouch.setOneHandGutter(exposed: true)
        KeyboardRoutedTouch.setOneHandGutterFrame(gutterWindowRect)
        record(
            "exclusionZoneIsRegistered",
            KeyboardRoutedTouch.pointIsInOneHandGutter(
                root.convert(CGPoint(x: gutterRect.midX, y: gutterRect.midY), to: window)))
        var zoneOnlyResults: [String: String] = [:]
        for (name, point) in samples {
            KeyboardRoutedTouch.clear()
            let hit = root.hitTest(point, with: nil)
            let isKey = hit.map { candidate in keys.contains(where: { $0 === candidate }) } ?? false
            zoneOnlyResults[name] = describe(hit)
            record("exclusionAloneBlocksKeyRoute/\(name)", !isKey, "hit=\(describe(hit))")
        }

        // The gutter region is consulted before the "!(hit is UIControl)" guard, so a key
        // that already accepts the point through a recorded route must not take it.
        let probePoint = CGPoint(x: gutterRect.minX + 1, y: keys[1].frame.midY)
        KeyboardRoutedTouch.clear()
        KeyboardRoutedTouch.route(keys[1], at: root.convert(probePoint, to: window))
        let zoneOnWithStaleRoute = describe(root.hitTest(probePoint, with: nil))
        // The region must win over the recorded route: the key does not take the touch.
        record(
            "recordedRouteDoesNotBeatExposedGutter",
            zoneOnWithStaleRoute != describe(keys[1]),
            "zoneOnWithStaleRoute=\(zoneOnWithStaleRoute) key=\(describe(keys[1]))")
        KeyboardRoutedTouch.clear()

        // The restore control is one accessibility element whose "activate" runs the
        // same restore action a tap runs.
        let axControl = OneHandGutterControl {}
        axControl.frame = gutterRect
        root.addSubview(axControl)
        window.layoutIfNeeded()
        record(
            "restoreIsAccessibilityElement",
            axControl.isAccessibilityElement && axControl.accessibilityTraits.contains(.button),
            "traits=\(axControl.accessibilityTraits.rawValue)")
        record(
            "restoreHasStableIdentifier",
            axControl.accessibilityIdentifier == "keyboard.oneHand.restore",
            "identifier=\(axControl.accessibilityIdentifier ?? "nil")")

        var axActionRan = false
        let axTap = OneHandGutterControl { axActionRan = true }
        axTap.frame = gutterRect
        root.addSubview(axTap)
        window.layoutIfNeeded()
        let axHandled = axTap.accessibilityActivate()
        record(
            "accessibilityActivateRunsRestore", axActionRan,
            "accessibilityActivate()=\(axHandled) actionRan=\(axActionRan)")
        record("accessibilityActivateReportsHandled", axHandled, "returned \(axHandled)")

        // A disabled control must not restore.
        var disabledRan = false
        let disabledTap = OneHandGutterControl { disabledRan = true }
        disabledTap.frame = gutterRect
        disabledTap.isEnabled = false
        root.addSubview(disabledTap)
        window.layoutIfNeeded()
        _ = disabledTap.accessibilityActivate()
        record("disabledAccessibilityActivateDoesNotRestore", !disabledRan)

        axControl.removeFromSuperview()
        axTap.removeFromSuperview()
        disabledTap.removeFromSuperview()
        window.layoutIfNeeded()

        // D. A recorded route does not outlive the layout that produced it.
        KeyboardRoutedTouch.route(keys[0], at: CGPoint(x: 5, y: 5))
        let stalePoint = keys[0].convert(CGPoint(x: 5, y: 5), from: window)
        record("routeAcceptedBeforeClear", KeyboardRoutedTouch.accepts(keys[0], stalePoint))
        KeyboardRoutedTouch.clear()
        record("clearDropsRoute", !KeyboardRoutedTouch.accepts(keys[0], stalePoint))

        // E. Full restore: no gutter zone survives, and the space is ordinary keyboard
        // space again (the same near-edge point routes).
        KeyboardRoutedTouch.setOneHandGutter(exposed: false)
        window.layoutIfNeeded()
        record(
            "fullRestoreLeavesNoGutterZone",
            !KeyboardRoutedTouch.pointIsInOneHandGutter(
                root.convert(CGPoint(x: gutterRect.midX, y: gutterRect.midY), to: window)))
        let restoredPoint = CGPoint(x: gutterRect.minX + 1, y: keys[0].frame.midY)
        let restoredHit = root.hitTest(restoredPoint, with: nil)
        record(
            "fullRestoreRoutesOrdinarySpace",
            restoredHit != nil && keys.contains(where: { $0 === restoredHit }),
            "hit=\(describe(restoredHit))")

        // F. SwiftUI may return its own transparent container from UIKit's hit test even
        // though the native control sits right there; the router must return the
        // registered control instead.
        let maskedControl = OneHandGutterControl {}
        maskedControl.frame = gutterRect
        root.addSubview(maskedControl)
        let mask = UIView(frame: gutterRect)  // transparent container, above the control
        mask.backgroundColor = .clear
        root.addSubview(mask)
        window.layoutIfNeeded()
        record(
            "maskedControlIsVisiblyPresent",
            maskedControl.window != nil && !maskedControl.isHidden && maskedControl.alpha > 0.01,
            "window=\(maskedControl.window != nil) hidden=\(maskedControl.isHidden) alpha=\(maskedControl.alpha)")
        let maskPoint = CGPoint(x: gutterRect.midX, y: gutterRect.midY)
        let maskWindowRect = maskedControl.convert(maskedControl.bounds, to: window)

        // With the region off the router returns UIKit's raw hit, which must be the container.
        KeyboardRoutedTouch.setOneHandGutter(exposed: false)
        let maskRawHit = root.hitTest(maskPoint, with: nil)
        record(
            "maskedRawHitIsTheContainer", maskRawHit === mask,
            "rawHit=\(describe(maskRawHit)) container=\(describe(mask)) control=\(describe(maskedControl))")

        KeyboardRoutedTouch.registerOneHandGutter(maskedControl, frame: maskWindowRect)
        let maskRoutedHit = root.hitTest(maskPoint, with: nil)
        record(
            "maskedPointReturnsRegisteredControl", maskRoutedHit === maskedControl,
            "hit=\(describe(maskRoutedHit)) control=\(describe(maskedControl))")

        // G. An exposed region whose registered target is INVALID must still exclude: the
        // underlying key may not take the touch, and the invalid control must not be
        // returned either. A key that physically overlaps the gutter provides the raw hit.
        mask.removeFromSuperview()
        maskedControl.removeFromSuperview()
        let overlapKey = AlternateCharacterKey.CharacterButton(
            frame: CGRect(x: gutterRect.minX - 10, y: 40, width: 60, height: 54))
        root.addSubview(overlapKey)
        window.layoutIfNeeded()
        let overlapPoint = CGPoint(x: gutterRect.minX + 4, y: overlapKey.frame.midY)

        KeyboardRoutedTouch.setOneHandGutter(exposed: false)
        let overlapRawHit = root.hitTest(overlapPoint, with: nil)
        record(
            "overlappingKeyIsTheRawHit", overlapRawHit === overlapKey,
            "rawHit=\(describe(overlapRawHit)) key=\(describe(overlapKey))")

        let invalidControl = OneHandGutterControl {}
        invalidControl.frame = gutterRect
        root.addSubview(invalidControl)
        window.layoutIfNeeded()
        invalidControl.isEnabled = false
        KeyboardRoutedTouch.registerOneHandGutter(
            invalidControl,
            frame: invalidControl.convert(invalidControl.bounds, to: window))
        record(
            "invalidTargetIsNotReturned",
            KeyboardRoutedTouch.oneHandRestoreTarget(
                at: root.convert(overlapPoint, to: window), in: window) == nil,
            "a disabled control must not be a restore target")
        let invalidTargetHit = root.hitTest(overlapPoint, with: nil)
        record(
            "invalidTargetExcludesWithoutLeakingKey", invalidTargetHit !== overlapKey,
            "hit=\(describe(invalidTargetHit)) key=\(describe(overlapKey))")
        record(
            "invalidTargetIsNeverReturned", invalidTargetHit !== invalidControl,
            "hit=\(describe(invalidTargetHit))")
        record(
            "invalidTargetExclusionStaysInTheInputView", invalidTargetHit === root,
            "hit=\(describe(invalidTargetHit)) -- the input view owns the excluded point")

        // H. A different overlay control at the same point is respected: only the input
        // view and the character keys are overridden inside the gutter.
        let plainOverlay = UIControl(frame: gutterRect)
        root.addSubview(plainOverlay)
        window.layoutIfNeeded()
        let overlayHit = root.hitTest(overlapPoint, with: nil)
        record(
            "otherOverlayControlIsRespected", overlayHit === plainOverlay,
            "hit=\(describe(overlayHit)) overlay=\(describe(plainOverlay))")
        plainOverlay.removeFromSuperview()
        overlapKey.removeFromSuperview()
        invalidControl.removeFromSuperview()
        window.layoutIfNeeded()

        // I. Owner-aware registration: a retired (or rebuilt) view must not clear the
        // region its replacement now owns.
        let ownerA = OneHandGutterControl {}
        let ownerB = OneHandGutterControl {}
        ownerA.frame = gutterRect
        ownerB.frame = gutterRect
        root.addSubview(ownerA)
        root.addSubview(ownerB)
        window.layoutIfNeeded()
        let gutterWindowPoint = root.convert(CGPoint(x: gutterRect.midX, y: gutterRect.midY), to: window)
        KeyboardRoutedTouch.registerOneHandGutter(
            ownerB,
            frame: ownerB.convert(ownerB.bounds, to: window))
        let replacement = KeyboardRoutedTouch.oneHandRestoreTarget(at: gutterWindowPoint, in: window)
        record(
            "replacementControlIsTheTarget", replacement === ownerB,
            "target=\(describe(replacement)) replacement=\(describe(ownerB))")

        KeyboardRoutedTouch.registerOneHandGutter(ownerA, frame: nil)
        let afterOldOwnerRetire = KeyboardRoutedTouch.oneHandRestoreTarget(at: gutterWindowPoint, in: window)
        record(
            "oldOwnerRetireDoesNotWipeReplacement", afterOldOwnerRetire === ownerB,
            "target=\(describe(afterOldOwnerRetire)) replacement=\(describe(ownerB))")

        KeyboardRoutedTouch.registerOneHandGutter(ownerB, frame: nil)
        record(
            "ownerCanRetireItsOwnRegion",
            KeyboardRoutedTouch.oneHandRestoreTarget(at: gutterWindowPoint, in: window) == nil,
            "the owner's own retire must clear its region")
        ownerA.removeFromSuperview()
        ownerB.removeFromSuperview()
        window.layoutIfNeeded()
        publish(extra: [
            "loadBearingSamples": loadBearing,
            "zoneOnlyHits": zoneOnlyResults,
            "zoneOnWithStaleRouteHit": zoneOnWithStaleRoute,
        ])
    }

    func publish(extra: [String: Any] = [:]) {
        var report: [String: Any] = [
            "passed": failures.isEmpty,
            "checks": checks,
            "scope":
                "production FeedbackInputView.hitTest + KeyboardRoutedTouch + OneHandGutterControl, real UIKit UIWindow/UIView/UIControl on the simulator",
        ]
        for (key, value) in extra { report[key] = value }
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("one-hand-touch-report.json"), options: .atomic)
        }
        if !failures.isEmpty {
            FileHandle.standardError.write(Data(("FAIL " + failures.joined(separator: ", ")).utf8))
        }
    }
}
