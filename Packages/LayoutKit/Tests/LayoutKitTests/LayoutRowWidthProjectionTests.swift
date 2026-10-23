import Foundation
import XCTest

@testable import LayoutKit

final class LayoutRowWidthProjectionTests: XCTestCase {
    func testImportedExtremeWeightsKeepEqualKeysVisible() throws {
        for value in [1e308, Double.leastNonzeroMagnitude] {
            let definition = LayoutDefinition(
                id: "extreme", name: "Extreme",
                input: .init(builtinLayout: .qwerty26),
                rows: [
                    .init(keys: [
                        .init(label: "a", width: value, action: .init(.literal, value: "a")),
                        .init(label: "b", width: value, action: .init(.literal, value: "b")),
                    ])
                ])
            let imported = try LayoutDefinition.decode(definition.encoded())
            let projected = LayoutRowWidthProjection(weights: imported.rows[0].keys.map(\.widthWeight))
            XCTAssertEqual(projected.keyFractions, [0.5, 0.5])
            XCTAssertEqual(projected.keyFractions.map { 390 * $0 }, [195, 195])
            XCTAssertEqual(projected.insetFraction, 0)
        }
        let single = LayoutRowWidthProjection(weights: [Double.greatestFiniteMagnitude])
        XCTAssertEqual(single.keyFractions, [1])
        XCTAssertEqual(single.keyFractions.map { 390 * $0 }, [390])
    }

    func testOrdinaryRatiosAndBundledInsetsPreserveGeometry() {
        let projected = LayoutRowWidthProjection(weights: [1, 2, 3], inset: 0.5)
        for (fraction, expected) in zip(projected.keyFractions, [1.0 / 7, 2.0 / 7, 3.0 / 7]) {
            XCTAssertEqual(fraction, expected, accuracy: 1e-15)
        }
        XCTAssertEqual(projected.insetFraction, 0.5 / 7, accuracy: 1e-15)
        XCTAssertEqual(
            projected.keyFractions.reduce(0, +) + projected.insetFraction * 2,
            1, accuracy: 1e-15)
        for scale in [1e-300, 1e300] {
            let scaled = LayoutRowWidthProjection(weights: [scale, 2 * scale, 3 * scale], inset: 0.5 * scale)
            for (fraction, expected) in zip(scaled.keyFractions, projected.keyFractions) {
                XCTAssertEqual(fraction, expected, accuracy: 1e-15)
            }
            XCTAssertEqual(scaled.insetFraction, projected.insetFraction, accuracy: 1e-15)
        }
    }

    func testPreviewValuesCannotProduceNonFiniteFractions() {
        for weights in [[], [0, -1], [.infinity, .nan, 1], [1e308, Double.leastNonzeroMagnitude]] {
            let projected = LayoutRowWidthProjection(weights: weights, inset: .infinity)
            XCTAssertEqual(projected.keyFractions.count, weights.count)
            XCTAssertTrue(projected.keyFractions.allSatisfy { $0.isFinite && (0...1).contains($0) })
            XCTAssertTrue(projected.insetFraction.isFinite)
        }
        let inset = LayoutRowWidthProjection(weights: [1e308], inset: 1e308)
        XCTAssertEqual(inset.keyFractions, [1.0 / 3])
        XCTAssertEqual(inset.insetFraction, 1.0 / 3)
    }
}
