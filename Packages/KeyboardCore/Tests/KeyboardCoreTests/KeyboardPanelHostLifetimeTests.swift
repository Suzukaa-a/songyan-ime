import XCTest

@testable import KeyboardCore

final class KeyboardPanelHostLifetimeTests: XCTestCase {

    private final class PanelGestureProbe: NSObject {
        private(set) var cancellations = 0
        @objc func cancel(_ notification: Notification) { cancellations += 1 }
    }

    func testLateHostDisappearanceStopsOnlyItsOwnGesturesAndPreservesNewRail() {
        let center = NotificationCenter()
        let name = Notification.Name("test.panelHostWillDisappear")
        let ownerA = NSObject(), ownerB = NSObject()
        var activeOwner = ownerA
        let hostA = KeyboardPanelHostLifetime { activeOwner === ownerA }
        let hostB = KeyboardPanelHostLifetime { activeOwner === ownerB }
        let gesturesA = PanelGestureProbe(), gesturesB = PanelGestureProbe()
        center.addObserver(gesturesA, selector: #selector(PanelGestureProbe.cancel(_:)), name: name, object: hostA)
        center.addObserver(gesturesB, selector: #selector(PanelGestureProbe.cancel(_:)), name: name, object: hostB)
        defer {
            center.removeObserver(gesturesA)
            center.removeObserver(gesturesB)
        }

        // UIKit retains A's panel while B takes over the same shared session.
        activeOwner = ownerB
        var pendingRail: String? = "B's pending reading"
        hostA.notifyDisappearance(name: name, center: center)
        hostA.cancelSharedSelection { pendingRail = nil }
        XCTAssertEqual(gesturesA.cancellations, 1)
        XCTAssertEqual(gesturesB.cancellations, 0)
        XCTAssertEqual(pendingRail, "B's pending reading")

        // B's own disappearance still stops its gestures and shared selection.
        hostB.notifyDisappearance(name: name, center: center)
        hostB.cancelSharedSelection { pendingRail = nil }
        XCTAssertEqual(gesturesA.cancellations, 1)
        XCTAssertEqual(gesturesB.cancellations, 1)
        XCTAssertNil(pendingRail)
    }

    func testUnownedHostNotificationsCannotCancelScopedGestures() {
        let center = NotificationCenter()
        let name = Notification.Name("test.panelHostWillDisappear")
        let host = KeyboardPanelHostLifetime { true }
        let gestures = PanelGestureProbe()
        center.addObserver(gestures, selector: #selector(PanelGestureProbe.cancel(_:)), name: name, object: host)
        defer { center.removeObserver(gestures) }
        center.post(name: name, object: nil)
        center.post(name: name, object: NSObject())
        XCTAssertEqual(gestures.cancellations, 0)
        host.notifyDisappearance(name: name, center: center)
        XCTAssertEqual(gestures.cancellations, 1)
    }

    func testSharedSelectionCancellationRechecksOwnershipAfterReappearance() {
        var isActive = false
        let host = KeyboardPanelHostLifetime { isActive }
        var cancellations = 0
        host.cancelSharedSelection { cancellations += 1 }
        XCTAssertEqual(cancellations, 0)
        isActive = true
        host.cancelSharedSelection { cancellations += 1 }
        XCTAssertEqual(cancellations, 1)
        isActive = false
        host.cancelSharedSelection { cancellations += 1 }
        XCTAssertEqual(cancellations, 1)
    }
}
