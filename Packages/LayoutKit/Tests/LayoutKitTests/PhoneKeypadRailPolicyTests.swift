import XCTest

@testable import LayoutKit

/// The trailing/leading rail policy must never fabricate an action for an
/// imported keypad. This is the regression the review flagged: an imported phone
/// keypad that declared no trailing auxiliary previously had a Delete + separator
/// injected out of nowhere.
final class PhoneKeypadRailPolicyTests: XCTestCase {
    /// A minimal canonical 3×3 telephone pad (rows only; the rail policy tests do
    /// not exercise `PhoneKeypadStructure`).
    private func phoneRows(trailingControls: Bool = false) -> [LayoutRow] {
        func key(_ value: String) -> LayoutKey {
            LayoutKey(label: value, secondaryLabel: value, action: .init(.code, value: value))
        }
        var rows: [LayoutRow] = [
            LayoutRow(keys: [
                LayoutKey(
                    label: "，。？", secondaryLabel: "1", action: .init(.literal, value: "，"),
                    longPress: [.init(label: "1", action: .init(.literal, value: "1"))]),
                key("2"), key("3"),
            ]),
            LayoutRow(keys: [key("4"), key("5"), key("6")]),
            LayoutRow(keys: [key("7"), key("8"), key("9")]),
        ]
        if trailingControls {
            rows.append(
                LayoutRow(keys: [
                    LayoutKey(label: "布局", action: .init(.modeSwitch, value: "nextLayout")),
                    LayoutKey(label: "空格", width: 4, action: .init(.space)),
                ]))
        }
        return rows
    }

    func testBundledT9AlwaysGetsItsAuthoredRail() {
        for declared in [0, 1, 2, 5] {
            XCTAssertEqual(
                PhoneKeypadRailPolicy.trailing(isBuiltinPhonePad: true, declaredKeyCount: declared),
                .bundledAuthored)
            XCTAssertEqual(
                PhoneKeypadRailPolicy.leading(isBuiltinPhonePad: true, declaredKeyCount: declared),
                .bundledAuthored)
        }
        // Delete[1] + 重输[1] + Return/Confirm[2] reaching into the control row, so
        // Return sits in the bottom-right corner and no reading-cycle key is invented.
        XCTAssertEqual(PhoneKeypadRailPolicy.bundledTrailingSpans, [1, 1, 2])
    }

    func testImportedKeypadWithNoDeclaredRailRendersNothing() {
        XCTAssertEqual(
            PhoneKeypadRailPolicy.trailing(isBuiltinPhonePad: false, declaredKeyCount: 0), .empty,
            "no trailing auxiliary must not inject Delete/separator")
        XCTAssertEqual(PhoneKeypadRailPolicy.leading(isBuiltinPhonePad: false, declaredKeyCount: 0), .empty)
    }

    func testImportedKeypadRendersExactlyItsDeclaredKeys() {
        for count in [1, 2, 3, 7] {
            XCTAssertEqual(
                PhoneKeypadRailPolicy.trailing(isBuiltinPhonePad: false, declaredKeyCount: count),
                .declared(keyCount: count),
                "an import must render exactly \(count) declared keys")
            XCTAssertEqual(
                PhoneKeypadRailPolicy.leading(isBuiltinPhonePad: false, declaredKeyCount: count),
                .declared(keyCount: count))
        }
    }

    /// The bundled rail is only ever produced for `isBuiltinPhonePad == true`, regardless
    /// of declared count. This is the invariant that makes injection impossible.
    func testAuthoredRailIsUnreachableForImports() {
        for declared in 0...12 {
            XCTAssertNotEqual(
                PhoneKeypadRailPolicy.trailing(isBuiltinPhonePad: false, declaredKeyCount: declared),
                .bundledAuthored)
            XCTAssertNotEqual(
                PhoneKeypadRailPolicy.leading(isBuiltinPhonePad: false, declaredKeyCount: declared),
                .bundledAuthored)
        }
    }

    // MARK: Declared keys are read verbatim; nothing is invented or dropped

    private func key(_ label: String, _ type: LayoutAction.Kind, value: String? = nil) -> LayoutKey {
        LayoutKey(label: label, action: .init(type, value: value))
    }

    func testDeclaredRailKeysAreReadVerbatim() {
        // An import that authors its own trailing rail gets exactly those keys.
        let definition = LayoutDefinition(
            id: "import-rail", name: "导入", input: .init(schemaID: "imported_t9"),
            rows: phoneRows(),
            auxiliaryAreas: [
                .init(
                    position: .trailing, role: .editing,
                    keys: [
                        key("⌫", .backspace), key("⏎", .enter),
                    ])
            ])
        let declared = PhoneKeypadRailPolicy.declaredKeys(in: definition, position: .trailing)
        XCTAssertEqual(declared.map(\.action.type), [.backspace, .enter])
        XCTAssertEqual(
            PhoneKeypadRailPolicy.trailing(isBuiltinPhonePad: false, declaredKeyCount: declared.count),
            .declared(keyCount: 2))
        // Leading side declared nothing.
        XCTAssertEqual(PhoneKeypadRailPolicy.declaredKeys(in: definition, position: .leading), [])
        XCTAssertEqual(PhoneKeypadRailPolicy.leading(isBuiltinPhonePad: false, declaredKeyCount: 0), .empty)
    }

    func testEngineDisambiguationAreasAreExcludedFromRails() {
        let definition = LayoutDefinition(
            id: "import-disambig", name: "导入", input: .init(schemaID: "imported_t9"),
            rows: phoneRows(),
            auxiliaryAreas: [
                // Engine-backed region with no static keys and one with keys: both
                // are runtime-only and must never become a static rail.
                .init(position: .leading, role: .disambiguation),
                .init(
                    position: .trailing, role: .disambiguation,
                    keys: [key("runtime", .literal, value: "x")]),
            ])
        XCTAssertTrue(PhoneKeypadRailPolicy.declaredKeys(in: definition, position: .leading).isEmpty)
        XCTAssertTrue(PhoneKeypadRailPolicy.declaredKeys(in: definition, position: .trailing).isEmpty)
    }

    func testDeclaredControlRowIsPreservedForImport() {
        // An import that declares a control row keeps exactly those keys; the shell
        // does not add a Delete/return the user did not author.
        let rows = phoneRows(trailingControls: true)
        let definition = LayoutDefinition(
            id: "import-controls", name: "导入",
            input: .init(schemaID: "imported_t9"), rows: rows)
        let control = PhoneKeypadRailPolicy.controlRowKeys(in: definition)
        XCTAssertEqual(control, rows.last!.keys)
        XCTAssertEqual(control?.map(\.action.type), [.modeSwitch, .space])
    }

    func testPadWithNoDeleteAnywhereStaysWithoutOne() {
        // Declared control row has no delete: the shell must report exactly the
        // authored keys (nothing injected), so no Delete appears from the rail
        // policy nor from the control row.
        let rows = phoneRows(trailingControls: true)
        let definition = LayoutDefinition(
            id: "import-nodelete", name: "导入",
            input: .init(schemaID: "imported_t9"), rows: rows)
        let types = (PhoneKeypadRailPolicy.controlRowKeys(in: definition) ?? []).map(\.action.type)
        XCTAssertFalse(types.contains(.backspace))
        XCTAssertEqual(PhoneKeypadRailPolicy.declaredKeys(in: definition, position: .trailing), [])
        XCTAssertEqual(
            PhoneKeypadRailPolicy.trailing(isBuiltinPhonePad: false, declaredKeyCount: 0), .empty,
            "the shell must not conjure a Delete for a pad that declared none")
    }
}
