import XCTest

@testable import LayoutKit

final class KeyboardPageRailGeometryTests: XCTestCase {
    func testPhoneEditingRailSpans54And54And112() {
        let geometry = KeyboardPageRailGeometry(height: 228, weights: [1, 1, 2])
        XCTAssertEqual(geometry.keyHeights.count, 3)
        XCTAssertEqual(geometry.keyHeights[0], 54, accuracy: 0.001)
        XCTAssertEqual(geometry.keyHeights[1], 54, accuracy: 0.001)
        XCTAssertEqual(geometry.keyHeights[2], 112, accuracy: 0.001)
        XCTAssertEqual(geometry.contentHeight, 228, accuracy: 0.001)
        XCTAssertEqual(geometry.spacing, 4)
    }

    func testRailHeightsFollowTheFormulaAndScrollInsteadOfCompressing() {
        for model in [
            (height: 400.0, weights: [1.0, 1, 1], spacing: 4.0),
            (height: 300, weights: [2, 1], spacing: 6),
            (height: 120, weights: [1, 1, 1], spacing: 4),
        ] {
            let geometry = KeyboardPageRailGeometry(
                height: model.height, weights: model.weights, spacing: model.spacing)
            let total = model.weights.reduce(0, +)
            for (index, weight) in model.weights.enumerated() {
                let raw = (model.height + model.spacing) * weight / total - model.spacing
                XCTAssertEqual(geometry.keyHeights[index], max(44, raw), accuracy: 0.001)
            }
            XCTAssertEqual(
                geometry.contentHeight,
                geometry.keyHeights.reduce(0, +) + model.spacing * Double(model.weights.count - 1),
                accuracy: 0.001)
        }
    }

    func testMinimumTapHeightWinsAndTheRailScrolls() {
        let geometry = KeyboardPageRailGeometry(height: 80, weights: [1, 1, 1], spacing: 0)
        XCTAssertEqual(geometry.keyHeights, [44, 44, 44])
        XCTAssertEqual(geometry.contentHeight, 132)
        XCTAssertGreaterThan(geometry.contentHeight, 80)
        let single = KeyboardPageRailGeometry(height: 30, weights: [1], spacing: 4)
        XCTAssertEqual(single.keyHeights, [44])
        XCTAssertEqual(single.contentHeight, 44)
    }

    func testHugeFiniteWeightsStayFinite() {
        let geometry = KeyboardPageRailGeometry(
            height: 228, weights: [Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude])
        XCTAssertTrue(geometry.keyHeights.allSatisfy(\.isFinite))
        XCTAssertTrue(geometry.contentHeight.isFinite)
        XCTAssertEqual(geometry.keyHeights[0], geometry.keyHeights[1], accuracy: 0.001)
        XCTAssertEqual(geometry.contentHeight, 228, accuracy: 0.001)
    }

    func testEmptyAndInvalidWeightsStayFinite() {
        XCTAssertTrue(KeyboardPageRailGeometry(height: 228, weights: []).keyHeights.isEmpty)
        XCTAssertEqual(KeyboardPageRailGeometry(height: 228, weights: []).contentHeight, 0)
        let invalid = KeyboardPageRailGeometry(height: 228, weights: [0, -1, .nan], spacing: 4)
        XCTAssertEqual(invalid.keyHeights, [44, 44, 44])
        XCTAssertTrue(invalid.keyHeights.allSatisfy(\.isFinite))
        let nonFinite = KeyboardPageRailGeometry(height: .infinity, weights: [1, 1], spacing: .nan)
        XCTAssertTrue(nonFinite.contentHeight.isFinite)
    }
}
