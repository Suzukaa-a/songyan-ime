import XCTest

@testable import LayoutKit

/// The two bundled 9-key identities stay separate:
///  * visual shell identity tolerates only the main rows' long-press menus, because the native shell
///    renders those keys from the definition; it rejects every control-row/rail edit that the shell
///    would otherwise cover up by synthesizing its own keys.
///  * primary-gesture semantics ignores main-row metadata so first-key cycling and digit up-flick
///    survive label/secondary/title edits, but never gates injected chrome. Control-row/rail
///    long-press edits also keep the gestures alive (only their non-LP fields must match).
final class Phone9SemanticsTests: XCTestCase {
    private var preset: LayoutDefinition { BuiltinLayouts.phone9 }

    private func clone(
        rows: [LayoutRow]? = nil, areas: [LayoutAuxiliaryArea]?? = nil,
        input: LayoutInput? = nil
    ) -> LayoutDefinition {
        LayoutDefinition(
            id: "phone9-lp-clone", name: "9 键 LP 副本",
            input: input ?? preset.input, rows: rows ?? preset.rows,
            auxiliaryAreas: areas ?? preset.auxiliaryAreas)
    }

    private func replacingKey(
        in rows: [LayoutRow], row: Int, key: Int, with transform: (LayoutKey) -> LayoutKey
    ) -> [LayoutRow] {
        var rows = rows
        let old = rows[row].keys[key]
        rows[row] = LayoutRow(
            keys: rows[row].keys.enumerated().map { index, value in
                index == key ? transform(old) : value
            })
        return rows
    }

    private func replacingAuxKey(
        in areas: [LayoutAuxiliaryArea], area: Int, key: Int, with transform: (LayoutKey) -> LayoutKey
    ) -> [LayoutAuxiliaryArea] {
        var areas = areas
        let old = areas[area].keys[key]
        areas[area] = LayoutAuxiliaryArea(
            position: areas[area].position, role: areas[area].role,
            keys: areas[area].keys.enumerated().map { index, value in
                index == key ? transform(old) : value
            })
        return areas
    }

    private func extraLongPress(_ key: LayoutKey) -> LayoutKey {
        key.settingLongPress(
            (key.longPress ?? []) + [LayoutOption(label: "#+=", action: .pageSwitch(.symbols))])
    }

    private func assertVisualOnlyIsBroken(
        _ definition: LayoutDefinition, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertFalse(
            BuiltinLayouts.matchesPhone9VisualShell(definition), "visual shell must fall back",
            file: file, line: line)
    }

    // MARK: Pristine

    func testBundledPhone9MatchesBoth() {
        XCTAssertTrue(BuiltinLayouts.matchesPhone9VisualShell(preset))
        XCTAssertTrue(BuiltinLayouts.matchesPhone9PrimarySemantics(preset))
    }

    func testRenamedCloneMatchesBoth() {
        XCTAssertTrue(BuiltinLayouts.matchesPhone9VisualShell(clone()))
        XCTAssertTrue(BuiltinLayouts.matchesPhone9PrimarySemantics(clone()))
    }

    // MARK: Long-press edits on the rendered main rows

    func testFirstKeyAndDigitLongPressEditsKeepBoth() {
        var rows = replacingKey(in: preset.rows, row: 0, key: 0, with: extraLongPress)
        let digitRow = 1
        rows = replacingKey(in: rows, row: digitRow, key: 0) { key in
            key.settingLongPress([])
        }
        let edited = clone(rows: rows)
        XCTAssertTrue(BuiltinLayouts.matchesPhone9VisualShell(edited))
        XCTAssertTrue(BuiltinLayouts.matchesPhone9PrimarySemantics(edited))
    }

    // MARK: Main-row metadata

    func testMainLabelSecondaryTitleEditsKeepPrimaryOnly() {
        let label = clone(rows: replacingKey(in: preset.rows, row: 1, key: 0) { $0.title("RET") })
        let secondary = clone(
            rows: replacingKey(in: preset.rows, row: 1, key: 1) { $0.settingSecondaryLabel("x") })
        let title = clone(
            rows: replacingKey(in: preset.rows, row: 1, key: 2) { $0.settingTitleMode(.automatic) })
        for definition in [label, secondary, title] {
            assertVisualOnlyIsBroken(definition)
            XCTAssertTrue(BuiltinLayouts.matchesPhone9PrimarySemantics(definition))
        }
    }

    // MARK: Main-row geometry / primary action

    func testMainGeometryOrActionEditsBreakBoth() {
        let width = clone(rows: replacingKey(in: preset.rows, row: 1, key: 0) { $0.settingWidth(2) })
        let action = clone(
            rows: replacingKey(in: preset.rows, row: 1, key: 0) { $0.settingAction(.init(.code, value: "0")) })
        var swapped = preset.rows
        swapped[1] = LayoutRow(keys: Array(swapped[1].keys.reversed()))
        let order = clone(rows: swapped)
        let fewerRows = clone(rows: Array(preset.rows.prefix(3)), areas: [])
        for definition in [width, action, order] {
            assertVisualOnlyIsBroken(definition)
            XCTAssertFalse(BuiltinLayouts.matchesPhone9PrimarySemantics(definition))
        }
        // The three-row phone shape keeps the canonical main rows. Its shell identity is false, but
        // primary gestures are main-row only, so they survive the author's structure edit.
        XCTAssertFalse(BuiltinLayouts.matchesPhone9VisualShell(fewerRows))
        XCTAssertTrue(BuiltinLayouts.matchesPhone9PrimarySemantics(fewerRows))
    }

    func testMainKeyCountChangeBreaksBoth() {
        var rows = preset.rows
        rows[0] = LayoutRow(keys: Array(rows[0].keys.prefix(2)) + Array(preset.rows[0].keys.prefix(1)))
        let edited = clone(rows: rows)
        XCTAssertFalse(BuiltinLayouts.matchesPhone9PrimarySemantics(edited))
        assertVisualOnlyIsBroken(edited)
    }

    // MARK: Injected control row / rails

    func testControlRowLongPressEditKeepsPrimaryGestures() {
        var parts = preset.rows
        let last = parts.count - 1
        parts[last] = LayoutRow(
            keys: parts[last].keys.enumerated().map { index, key in
                index == 0 ? extraLongPress(key) : key
            })
        let edited = clone(rows: parts)
        assertVisualOnlyIsBroken(edited)
        XCTAssertTrue(
            BuiltinLayouts.matchesPhone9PrimarySemantics(edited),
            "a footer long-press edit must not re-degrade digit flick / first-key cycling")
    }

    func testControlRowNonLongPressEditsKeepPrimaryGestures() {
        var parts = preset.rows
        let last = parts.count - 1
        let label = clone(
            rows: {
                parts[last] = LayoutRow(
                    keys: parts[last].keys.enumerated().map { index, key in
                        index == 0 ? key.title("布局!") : key
                    })
                return parts
            }())
        let width = clone(
            rows: {
                parts[last] = LayoutRow(
                    keys: parts[last].keys.enumerated().map { index, key in
                        index == 1 ? key.settingWidth(8) : key
                    })
                return parts
            }())
        for definition in [label, width] {
            assertVisualOnlyIsBroken(definition)
            // The shell falls back to the author renderer (its fixed row would otherwise hide these
            // edits), but the main-row gestures stay native.
            XCTAssertTrue(BuiltinLayouts.matchesPhone9PrimarySemantics(definition))
        }
    }

    func testRailLongPressEditKeepsPrimaryGestures() {
        guard let areas = preset.auxiliaryAreas else { return XCTFail("preset has rails") }
        let edited = clone(areas: replacingAuxKey(in: areas, area: 0, key: 0, with: extraLongPress))
        assertVisualOnlyIsBroken(edited)
        XCTAssertTrue(BuiltinLayouts.matchesPhone9PrimarySemantics(edited))
    }

    func testRailNonLongPressOrShapeEditsKeepPrimaryGestures() {
        guard let areas = preset.auxiliaryAreas else { return XCTFail("preset has rails") }
        let label = clone(areas: replacingAuxKey(in: areas, area: 0, key: 0) { $0.title("Del") })
        let action = clone(areas: replacingAuxKey(in: areas, area: 0, key: 1) { $0.settingAction(.init(.enter)) })
        let removed = clone(
            areas: areas.enumerated().map { index, area in
                index == 0
                    ? LayoutAuxiliaryArea(
                        position: area.position, role: area.role, keys: Array(area.keys.dropFirst()))
                    : area
            })
        for definition in [label, action, removed] {
            assertVisualOnlyIsBroken(definition)
            // Rails are not part of the main-row gesture predicate; the author renderer shows them.
            XCTAssertTrue(BuiltinLayouts.matchesPhone9PrimarySemantics(definition))
        }
    }

    // MARK: Unknown / other builtin layouts

    func testUnknownSchemaNeverMatches() {
        let bound = clone(input: .init(schemaID: "unknown_t9", builtinLayout: .phone9))
        for definition in [bound] {
            XCTAssertFalse(BuiltinLayouts.matchesPhone9VisualShell(definition))
            XCTAssertFalse(BuiltinLayouts.matchesPhone9PrimarySemantics(definition))
        }
    }

    func testOtherBuiltinLayoutsNeverMatch() {
        for definition in [BuiltinLayouts.qwerty26, BuiltinLayouts.merged14, BuiltinLayouts.merged18] {
            XCTAssertFalse(BuiltinLayouts.matchesPhone9VisualShell(definition))
            XCTAssertFalse(BuiltinLayouts.matchesPhone9PrimarySemantics(definition))
        }
    }

    func testImportedPhoneShapeWithoutBuiltinMetadataNeverMatches() {
        let imported = LayoutDefinition(
            id: "imported-t9", name: "导入九键", input: .init(),
            rows: preset.rows, auxiliaryAreas: preset.auxiliaryAreas)
        XCTAssertFalse(BuiltinLayouts.matchesPhone9VisualShell(imported))
        XCTAssertFalse(BuiltinLayouts.matchesPhone9PrimarySemantics(imported))
    }
}
