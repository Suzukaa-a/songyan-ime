import XCTest

@testable import CandidateKit

final class KeyboardGeometryLogLimiterTests: XCTestCase {
    func testAlternatingEntrypointsAndPrioritiesOnlyEmitEachQueryOnce() {
        var limiter = KeyboardGeometryLogLimiter()
        let queries = [
            "sizeThatFits proposed=(402,509) returned=(402,280)",
            "systemLayoutSizeFitting proposed=(402,509) returned=(402,280)",
            "systemLayoutSizeFitting h=1000 v=50 proposed=(402,509) returned=(402,280)",
            "systemLayoutSizeFitting h=1000 v=1000 proposed=(402,509) returned=(402,280)",
        ]
        var count = 0
        for index in 0..<10_000 {
            if limiter.admit(queries[index % queries.count], now: Double(index) / 10) { count += 1 }
        }
        XCTAssertEqual(count, 4)
        XCTAssertTrue(limiter.admit("sizeThatFits proposed=(402,600) returned=(402,280)", now: 1001))
        XCTAssertTrue(limiter.admit("sizeThatFits proposed=(402,600) returned=(402,240)", now: 1001))
    }

    func testRollingWindowAndLifetimeCapacityBoundUniqueQueryFlood() {
        var limiter = KeyboardGeometryLogLimiter()
        for index in 0..<20 { XCTAssertTrue(limiter.admit("first-\(index)", now: 0)) }
        XCTAssertFalse(limiter.admit("later", now: 9.999))
        XCTAssertTrue(limiter.admit("later", now: 10))
        for index in 0..<200 { _ = limiter.admit("unique-\(index)", now: 20 + Double(index) * 10) }
        XCTAssertEqual(limiter.keys.count, 128)
        XCTAssertFalse(limiter.admit("beyond-capacity", now: 10_000))
        XCTAssertFalse(limiter.admit("first-0", now: 10_001))
    }
}
