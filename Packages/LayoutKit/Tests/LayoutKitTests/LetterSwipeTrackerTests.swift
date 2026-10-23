import XCTest

@testable import LayoutKit

final class LetterSwipeTrackerTests: XCTestCase {
    func testTapDriftNeverPicks() {
        var tracker = LetterSwipeTracker(letterCount: 2)
        for (dx, dy) in [(3.0, 2.0), (-6, 4), (10, -9), (17, 1)] { tracker.update(dx: dx, dy: dy) }
        XCTAssertFalse(tracker.isLocked)
        XCTAssertNil(tracker.choice)
    }

    func testLeftAndRightPickTheMatchingLetter() {
        var left = LetterSwipeTracker(letterCount: 2)
        XCTAssertTrue(left.update(dx: -20, dy: 3))
        XCTAssertEqual(left.choice, 0)
        var right = LetterSwipeTracker(letterCount: 2)
        XCTAssertTrue(right.update(dx: 22, dy: -5))
        XCTAssertEqual(right.choice, 1)
    }

    func testMostlyVerticalTravelDoesNotLock() {
        var tracker = LetterSwipeTracker(letterCount: 2)
        tracker.update(dx: 20, dy: 25)
        XCTAssertFalse(tracker.isLocked)
        XCTAssertNil(tracker.choice)
    }

    func testLockedSwipeFollowsTheFingerAndCanReturnToATap() {
        var tracker = LetterSwipeTracker(letterCount: 2)
        tracker.update(dx: 20, dy: 0)
        XCTAssertEqual(tracker.choice, 1)
        // After the lock, vertical drift no longer matters.
        XCTAssertFalse(tracker.update(dx: 14, dy: 30))
        XCTAssertEqual(tracker.choice, 1)
        XCTAssertTrue(tracker.update(dx: -12, dy: 0))
        XCTAssertEqual(tracker.choice, 0)
        XCTAssertTrue(tracker.update(dx: 3, dy: 0))
        XCTAssertNil(tracker.choice)
        XCTAssertTrue(tracker.isLocked)
    }

    func testSingleLetterKeysNeverSwipe() {
        var tracker = LetterSwipeTracker(letterCount: 1)
        XCTAssertFalse(tracker.update(dx: 40, dy: 0))
        XCTAssertNil(tracker.choice)
    }
}
