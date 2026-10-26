import XCTest

@testable import LayoutKit

final class LayoutSplitConfigurationTests: XCTestCase {
    func testStandardRowsKeepOneCharacterWidthAtPhoneAndTabletWidths() {
        for width in [280.0, 320, 393, 600, 768, 1024, 1366] {
            for split in [nil, LayoutSplitConfiguration(rowBreaks: [5, 4, 3], gapFraction: 0.24)] {
                let geometry = StandardKeyRowGeometry(width: width, split: split)
                XCTAssertEqual(geometry.keyWidth * 10 + 36 + geometry.gap, width, accuracy: 0.001)
                XCTAssertEqual(
                    geometry.keyWidth * 7 + geometry.thirdRowSideWidth * 2 + 32 + geometry.gap, width, accuracy: 0.001)
                XCTAssertGreaterThan(geometry.keyWidth, 0)
                XCTAssertGreaterThan(geometry.thirdRowSideWidth, 0)
            }
        }
    }

    func testSplitRetractsInFloatingWidthAndReturnsOnWideSurface() {
        let split = LayoutSplitConfiguration(gapFraction: 0.4)
        XCTAssertEqual(split.gap(width: 300, keyCount: 10), 0)
        XCTAssertGreaterThan(split.gap(width: 768, keyCount: 10), 200)
        XCTAssertEqual(split.gap(width: 300, keyCount: 10), 0)
        XCTAssertEqual(split.breakIndex(row: 0, keyCount: 7), 4)
    }

    func testSavedBreaksAndLayoutMutationsPreserveTheSplit() throws {
        let split = LayoutSplitConfiguration(rowBreaks: [5, 4, 3, 1])
        let layout = BuiltinLayouts.qwerty26.settingSplit(split)
        let decoded = try LayoutDefinition.decode(layout.encoded())
        XCTAssertEqual(decoded.split, split)
        XCTAssertEqual(decoded.copy().split, split)
        XCTAssertEqual(decoded.renamed("我的拆分").split, split)
        XCTAssertEqual(decoded.settingCandidateArea(.init(candidates: true, reading: false)).split, split)
        XCTAssertEqual(decoded.replacingKey(at: .row(0, key: 0), with: decoded.rows[0].keys[0]).split, split)
        XCTAssertNotEqual(decoded.runtimeIdentity, BuiltinLayouts.qwerty26.runtimeIdentity)
    }

    func testAutomaticSpacingKeepsLargeTabletKeysWithinThumbReach() {
        let split = LayoutSplitConfiguration()
        for width in [834.0, 1024, 1194, 1366] {
            let geometry = StandardKeyRowGeometry(width: width, split: split)
            XCTAssertLessThanOrEqual((width - geometry.gap) / 2, LayoutSplitConfiguration.maximumThumbHalfWidth)
            XCTAssertGreaterThanOrEqual(geometry.keyWidth, 32)
        }
    }

    /// Narrow one-hand surfaces stay whole by default; wide surfaces split. An explicit
    /// `.always` keeps the old split at every width.
    func testAutomaticSpacingAdaptsAcrossFoldedExpandedPortraitAndLandscapeWidths() {
        let split = LayoutSplitConfiguration()
        let widths = [320.0, 393, 466, 669, 744, 834, 1133, 1194, 1366]
        let gaps = widths.map { split.gap(width: $0, keyCount: 10) }
        XCTAssertEqual(gaps[0], 0)
        XCTAssertEqual(gaps[1], 0)
        XCTAssertEqual(gaps[2], 0, "a 466pt cover screen fits one hand")
        for index in 4..<gaps.count { XCTAssertGreaterThan(gaps[index], gaps[index - 1]) }
        XCTAssertGreaterThan(gaps[5], 834 * 0.3)
        let forced = LayoutSplitConfiguration(activation: .always)
        XCTAssertEqual(forced.gap(width: 466, keyCount: 10), 110, accuracy: 0.001)
    }

    func testSplitActivationDecidesWhetherANarrowSurfaceSplits() throws {
        let automatic = LayoutSplitConfiguration(rowBreaks: [5])
        XCTAssertFalse(automatic.isActive(width: 466))
        XCTAssertTrue(automatic.isActive(width: 834))
        XCTAssertNil(automatic.resolved(forWidth: 466))
        XCTAssertNil(automatic.breakIndex(row: 0, keyCount: 10, width: 466))
        let resolved = try XCTUnwrap(automatic.resolved(forWidth: 834))
        // The resolved value is a render-only copy that survives inner-width checks (rails reduce
        // the key area below 600 on a wide keyboard).
        XCTAssertEqual(resolved.activation, .always)
        XCTAssertEqual(automatic.activation, nil, "resolving must not mutate the stored choice")
        XCTAssertGreaterThan(resolved.gap(width: 400, keyCount: 10), 0)
        let forced = LayoutSplitConfiguration(activation: .always)
        XCTAssertTrue(forced.isActive(width: 320))
        XCTAssertEqual(forced.breakIndex(row: 0, keyCount: 7, width: 320), 4)
        let disabled = LayoutSplitConfiguration(enabled: false, activation: .always)
        XCTAssertFalse(disabled.isActive(width: 1024))
        // Old catalogs decode as automatic without a migration.
        let legacy = try JSONDecoder().decode(
            LayoutSplitConfiguration.self,
            from: Data("{\"enabled\":true,\"rowBreaks\":[5],\"gapFraction\":0.15}".utf8))
        XCTAssertNil(legacy.activation)
        XCTAssertFalse(legacy.isActive(width: 466))
        let restored = try JSONDecoder().decode(
            LayoutSplitConfiguration.self, from: JSONEncoder().encode(forced))
        XCTAssertEqual(restored, forced)
    }

    func testAutomaticSpacingKeepsThreeColumnDigitsFromStretchingOnTablets() {
        let split = LayoutSplitConfiguration()
        for width in [834.0, 1194, 1366] {
            let gap = split.gap(width: width, keyCount: 3)
            let digitWidth = (width - gap - 8) / 3
            XCTAssertGreaterThanOrEqual(digitWidth, 32)
            XCTAssertLessThanOrEqual(digitWidth, PhoneKeypadMetrics.preferredDigitWidth + 0.001)
        }
        // Default narrow surfaces are not split, so there is no automatic gutter to reserve.
        for width in [320.0, 466] {
            XCTAssertEqual(split.gap(width: width, keyCount: 3), 0)
        }
        // A user who forces the split keeps the tablet content cap.
        let forced = LayoutSplitConfiguration(activation: .always)
        for width in [466.0, 669] {
            let gap = forced.gap(width: width, keyCount: 3)
            let digitWidth = (width - gap - 8) / 3
            XCTAssertGreaterThanOrEqual(digitWidth, 32)
            XCTAssertLessThanOrEqual(digitWidth, PhoneKeypadMetrics.preferredDigitWidth + 0.001)
        }
    }

    func testOldManualSpacingAndAutomaticSpacingBothRoundTrip() throws {
        let legacy = Data("{\"enabled\":true,\"rowBreaks\":[5],\"gapFraction\":0.15}".utf8)
        let manual = try JSONDecoder().decode(LayoutSplitConfiguration.self, from: legacy)
        XCTAssertNil(manual.automaticGap)
        XCTAssertEqual(manual.gap(width: 834, keyCount: 10), 834 * 0.15, accuracy: 0.001)
        let automatic = LayoutSplitConfiguration(rowBreaks: [5])
        let restored = try JSONDecoder().decode(LayoutSplitConfiguration.self, from: JSONEncoder().encode(automatic))
        XCTAssertEqual(restored, automatic)
        XCTAssertTrue(restored.automaticGap == true)
    }

    func testPagesFollowMainSpacingUnlessExplicitlyOverridden() {
        let main = LayoutSplitConfiguration(rowBreaks: [5, 5, 4, 3])
        let inherited = LayoutSplitConfiguration.resolving(page: nil, main: main)
        XCTAssertTrue(inherited?.enabled == true)
        XCTAssertTrue(inherited?.automaticGap == true)
        XCTAssertEqual(inherited?.rowBreaks, [])
        let disabled = LayoutSplitConfiguration(enabled: false)
        XCTAssertEqual(LayoutSplitConfiguration.resolving(page: disabled, main: main), disabled)
        let custom = LayoutSplitConfiguration(rowBreaks: [4, 6, 5], gapFraction: 0.4)
        XCTAssertEqual(LayoutSplitConfiguration.resolving(page: custom, main: main), custom)
        XCTAssertNil(LayoutSplitConfiguration.resolving(page: nil, main: nil))
    }

    func testImportedSplitRejectsInvalidGapsAndRowBoundaries() {
        for fraction in [-0.1, 0.86, .nan, .infinity] {
            XCTAssertThrowsError(try LayoutSplitConfiguration(gapFraction: fraction).validate(rowKeyCounts: [10]))
        }
        XCTAssertThrowsError(try LayoutSplitConfiguration(rowBreaks: [10]).validate(rowKeyCounts: [10]))
        XCTAssertThrowsError(try LayoutSplitConfiguration(rowBreaks: [0]).validate(rowKeyCounts: [10]))
        XCTAssertThrowsError(try LayoutSplitConfiguration(rowBreaks: [5, 2]).validate(rowKeyCounts: [10]))
    }

    /// The automatic width rule only applies once the user turned splitting on. No split
    /// configuration means no split, and a disabled split stays whole even when forced.
    func testSplitOnlyHappensWhenTheUserTurnsItOn() {
        XCTAssertNil(LayoutSplitConfiguration.resolving(page: nil, main: nil))
        let unsplitGeometry = StandardKeyRowGeometry(width: 834, split: nil)
        XCTAssertEqual(unsplitGeometry.gap, 0)
        XCTAssertEqual(unsplitGeometry.keyWidth * 10 + 36, 834, accuracy: 0.001)

        for width in [320.0, 834] {
            XCTAssertFalse(LayoutSplitConfiguration(enabled: false).isActive(width: width))
            XCTAssertFalse(
                LayoutSplitConfiguration(enabled: false, activation: .always).isActive(width: width))
        }
        let automatic = LayoutSplitConfiguration()
        XCTAssertFalse(automatic.isActive(width: 600))
        XCTAssertTrue(automatic.isActive(width: 601))
        XCTAssertNil(automatic.resolved(forWidth: 600))
        XCTAssertNotNil(automatic.resolved(forWidth: 601))
        XCTAssertTrue(LayoutSplitConfiguration(activation: .always).isActive(width: 320))
    }
}
