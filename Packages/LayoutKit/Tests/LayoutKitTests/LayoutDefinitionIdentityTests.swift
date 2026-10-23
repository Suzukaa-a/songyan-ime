import XCTest

@testable import LayoutKit

/// `LayoutDefinition.runtimeIdentity` is stable, content-level and deterministic across calls (no random `Hasher`),
/// and unprovable identities never equal anything (`.unproven` / `.absent` never revive old state).
///
/// The transaction layer uses it to decide whether it is still the same physical definition. Using only `id` /
/// `kind` / `schemaID` would treat "same id, new content" as a no-op and let an old lock/opaque token survive
/// across physical definitions.
final class LayoutDefinitionIdentityTests: XCTestCase {

    private func code(_ v: String) -> LayoutKey {
        LayoutKey(label: v, secondaryLabel: v, action: .init(.code, value: v))
    }
    private func controls() -> LayoutRow {
        LayoutRow(keys: [
            LayoutKey(label: "布局", action: .init(.modeSwitch, value: "nextLayout")),
            LayoutKey(label: "空格", width: 4, action: .init(.space)),
            LayoutKey(label: "⌫", action: .init(.backspace)),
            LayoutKey(label: "⏎", action: .init(.enter)),
        ])
    }
    private func merged14(name: String = "14 键", rowsOverride: [[String]]? = nil) -> LayoutDefinition {
        let groups =
            rowsOverride ?? [
                ["q", "e", "t", "u", "o"], ["a", "d", "g", "j"],
                ["l", "z", "c", "b", "m"],
            ]
        return LayoutDefinition(
            id: "merged14", name: name,
            input: .init(builtinLayout: .merged14),
            rows: groups.map { LayoutRow(keys: $0.map(code)) } + [controls()])
    }

    /// Same id and same behavior content give the same identity (stable across calls, repeatable).
    func testSameContentSameIDYieldsStableIdentity() {
        let a = merged14()
        let b = merged14()
        XCTAssertTrue(a.runtimeIdentity.isProvablySame(as: b.runtimeIdentity))
        XCTAssertTrue(a.runtimeIdentity.isProvablySame(as: a.runtimeIdentity), "repeated calls must be stable")
        guard case .proven(let canonical) = a.runtimeIdentity else {
            return XCTFail("an encodable definition must yield .proven")
        }
        XCTAssertTrue(canonical.contains("\"id\":\"merged14\""), "the content-level encoding must carry the id")
    }

    /// A pure rename / note edit does not change behavior, so identity is unchanged (a true no-op that must not trigger a config-change confirmation).
    func testRenameAndNoteDoNotChangeIdentity() {
        let base = merged14(name: "14 键")
        let renamed = LayoutDefinition(
            id: base.id, name: "新的名字", input: base.input,
            rows: base.rows, auxiliaryAreas: base.auxiliaryAreas,
            note: "改过的说明", longPressDelay: base.longPressDelay)
        XCTAssertNotEqual(renamed, base, "name/note really changed (at the Equatable level)")
        XCTAssertTrue(
            renamed.runtimeIdentity.isProvablySame(as: base.runtimeIdentity),
            "但行为内容未变 → identity 必须相同（纯改名是 no-op）")
    }

    /// A key action change (same id, same row shape) must change identity.
    func testKeyActionChangeChangesIdentity() {
        let base = merged14()
        var rows = base.rows
        var keys = rows[0].keys
        keys[0] = LayoutKey(label: "QW", action: .init(.code, value: "w"))  // q → w
        rows[0] = LayoutRow(keys: keys)
        let mutated = LayoutDefinition(
            id: base.id, name: base.name, input: base.input,
            rows: rows, auxiliaryAreas: base.auxiliaryAreas,
            note: base.note)
        XCTAssertEqual(mutated.id, base.id, "same id")
        XCTAssertFalse(
            mutated.runtimeIdentity.isProvablySame(as: base.runtimeIdentity),
            "键 action 变化必须改变 identity")
    }

    /// A change in row shape must change identity.
    func testRowShapeChangeChangesIdentity() {
        let base = merged14()
        let reordered = merged14(rowsOverride: [
            ["q", "e", "t", "u", "o"], ["a", "d", "g", "j"],
            ["m", "z", "c", "b", "l"],
        ])
        XCTAssertFalse(reordered.runtimeIdentity.isProvablySame(as: base.runtimeIdentity))
    }

    /// An `input` (binding) change must change identity (kind/schema cannot approximate it).
    func testInputChangeChangesIdentity() {
        let base = merged14()
        let rebound = LayoutDefinition(
            id: base.id, name: base.name,
            input: .init(schemaID: "imported_14"),
            rows: base.rows, auxiliaryAreas: base.auxiliaryAreas,
            note: base.note)
        XCTAssertFalse(rebound.runtimeIdentity.isProvablySame(as: base.runtimeIdentity))
    }

    /// A change to long-press alternates / width weights / auxiliary areas must change identity.
    func testLongPressWidthAndAuxiliaryAreasChangeIdentity() {
        let base = merged14()

        var rows = base.rows
        var keys = rows[0].keys
        keys[0] = LayoutKey(
            label: keys[0].label, secondaryLabel: keys[0].secondaryLabel,
            width: keys[0].width, action: keys[0].action,
            longPress: [.init(label: "z", action: .init(.literal, value: "z"))])
        rows[0] = LayoutRow(keys: keys)
        let withLongPress = LayoutDefinition(
            id: base.id, name: base.name, input: base.input,
            rows: rows, auxiliaryAreas: base.auxiliaryAreas)
        XCTAssertFalse(withLongPress.runtimeIdentity.isProvablySame(as: base.runtimeIdentity), "long-press alternates")

        var weighted = base.rows
        var weightedKeys = weighted[0].keys
        weightedKeys[0] = LayoutKey(
            label: weightedKeys[0].label, width: 2,
            action: weightedKeys[0].action)
        weighted[0] = LayoutRow(keys: weightedKeys)
        let withWidth = LayoutDefinition(
            id: base.id, name: base.name, input: base.input,
            rows: weighted, auxiliaryAreas: base.auxiliaryAreas)
        XCTAssertFalse(withWidth.runtimeIdentity.isProvablySame(as: base.runtimeIdentity), "width weight")

        let withAux = LayoutDefinition(
            id: base.id, name: base.name, input: base.input,
            rows: base.rows,
            auxiliaryAreas: [
                .init(
                    position: .leading, role: .editing,
                    keys: [code("x")])
            ])
        XCTAssertFalse(withAux.runtimeIdentity.isProvablySame(as: base.runtimeIdentity), "auxiliary area")
    }

    /// A different id (even with identical content) gives a different identity.
    func testDifferentIDChangesIdentity() {
        let a = LayoutDefinition(
            id: "a", name: "n", input: .init(builtinLayout: .merged14),
            rows: merged14().rows)
        let b = LayoutDefinition(
            id: "b", name: "n", input: .init(builtinLayout: .merged14),
            rows: merged14().rows)
        XCTAssertFalse(a.runtimeIdentity.isProvablySame(as: b.runtimeIdentity))
    }

    /// Process-independent: does not rely on `Hasher` (stable across repeated computation in one process and
    /// unaffected by `SWIFT_DETERMINISTIC_HASHING`).
    func testIdentityIsNotHashOrderDependent() {
        let definition = BuiltinLayouts.merged14
        let identities = (0..<8).map { _ in definition.runtimeIdentity }
        for other in identities.dropFirst() {
            XCTAssertTrue(identities[0].isProvablySame(as: other), "must be fully deterministic")
        }
        XCTAssertTrue(definition.runtimeIdentity.isProven)
    }

    // MARK: Unprovable fails closed (never collides, never counts as equal)

    /// Injected encoding failure: `identity` must yield `.unproven(id:)` and must not pass the id off as content identity.
    func testEncodingFailureYieldsUnprovenNeverCollides() {
        let a = merged14(name: "A")
        var rows = a.rows
        var keys = rows[0].keys
        keys[0] = LayoutKey(label: "W", action: .init(.code, value: "w"))
        rows[0] = LayoutRow(keys: keys)
        let b = LayoutDefinition(id: a.id, name: "B", input: a.input, rows: rows)
        XCTAssertEqual(a.id, b.id, "two definitions with the same id and different content")

        let failing: (LayoutDefinition) throws -> String = { _ in
            throw LayoutIdentityEncoder.EncodingUnavailable()
        }
        let idA = LayoutIdentityEncoder.identity(for: a, encode: failing)
        let idB = LayoutIdentityEncoder.identity(for: b, encode: failing)
        guard case .unproven(let unprovenID) = idA else {
            return XCTFail("encoding failure must be .unproven, got \(idA)")
        }
        XCTAssertEqual(unprovenID, a.id, "only the id is kept for diagnostics")
        XCTAssertFalse(idA.isProven)
        // Key point: two different contents with the same id must never be judged the same on failure (the old implementation collided).
        XCTAssertFalse(idA.isProvablySame(as: idB), "unprovable never counts as the same")
        // Even compared with itself it must be false (unprovable counts as changed).
        XCTAssertFalse(idA.isProvablySame(as: idA), "unproven is not the same even as itself")
    }

    /// `.absent == .absent` is not the same (callers must treat it as a change).
    func testAbsentNeverEqualsAbsent() {
        XCTAssertFalse(LayoutRuntimeIdentity.absent.isProvablySame(as: .absent))
        XCTAssertFalse(
            LayoutRuntimeIdentity(nil as LayoutDefinition?).isProvablySame(
                as: LayoutRuntimeIdentity(nil as LayoutDefinition?)))
    }

    /// Mixed states are always false: proven vs unproven / proven vs absent.
    func testMixedStatesAreNeverSame() {
        let definition = merged14()
        let proven = definition.runtimeIdentity
        XCTAssertFalse(proven.isProvablySame(as: .unproven(id: definition.id)))
        XCTAssertFalse(proven.isProvablySame(as: .absent))
        XCTAssertFalse(LayoutRuntimeIdentity.unproven(id: "x").isProvablySame(as: .absent))
    }
}
