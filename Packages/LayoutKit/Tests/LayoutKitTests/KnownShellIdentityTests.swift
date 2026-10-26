import XCTest

@testable import LayoutKit

/// Structural main-shell identity for the bundled 26/14/18 layouts: metadata and main-row
/// long-press edits keep the native columns/side keys, while width/action/shape/aux edits and an
/// edited control row must fall back to the author renderer (never silently hidden).
final class KnownShellIdentityTests: XCTestCase {
    private var qwerty: LayoutDefinition { BuiltinLayouts.qwerty26 }
    private var merged14: LayoutDefinition { BuiltinLayouts.merged14 }
    private var merged18: LayoutDefinition { BuiltinLayouts.merged18 }

    private func clone(_ preset: LayoutDefinition, rows: [LayoutRow]? = nil) -> LayoutDefinition {
        LayoutDefinition(
            id: preset.id + "-clone", name: preset.name + " 副本", input: preset.input,
            rows: rows ?? preset.rows, auxiliaryAreas: preset.auxiliaryAreas)
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

    private func lp(_ key: LayoutKey) -> LayoutKey {
        key.settingLongPress(
            (key.longPress ?? []) + [LayoutOption(label: "#+=", action: .pageSwitch(.symbols))])
    }

    // MARK: Pristine / metadata

    func testPristinePresetsMatchBothLayers() {
        for preset in [qwerty, merged14, merged18] {
            XCTAssertTrue(expectedMain(preset))
            XCTAssertTrue(expectedControl(preset))
        }
    }

    func testMainLongPressLabelAndTitleEditsKeepShellAndFooter() {
        for preset in [qwerty, merged14, merged18] {
            let lp = clone(preset, rows: replacingKey(in: preset.rows, row: 0, key: 0, with: self.lp))
            XCTAssertTrue(expectedMain(lp))
            XCTAssertTrue(expectedControl(lp))
            let label = clone(preset, rows: replacingKey(in: preset.rows, row: 0, key: 0) { $0.title("X") })
            XCTAssertTrue(expectedMain(label))
            XCTAssertTrue(expectedControl(label))
            let title = clone(
                preset,
                rows: replacingKey(in: preset.rows, row: 0, key: 1) { $0.settingTitleMode(.automatic) })
            XCTAssertTrue(expectedMain(title))
            XCTAssertTrue(expectedControl(title))
        }
    }

    func testMainWidthActionOrderAndCountEditsBreakMainShell() {
        for preset in [qwerty, merged14, merged18] {
            let width = clone(
                preset, rows: replacingKey(in: preset.rows, row: 0, key: 0) { $0.settingWidth(9) })
            XCTAssertFalse(expectedMain(width))
            let action = clone(
                preset,
                rows: replacingKey(in: preset.rows, row: 0, key: 0) { $0.settingAction(.init(.literal, value: "x")) })
            XCTAssertFalse(expectedMain(action))
            var swapped = preset.rows
            swapped[0] = LayoutRow(keys: Array(swapped[0].keys.reversed()))
            XCTAssertFalse(expectedMain(clone(preset, rows: swapped)))
        }
    }

    // MARK: Row shape guards

    func testFourthRowMustStayNonEncoding() {
        for preset in [qwerty, merged14, merged18] {
            var rows = preset.rows
            rows[3] = LayoutRow(keys: rows[3].keys + [LayoutKey(label: "x", action: .init(.code, value: "x"))])
            XCTAssertFalse(expectedMain(clone(preset, rows: rows)))
            XCTAssertFalse(expectedControl(clone(preset, rows: rows)))
        }
    }

    func testExtraFifthRowAndThreeRowShape() {
        for preset in [qwerty, merged14, merged18] {
            let extra = clone(preset, rows: preset.rows + [LayoutRow(keys: [])])
            XCTAssertFalse(expectedMain(extra))
            XCTAssertFalse(expectedControl(extra))
            let threeRows = clone(preset, rows: Array(preset.rows.prefix(3)))
            XCTAssertTrue(expectedMain(threeRows), "the shell draws only the three main rows; no data is dropped")
            XCTAssertFalse(expectedControl(threeRows))
        }
    }

    // MARK: Footer identity

    func testControlRowEditsKeepMainShellButBreakFooterPolicy() {
        for preset in [qwerty, merged14, merged18] {
            var rows = preset.rows
            let control = rows[3]
            rows[3] = LayoutRow(
                keys: control.keys.enumerated().map { index, key in
                    index == 0 ? key.title("自定义") : key
                })
            let edited = clone(preset, rows: rows)
            XCTAssertTrue(expectedMain(edited))
            XCTAssertFalse(expectedControl(edited))
            var lpRows = preset.rows
            lpRows[3] = LayoutRow(
                keys: lpRows[3].keys.enumerated().map { index, key in
                    index == 0 ? lp(key) : key
                })
            let lpEdited = clone(preset, rows: lpRows)
            XCTAssertTrue(expectedMain(lpEdited))
            XCTAssertFalse(expectedControl(lpEdited))
        }
    }

    func testAuxEditsBreakMainShell() {
        for preset in [qwerty, merged14, merged18] {
            let areas = [
                LayoutAuxiliaryArea(
                    position: .trailing, role: .editing,
                    keys: [LayoutKey(label: "⌫", action: .init(.backspace))])
            ]
            let edited = LayoutDefinition(
                id: preset.id + "-aux", name: preset.name, input: preset.input,
                rows: preset.rows, auxiliaryAreas: areas)
            XCTAssertFalse(expectedMain(edited))
            XCTAssertFalse(expectedControl(edited))
        }
    }

    // MARK: Unknown metadata

    func testUnknownSchemaAndImportedShapesNeverMatch() {
        let bound = LayoutDefinition(
            id: "bound", name: "绑定", input: .init(schemaID: "unknown", builtinLayout: .qwerty26),
            rows: qwerty.rows, auxiliaryAreas: qwerty.auxiliaryAreas)
        XCTAssertFalse(expectedMain(bound))
        XCTAssertFalse(expectedControl(bound))
        let imported = LayoutDefinition(
            id: "imported", name: "导入", input: .init(), rows: qwerty.rows,
            auxiliaryAreas: qwerty.auxiliaryAreas)
        XCTAssertFalse(expectedMain(imported))
        XCTAssertFalse(expectedControl(imported))
        let mergedWithQwertyShell = LayoutDefinition(
            id: "cross", name: "cross", input: .init(builtinLayout: .qwerty26),
            rows: merged14.rows, auxiliaryAreas: nil)
        XCTAssertFalse(expectedMain(mergedWithQwertyShell))
    }

    // MARK: Helpers

    private func expectedMain(_ definition: LayoutDefinition) -> Bool {
        switch definition.input.builtinLayout {
        case .qwerty26: return BuiltinLayouts.matchesQwerty26MainShell(definition)
        case .merged14: return BuiltinLayouts.matchesMerged14MainShell(definition)
        case .merged18: return BuiltinLayouts.matchesMerged18MainShell(definition)
        default: return false
        }
    }

    private func expectedControl(_ definition: LayoutDefinition) -> Bool {
        switch definition.input.builtinLayout {
        case .qwerty26: return BuiltinLayouts.matchesQwerty26ControlRowPolicy(definition)
        case .merged14: return BuiltinLayouts.matchesMerged14ControlRowPolicy(definition)
        case .merged18: return BuiltinLayouts.matchesMerged18ControlRowPolicy(definition)
        default: return false
        }
    }
}
