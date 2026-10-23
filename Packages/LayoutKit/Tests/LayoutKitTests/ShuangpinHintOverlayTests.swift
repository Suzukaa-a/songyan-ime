import XCTest

@testable import LayoutKit

final class ShuangpinHintOverlayTests: XCTestCase {
    func testLetterGroupsCoverTheBundledLetterLayouts() {
        XCTAssertEqual(ShuangpinHintOverlay.letterGroups(for: BuiltinLayouts.qwerty26)?.count, 26)
        XCTAssertEqual(ShuangpinHintOverlay.letterGroups(for: BuiltinLayouts.merged14)?.count, 14)
        XCTAssertEqual(ShuangpinHintOverlay.letterGroups(for: BuiltinLayouts.merged18)?.count, 18)
        XCTAssertNil(ShuangpinHintOverlay.letterGroups(for: BuiltinLayouts.phone9))
        XCTAssertNil(ShuangpinHintOverlay.letterGroups(for: nil))
        let renamed = LayoutDefinition(
            id: "custom", name: "DIY", input: .init(schemaID: "custom"),
            rows: BuiltinLayouts.qwerty26.rows)
        XCTAssertNotNil(ShuangpinHintOverlay.letterGroups(for: renamed))
    }

    func testMislabelledKeysRejectTheWholeLayout() {
        let standard = BuiltinLayouts.qwerty26
        var keys = standard.rows[0].keys
        keys[0] = LayoutKey(label: "q", action: .init(.code, value: "x"))
        let impostor = LayoutDefinition(
            id: "qwerty26", name: "26", input: standard.input,
            rows: [LayoutRow(keys: keys)] + Array(standard.rows.dropFirst()))
        XCTAssertNil(ShuangpinHintOverlay.letterGroups(for: impostor))
        // A merged key that sends its second letter.
        let merged = BuiltinLayouts.merged14
        var first = merged.rows[0].keys
        first[0] = LayoutKey(label: "QW", action: .init(.code, value: "w"))
        let swapped = LayoutDefinition(
            id: "m", name: "m", input: merged.input,
            rows: [LayoutRow(keys: first)] + Array(merged.rows.dropFirst()))
        XCTAssertNil(ShuangpinHintOverlay.letterGroups(for: swapped))
    }

    func testMergedKeysGetOneHintPerLetter() throws {
        let labels = ["q": "iu", "w": "ei", "t": "ue", "r": "uan"]
        let qw = try XCTUnwrap(BuiltinLayouts.merged14.rows[0].keys.first)
        XCTAssertEqual(
            ShuangpinHintOverlay.hints(for: qw, labels: labels, preservingSecondaryLabel: false),
            ["iu", "ei"])
        let we = BuiltinLayouts.merged18.rows[0].keys[1]
        XCTAssertEqual(
            ShuangpinHintOverlay.hints(for: we, labels: labels, preservingSecondaryLabel: false),
            ["ei", nil])
        let q = BuiltinLayouts.merged18.rows[0].keys[0]
        XCTAssertEqual(
            ShuangpinHintOverlay.hints(for: q, labels: labels, preservingSecondaryLabel: false),
            ["iu"])
    }

    func testBuiltinDigitBadgeMayYieldButDIYAnnotationWins() {
        let key = BuiltinLayouts.qwerty26.rows[0].keys[0]
        XCTAssertEqual(
            ShuangpinHintOverlay.hints(
                for: key, labels: ["q": "iu"],
                preservingSecondaryLabel: false), ["iu"])
        XCTAssertEqual(
            ShuangpinHintOverlay.hints(
                for: key, labels: ["q": "iu"],
                preservingSecondaryLabel: true), [nil])
        let custom = LayoutKey(label: "q", secondaryLabel: "自定", action: key.action, longPress: key.longPress)
        XCTAssertEqual(
            ShuangpinHintOverlay.hints(
                for: custom, labels: ["q": "iu"],
                preservingSecondaryLabel: true), [nil])
    }

    func testOnlyExplicitNonemptyHintIsShownAndLiteralKeysAreExcluded() {
        let key = LayoutKey(label: "q", action: .init(.code, value: "q"))
        XCTAssertEqual(
            ShuangpinHintOverlay.hints(
                for: key, labels: ["q": "iu"],
                preservingSecondaryLabel: true), ["iu"])
        XCTAssertEqual(ShuangpinHintOverlay.hints(for: key, labels: [:], preservingSecondaryLabel: false), [nil])
        XCTAssertEqual(
            ShuangpinHintOverlay.hints(for: key, labels: ["q": "  "], preservingSecondaryLabel: false), [nil])
        let literal = LayoutKey(label: "q", action: .init(.literal, value: "q"))
        XCTAssertEqual(
            ShuangpinHintOverlay.hints(for: literal, labels: ["q": "iu"], preservingSecondaryLabel: false), [])
    }
}
