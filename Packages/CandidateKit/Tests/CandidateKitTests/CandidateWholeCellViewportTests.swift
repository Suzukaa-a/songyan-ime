import XCTest

@testable import CandidateKit

final class CandidateWholeCellViewportTests: XCTestCase {
    func testOverflowEndsOnLastWholeCell() {
        let width = CandidateCollapsedFlow.wholeCellViewportWidth(
            cellWidths: [60, 44, 60, 60], spacing: 4, availableWidth: 200)
        XCTAssertEqual(width, 60 + 4 + 44 + 4 + 60)
    }

    func testFittingRowKeepsFullWidth() {
        XCTAssertEqual(
            CandidateCollapsedFlow.wholeCellViewportWidth(
                cellWidths: [60, 60], spacing: 4, availableWidth: 200), 200)
    }

    func testOversizedFirstCellUsesFullWidth() {
        XCTAssertEqual(
            CandidateCollapsedFlow.wholeCellViewportWidth(
                cellWidths: [300, 44], spacing: 4, availableWidth: 200), 200)
    }
}
