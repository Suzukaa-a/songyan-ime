import XCTest
import os

@testable import KeyboardCore

final class BoundedDiagnosticLineCounterTests: XCTestCase {

    func testBoundedCounterNeverExceedsLimitUnderConcurrency() {
        let counter = BoundedDiagnosticLineCounter(limit: 200)
        DispatchQueue.concurrentPerform(iterations: 2_000) { _ in
            _ = counter.reserve()
        }
        XCTAssertEqual(counter.count, 200)
    }

    func testBoundedCounterReservesExactlyLimit() {
        let counter = BoundedDiagnosticLineCounter(limit: 3)
        XCTAssertTrue(counter.reserve())
        XCTAssertTrue(counter.reserve())
        XCTAssertTrue(counter.reserve())
        XCTAssertFalse(counter.reserve())
        XCTAssertEqual(counter.count, 3)
    }

    func testZeroLimitReservesNothing() {
        let counter = BoundedDiagnosticLineCounter(limit: 0)
        XCTAssertFalse(counter.reserve())
        XCTAssertEqual(counter.count, 0)
    }

    func testLifecycleCapReportsTruncationOnceUnderConcurrency() {
        let counter = BoundedDiagnosticLineCounter(limit: 4)
        let tally = OSAllocatedUnfairLock(initialState: (lines: 0, markers: 0))
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            let result = counter.reserveWithCapMarker()
            tally.withLock {
                if result == .line { $0.lines += 1 }
                if result == .capMarker { $0.markers += 1 }
            }
        }
        XCTAssertEqual(tally.withLock { $0.lines }, 3)
        XCTAssertEqual(tally.withLock { $0.markers }, 1)
        XCTAssertEqual(counter.count, 4)
        XCTAssertEqual(counter.reserveWithCapMarker(), .exhausted)
        XCTAssertEqual(BoundedDiagnosticLineCounter(limit: 0).reserveWithCapMarker(), .exhausted)
    }
}
