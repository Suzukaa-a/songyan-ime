import XCTest

@testable import LayoutKit

final class LayoutSplitConfigurationTests: XCTestCase {
    /// The split as a wide keyboard renders it.
    private func active(_ split: LayoutSplitConfiguration) -> ActiveLayoutSplit {
        split.resolved(forWidth: 10_000)!
    }

    func testStandardRowsKeepOneCharacterWidthAtPhoneAndTabletWidths() {
        let manual = LayoutSplitConfiguration(activation: .always, rowBreaks: [5, 4, 3], gapFraction: 0.24)
        for width in [280.0, 320, 393, 600, 768, 1024, 1366] {
            for split in [nil, manual.resolved(forWidth: width)] {
                let geometry = StandardKeyRowGeometry(width: width, split: split)
                XCTAssertEqual(geometry.keyWidth * 10 + 36 + geometry.gap, width, accuracy: 0.001)
                XCTAssertEqual(
                    geometry.keyWidth * 7 + geometry.thirdRowSideWidth * 2 + 32 + geometry.gap, width, accuracy: 0.001)
                XCTAssertGreaterThan(geometry.keyWidth, 0)
                XCTAssertGreaterThan(geometry.thirdRowSideWidth, 0)
            }
        }
    }

    func testManualGapRetractsWhenKeysWouldGetTooNarrow() {
        let split = active(LayoutSplitConfiguration(gapFraction: 0.4))
        XCTAssertEqual(split.gap(width: 300, keyCount: 10), 0)
        XCTAssertGreaterThan(split.gap(width: 768, keyCount: 10), 200)
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
            let geometry = StandardKeyRowGeometry(width: width, split: split.resolved(forWidth: width))
            XCTAssertLessThanOrEqual((width - geometry.gap) / 2, ActiveLayoutSplit.maximumThumbHalfWidth)
            XCTAssertGreaterThanOrEqual(geometry.keyWidth, ActiveLayoutSplit.minimumAutomaticKeyWidth)
        }
    }

    /// Narrow one-hand surfaces stay whole by default; wide surfaces split. An explicit
    /// `.always` splits at every width.
    func testAutomaticSpacingAdaptsAcrossFoldedExpandedPortraitAndLandscapeWidths() {
        let split = LayoutSplitConfiguration()
        let widths = [320.0, 393, 466, 669, 744, 834, 1133, 1194, 1366]
        let gaps = widths.map { split.resolved(forWidth: $0)?.gap(width: $0, keyCount: 10) ?? 0 }
        XCTAssertEqual(gaps[0], 0)
        XCTAssertEqual(gaps[1], 0)
        XCTAssertEqual(gaps[2], 0, "a 466pt cover screen fits one hand")
        for index in 4..<gaps.count { XCTAssertGreaterThan(gaps[index], gaps[index - 1]) }
        XCTAssertGreaterThan(gaps[5], 834 * 0.3)
        let forced = LayoutSplitConfiguration(activation: .always).resolved(forWidth: 466)
        XCTAssertEqual(forced?.gap(width: 466, keyCount: 10) ?? 0, 110, accuracy: 0.001)
    }

    func testActivationIsDecidedOnceOnTheWholeKeyboard() throws {
        let automatic = LayoutSplitConfiguration(rowBreaks: [5])
        for width in [320.0, 466, KeyboardSurfaceWidth.phoneMaximum] {
            XCTAssertNil(automatic.resolved(forWidth: width))
        }
        // The resolved split survives an inner area that rails narrowed below the threshold.
        let resolved = try XCTUnwrap(automatic.resolved(forWidth: 834))
        XCTAssertGreaterThan(resolved.gap(width: 400, keyCount: 10), 0)
        XCTAssertEqual(resolved.breakIndex(row: 0, keyCount: 10), 5)

        let forced = LayoutSplitConfiguration(activation: .always)
        XCTAssertEqual(forced.resolved(forWidth: 320)?.breakIndex(row: 0, keyCount: 7), 4)
        XCTAssertNil(LayoutSplitConfiguration(activation: .off).resolved(forWidth: 1366))
        XCTAssertEqual(
            try JSONDecoder().decode(LayoutSplitConfiguration.self, from: JSONEncoder().encode(forced)), forced)
    }

    func testAutomaticSpacingKeepsThreeColumnDigitsFromStretchingOnTablets() {
        let automatic = LayoutSplitConfiguration()
        let forced = LayoutSplitConfiguration(activation: .always)
        for (split, widths) in [(automatic, [834.0, 1194, 1366]), (forced, [466.0, 669])] {
            for width in widths {
                let gap = split.resolved(forWidth: width)?.gap(width: width, keyCount: 3) ?? 0
                let digitWidth = (width - gap - 8) / 3
                XCTAssertGreaterThanOrEqual(digitWidth, ActiveLayoutSplit.minimumAutomaticKeyWidth)
                XCTAssertLessThanOrEqual(digitWidth, ActiveLayoutSplit.maximumAutomaticKeyWidth + 0.001)
            }
        }
    }

    func testManualAndAutomaticSpacingBothRoundTrip() throws {
        let manual = LayoutSplitConfiguration(rowBreaks: [5], gapFraction: 0.15)
        XCTAssertFalse(manual.automaticGap)
        XCTAssertEqual(active(manual).gap(width: 834, keyCount: 10), 834 * 0.15, accuracy: 0.001)
        let automatic = LayoutSplitConfiguration(rowBreaks: [5])
        XCTAssertTrue(automatic.automaticGap)
        for split in [manual, automatic] {
            XCTAssertEqual(
                try JSONDecoder().decode(LayoutSplitConfiguration.self, from: JSONEncoder().encode(split)), split)
        }
    }

    func testPagesFollowMainSpacingUnlessExplicitlyOverridden() {
        let main = LayoutSplitConfiguration(rowBreaks: [5, 5, 4, 3])
        let inherited = LayoutSplitConfiguration.resolving(page: nil, main: main)
        XCTAssertEqual(inherited?.activation, .automatic)
        XCTAssertEqual(inherited?.automaticGap, true)
        XCTAssertEqual(inherited?.rowBreaks, [])
        let disabled = LayoutSplitConfiguration(activation: .off)
        XCTAssertEqual(LayoutSplitConfiguration.resolving(page: disabled, main: main), disabled)
        let custom = LayoutSplitConfiguration(rowBreaks: [4, 6, 5], gapFraction: 0.4)
        XCTAssertEqual(LayoutSplitConfiguration.resolving(page: custom, main: main), custom)
        XCTAssertNil(LayoutSplitConfiguration.resolving(page: nil, main: nil))
    }

    /// A category grid under an active page keeps the page's spacing with its own cuts, unless it
    /// stores its own setting, which is resolved against the same keyboard width.
    func testNestedAreasInheritTheActiveSplitOrResolveTheirOwn() throws {
        let page = try XCTUnwrap(LayoutSplitConfiguration(rowBreaks: [3], gapFraction: 0.3).resolved(forWidth: 834))
        let inherited = try XCTUnwrap(ActiveLayoutSplit.resolving(nested: nil, parent: page, width: 834))
        XCTAssertEqual(inherited, page.withoutRowBreaks)
        XCTAssertEqual(inherited.rowBreaks, [])
        XCTAssertEqual(inherited.gapFraction, 0.3)
        XCTAssertNil(ActiveLayoutSplit.resolving(nested: .init(activation: .off), parent: page, width: 834))
        XCTAssertNil(ActiveLayoutSplit.resolving(nested: nil, parent: nil, width: 834))
        XCTAssertNotNil(ActiveLayoutSplit.resolving(nested: .init(), parent: nil, width: 834))
    }

    func testImportedSplitRejectsInvalidGapsAndRowBoundaries() {
        for fraction in [-0.1, 0.86, .nan, .infinity] {
            XCTAssertThrowsError(try LayoutSplitConfiguration(gapFraction: fraction).validate(rowKeyCounts: [10]))
        }
        XCTAssertThrowsError(try LayoutSplitConfiguration(rowBreaks: [10]).validate(rowKeyCounts: [10]))
        XCTAssertThrowsError(try LayoutSplitConfiguration(rowBreaks: [0]).validate(rowKeyCounts: [10]))
    }

    func testMoreCutsThanRowsExplainsTheCutsNotTheSpacing() {
        XCTAssertThrowsError(try LayoutSplitConfiguration(rowBreaks: [5, 2]).validate(rowKeyCounts: [10])) { error in
            XCTAssertEqual(error as? LayoutError, .invalid("拆分位置比按键行还多，请重新设置拆分位置。"))
        }
    }
}
