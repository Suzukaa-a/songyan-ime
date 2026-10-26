import XCTest

@testable import LayoutKit

final class KeyboardPageFooterGeometryTests: XCTestCase {
    private func lettersPolicy(globe: Bool = true) -> KeyboardControlPolicy {
        KeyboardControlPolicy(
            page: .letters, isEnglishMode: false, hasGlobe: globe,
            isPhoneLayout: false, usesASCIIPunctuation: false)
    }

    private func footer(_ page: KeyboardPageDefinition) -> [LayoutKey] {
        page.materialized().chrome?.bottom ?? []
    }

    private func assertFillsWidth(
        _ geometry: KeyboardPageFooterGeometry, width: Double, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(
            geometry.keyWidths.reduce(0, +) + geometry.spacing * Double(max(0, geometry.keyWidths.count - 1)),
            width, accuracy: 0.001, file: file, line: line)
        XCTAssertTrue(geometry.keyWidths.allSatisfy { $0.isFinite && $0 >= 0 }, file: file, line: line)
    }

    func testDefaultABCFooterKeepsTheControlRowBudget() {
        let keys = footer(KeyboardPagePresets.englishQwerty)
        for width in [320.0, 382, 466, 834] {
            let policy = lettersPolicy()
            let geometry = KeyboardPageFooterGeometry(width: width, keys: keys, policy: policy)
            XCTAssertTrue(geometry.usesControlRowBudget)
            let metrics = policy.metrics(width: width)
            XCTAssertEqual(geometry.keyWidths, policy.slots.map { metrics[$0] })
            // The tuned default bottom row is not squeezed by a fresh copy.
            XCTAssertEqual(geometry.keyWidths[3], metrics[.space], accuracy: 0.001)
            assertFillsWidth(geometry, width: width)
        }
    }

    func testHiddenGlobeUsesTheSameBudgetWithoutItsWidth() {
        let metricsKeys = footer(KeyboardPagePresets.englishQwerty).filter { $0.action.type != .globe }
        let policy = lettersPolicy(globe: false)
        let geometry = KeyboardPageFooterGeometry(width: 382, keys: metricsKeys, policy: policy)
        XCTAssertTrue(geometry.usesControlRowBudget)
        XCTAssertEqual(geometry.keyWidths.count, metricsKeys.count)
        assertFillsWidth(geometry, width: 382)
        XCTAssertGreaterThan(geometry.keyWidths[2], 100, "space takes the width the hidden globe gave up")
    }

    func testEveryDefaultFooterVariantMatchesItsOwnControlRowPolicy() {
        let variants: [(KeyboardPageDefinition, KeyboardControlPolicy)] = [
            (
                KeyboardPagePresets.numericChinese,
                KeyboardControlPolicy(
                    page: .numeric, isEnglishMode: false, hasGlobe: true,
                    isPhoneLayout: false, usesASCIIPunctuation: false)
            ),
            (
                KeyboardPagePresets.symbolsChinese,
                KeyboardControlPolicy(
                    page: .symbols, isEnglishMode: false, hasGlobe: true,
                    isPhoneLayout: false, usesASCIIPunctuation: false, usesCategorySymbolPage: false)
            ),
            (
                KeyboardPagePresets.symbolsCategorized,
                KeyboardControlPolicy(
                    page: .symbols, isEnglishMode: false, hasGlobe: true,
                    isPhoneLayout: true, usesASCIIPunctuation: false, includesBottomEnter: false)
            ),
            (
                KeyboardPagePresets.numericKeypad,
                KeyboardControlPolicy(
                    page: .numeric, isEnglishMode: false, hasGlobe: true,
                    isPhoneLayout: true, usesASCIIPunctuation: false, includesBottomEnter: false)
            ),
        ]
        for (page, policy) in variants {
            let geometry = KeyboardPageFooterGeometry(width: 402, keys: footer(page), policy: policy)
            XCTAssertTrue(geometry.usesControlRowBudget, page.name)
            assertFillsWidth(geometry, width: 402)
        }
    }

    func testKeypadFooterOnThePhoneShellKeepsTheRailColumns() {
        let policy = KeyboardControlPolicy(
            page: .numeric, isEnglishMode: false, hasGlobe: false,
            isPhoneLayout: true, usesASCIIPunctuation: false, includesBottomEnter: false
        ).aligned(to: .init(rail: 88, digit: 64))
        let keys = footer(KeyboardPagePresets.numericKeypad).filter { $0.action.type != .globe }
        let geometry = KeyboardPageFooterGeometry(width: 402, keys: keys, policy: policy)
        XCTAssertTrue(geometry.usesControlRowBudget)
        XCTAssertEqual(geometry.keyWidths[0], 88, accuracy: 0.001, "the first bottom key sits under the rail")
        assertFillsWidth(geometry, width: 402)
    }

    func testCustomLabelsAndLongPressDoNotChangeTheGeometry() {
        let policy = lettersPolicy()
        let baseline = KeyboardPageFooterGeometry(
            width: 382, keys: footer(KeyboardPagePresets.englishQwerty), policy: policy)
        let decorated = footer(KeyboardPagePresets.englishQwerty).map { key in
            key.title("我的\(key.label)").settingSecondaryLabel("提示").settingLongPress([
                LayoutOption(label: "选项", action: .pageSwitch(.letters))
            ])
        }
        let geometry = KeyboardPageFooterGeometry(width: 382, keys: decorated, policy: policy)
        XCTAssertTrue(geometry.usesControlRowBudget)
        XCTAssertEqual(geometry.keyWidths, baseline.keyWidths)
    }

    func testAnyWidthOrStructureChangeFallsBackToAuthoredRelativeWidths() {
        let policy = lettersPolicy()
        let defaults = footer(KeyboardPagePresets.englishQwerty)
        var spaceWider = defaults
        spaceWider[3] = spaceWider[3].settingWidth(3)
        XCTAssertFalse(
            KeyboardPageFooterGeometry(width: 382, keys: spaceWider, policy: policy).usesControlRowBudget)

        var globeExplicit = defaults
        globeExplicit[0] = globeExplicit[0].settingWidth(1)
        XCTAssertFalse(
            KeyboardPageFooterGeometry(width: 382, keys: globeExplicit, policy: policy).usesControlRowBudget)

        var letterExplicit = defaults
        letterExplicit[1] = letterExplicit[1].settingWidth(1)
        XCTAssertFalse(
            KeyboardPageFooterGeometry(width: 382, keys: letterExplicit, policy: policy).usesControlRowBudget)

        let reordered = [defaults[0], defaults[2], defaults[1], defaults[3], defaults[4], defaults[5]]
        XCTAssertFalse(
            KeyboardPageFooterGeometry(width: 382, keys: reordered, policy: policy).usesControlRowBudget)

        let fewer = Array(defaults.dropLast())
        XCTAssertFalse(
            KeyboardPageFooterGeometry(width: 382, keys: fewer, policy: policy).usesControlRowBudget)
        let more = defaults + [LayoutKey(label: "×", action: .init(.clearInput))]
        XCTAssertFalse(
            KeyboardPageFooterGeometry(width: 382, keys: more, policy: policy).usesControlRowBudget)

        // Author deletes the globe but the live system does offer one: no auto-repair, generic.
        let globeDeleted = Array(defaults.dropFirst())
        XCTAssertFalse(
            KeyboardPageFooterGeometry(width: 382, keys: globeDeleted, policy: policy).usesControlRowBudget)
    }

    func testAuthoredRelativeWidthsShareTheAvailableWidth() {
        let keys = [
            LayoutKey(label: "a", width: 1, action: .pageSwitch(.numeric)),
            LayoutKey(label: "b", width: 3, action: .init(.literal, value: "b")),
        ]
        let policy = lettersPolicy()
        let geometry = KeyboardPageFooterGeometry(width: 402, keys: keys, policy: policy)
        XCTAssertFalse(geometry.usesControlRowBudget)
        let available = 402 - geometry.spacing
        XCTAssertEqual(geometry.keyWidths, [available / 4, available * 3 / 4])
        assertFillsWidth(geometry, width: 402)
    }

    func testHugeFiniteWeightsStayFinite() {
        let keys = [
            LayoutKey(label: "a", width: Double.greatestFiniteMagnitude, action: .pageSwitch(.letters)),
            LayoutKey(label: "b", width: 1, action: .init(.literal, value: "b")),
            LayoutKey(label: "c", width: Double.greatestFiniteMagnitude, action: .init(.literal, value: "c")),
        ]
        let geometry = KeyboardPageFooterGeometry(width: 402, keys: keys, policy: lettersPolicy())
        XCTAssertFalse(geometry.usesControlRowBudget)
        XCTAssertTrue(geometry.keyWidths.allSatisfy { $0.isFinite && $0 >= 0 })
        XCTAssertEqual(geometry.keyWidths[0], geometry.keyWidths[2], accuracy: 0.001)
        XCTAssertLessThan(geometry.keyWidths[1], geometry.keyWidths[0])
        assertFillsWidth(geometry, width: 402)
    }

    func testEmptyAndInvalidFootersStayFinite() {
        let policy = lettersPolicy()
        let empty = KeyboardPageFooterGeometry(width: 382, keys: [], policy: policy)
        XCTAssertTrue(empty.keyWidths.isEmpty)
        XCTAssertFalse(empty.usesControlRowBudget)
        for width in [-1.0, .nan, .infinity] {
            let geometry = KeyboardPageFooterGeometry(
                width: width, keys: footer(KeyboardPagePresets.englishQwerty), policy: policy)
            XCTAssertTrue(geometry.keyWidths.allSatisfy(\.isFinite))
            XCTAssertTrue(geometry.keyWidths.allSatisfy { $0 >= 0 })
        }
    }
}
