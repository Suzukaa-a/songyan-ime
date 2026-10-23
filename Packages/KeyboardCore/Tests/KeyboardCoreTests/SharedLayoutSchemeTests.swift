import Foundation
import XCTest

@testable import KeyboardCore

/// Several input schemes can share one physical layout; the layout never names a scheme.
final class SharedLayoutSchemeTests: XCTestCase {
    func testLayoutRawValuesAreSchemeNeutral() throws {
        XCTAssertEqual(KeyboardLayoutKind.allCases.map(\.rawValue), ["qwerty26", "merged14", "merged18", "phone9"])
        XCTAssertThrowsError(try JSONDecoder().decode(KeyboardLayoutKind.self, from: Data(#""flypy26""#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(KeyboardLayoutKind.self, from: Data(#""unknown""#.utf8)))
        for layout in KeyboardLayoutKind.allCases {
            for word in ["全拼", "双拼", "小鹤", "拼音"] {
                XCTAssertFalse(layout.userTitle.contains(word))
                XCTAssertFalse(layout.detail.contains(word))
            }
        }
    }

    func testBuiltinSchemesRunOnEveryLayoutThroughCompanions() {
        for source in BuiltinTemplateSchemas.sourceSchemaIDs {
            XCTAssertEqual(BuiltinTemplateSchemas.layout(forSchemaID: source), .qwerty26)
            for layout in KeyboardLayoutKind.allCases {
                let engine = BuiltinTemplateSchemas.engineSchemaID(source: source, layout: layout)
                XCTAssertNotNil(engine)
                XCTAssertEqual(engine.flatMap(BuiltinTemplateSchemas.layout(forSchemaID:)), layout)
            }
        }
        XCTAssertNil(BuiltinTemplateSchemas.layout(forSchemaID: "nonexistent"))
        XCTAssertNil(BuiltinTemplateSchemas.engineSchemaID(source: "nonexistent", layout: .qwerty26))
        for layout in KeyboardLayoutKind.allCases {
            let schemaID = BuiltinTemplateSchemas.defaultSchemaID(for: layout)
            XCTAssertNotNil(schemaID)
            XCTAssertEqual(schemaID.flatMap(BuiltinTemplateSchemas.layout(forSchemaID:)), layout)
        }
    }

    func testBootKeepsTheExplicitSourceInsteadOfFirstBindingOnTheLayout() throws {
        let root = URL(fileURLWithPath: "/unused")
        let set = KeyboardResourceSet(
            id: "source", name: "来源", sharedDirectory: root, userDirectory: root,
            layoutEntries: [
                .init(layout: .qwerty26, schemaID: "songyan_quanpin"),
                .init(layout: .qwerty26, schemaID: "songyan_flypy"),
            ],
            schemas: [
                .init(id: "songyan_quanpin", name: "全拼", alphabet: "abc"),
                .init(id: "songyan_flypy", name: "双拼", alphabet: "abc"),
            ],
            selectedSchemaID: "songyan_flypy")
        let boot = try XCTUnwrap(set.bootSelection(candidates: [.qwerty26], restrictedToSource: set.selectedSchemaID))
        XCTAssertEqual(boot.layout, .qwerty26)
        XCTAssertEqual(boot.schemaID, "songyan_flypy")
        XCTAssertNil(set.bootSelection(candidates: [.qwerty26], restrictedToSource: "not_enabled"))
    }

    func testShuangpinSourceBindingOn26KeysKeepsItsEngineSchema() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("compiled".utf8).write(to: root.appendingPathComponent("my_double_pinyin.schema.yaml"))
        let binding = try JSONDecoder().decode(
            KeyboardResourceSet.LayoutEntry.self,
            from: Data(#"{"layout":"qwerty26","schemaID":"my_double_pinyin"}"#.utf8))
        let set = KeyboardResourceSet(
            id: "source", name: "自定义", sharedDirectory: root, userDirectory: root,
            layoutEntries: [binding], prebuiltDirectory: root,
            schemas: [.init(id: "my_double_pinyin", name: "双拼", alphabet: "abcdefghijklmnopqrstuvwxyz")],
            selectedSchemaID: "my_double_pinyin", preferredLayout: .qwerty26,
            publishedKeyboards: [.init(schemaID: "my_double_pinyin", layout: .qwerty26)])
        let ready = set.restricted(toPublished: [.init(schemaID: "my_double_pinyin", layout: .qwerty26)])
        XCTAssertEqual(ready.preferredLayout, .qwerty26)
        XCTAssertEqual(ready.availableLayouts, [.qwerty26])
        XCTAssertEqual(ready.schemaID(for: .qwerty26), "my_double_pinyin")
        XCTAssertEqual(ready.logicalSchemaID("my_double_pinyin", layout: .qwerty26), "my_double_pinyin")
        XCTAssertTrue(ready.keyboardChoices(for: "another_source").isEmpty)
        try FileManager.default.removeItem(at: root.appendingPathComponent("my_double_pinyin.schema.yaml"))
        XCTAssertTrue(
            set.restricted(toPublished: [.init(schemaID: "my_double_pinyin", layout: .qwerty26)]).availableLayouts
                .isEmpty)
    }
}
