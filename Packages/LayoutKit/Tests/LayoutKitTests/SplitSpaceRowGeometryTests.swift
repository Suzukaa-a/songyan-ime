import XCTest

@testable import LayoutKit

final class SplitSpaceRowGeometryTests: XCTestCase {
    func testBothHalvesKeepReachableSpaceBarsAcrossKeyboardModesAndWidths() {
        for width in [390.0, 466, 669, 834, 1194, 1366] {
            for globe in [false, true] {
                for page in KeyboardControlPolicy.Page.allCases {
                    let policy = KeyboardControlPolicy(
                        page: page, isEnglishMode: false, hasGlobe: globe,
                        isPhoneLayout: false, usesASCIIPunctuation: false)
                    let metrics = policy.metrics(width: 320)
                    let boundary = (policy.slots.count + 1) / 2
                    let left = policy.slots.prefix(boundary).filter { $0 != .space }.map { metrics[$0] }
                    let right = policy.slots.dropFirst(boundary).filter { $0 != .space }.map { metrics[$0] }
                    // This checks the forced split layout at every width; the default automatic
                    // activation keeps narrow surfaces whole.
                    let forced = LayoutSplitConfiguration(activation: .always)
                    let requested = forced.gap(
                        width: width, keyCount: policy.slots.count, minimumKeyWidth: 44)
                    let geometry = SplitSpaceRowGeometry(
                        width: width, requestedGap: requested, leftKeyWidths: left, rightKeyWidths: right,
                        preferredSpaceWidth: StandardKeyRowGeometry(width: width, split: forced).keyWidth * 3)
                    XCTAssertNotNil(geometry)
                    if let geometry {
                        XCTAssertGreaterThanOrEqual(geometry.leftSpaceWidth, 44 - 0.001)
                        XCTAssertGreaterThanOrEqual(geometry.rightSpaceWidth, 44 - 0.001)
                        XCTAssertEqual(geometry.leftSpaceWidth, geometry.rightSpaceWidth, accuracy: 0.001)
                        XCTAssertEqual(
                            geometry.leftWidth + geometry.gap + geometry.spacing + geometry.rightWidth, width,
                            accuracy: 0.001)
                        XCTAssertEqual(
                            left.reduce(0, +) + Double(left.count) * geometry.spacing + geometry.leftSpaceWidth,
                            geometry.leftWidth, accuracy: 0.001)
                        XCTAssertEqual(
                            right.reduce(0, +) + Double(right.count) * geometry.spacing + geometry.rightSpaceWidth,
                            geometry.rightWidth, accuracy: 0.001)
                    }
                }
            }
        }
    }

    func testSpaceWidthTakesPriorityOverTheGutter() throws {
        let geometry = try XCTUnwrap(
            SplitSpaceRowGeometry(
                width: 834, requestedGap: 310, leftKeyWidths: [50, 50, 44], rightKeyWidths: [44, 60],
                preferredSpaceWidth: 156))
        XCTAssertEqual(geometry.leftSpaceWidth, 156, accuracy: 0.001)
        XCTAssertEqual(geometry.rightSpaceWidth, 156, accuracy: 0.001)
        XCTAssertEqual(geometry.gap, 250, accuracy: 0.001)
    }

    func testDuoWidthKeepsEqualLargeSpacesBeforeKeepingALargeGutter() throws {
        let geometry = try XCTUnwrap(
            SplitSpaceRowGeometry(
                width: 466, requestedGap: 150, leftKeyWidths: [50, 50, 44], rightKeyWidths: [44, 60],
                preferredSpaceWidth: 96))
        XCTAssertEqual(geometry.leftSpaceWidth, 93, accuracy: 0.001)
        XCTAssertEqual(geometry.rightSpaceWidth, 93, accuracy: 0.001)
        XCTAssertEqual(geometry.gap, 8, accuracy: 0.001)
    }

    func testNarrowWindowsKeepAnUnbrokenSpaceBarInsteadOfCrushingControls() {
        XCTAssertNil(
            SplitSpaceRowGeometry(
                width: 320, requestedGap: 60, leftKeyWidths: [50, 50, 44], rightKeyWidths: [44, 60]))
        XCTAssertNil(
            SplitSpaceRowGeometry(
                width: 834, requestedGap: 0, leftKeyWidths: [50, 50, 44], rightKeyWidths: [44, 60]))
    }

    func testAuthoredControlWidthsAndUnevenBreaksLeaveASpaceOnEachSide() throws {
        let geometry = try XCTUnwrap(
            SplitSpaceRowGeometry(
                width: 834, requestedGap: 266, leftKeyWidths: [44, 44, 88, 44], rightKeyWidths: [66]))
        XCTAssertGreaterThanOrEqual(geometry.leftSpaceWidth, 44)
        XCTAssertGreaterThanOrEqual(geometry.rightSpaceWidth, 44)
        XCTAssertEqual(geometry.leftWidth + geometry.gap + geometry.spacing + geometry.rightWidth, 834, accuracy: 0.001)
    }
}
