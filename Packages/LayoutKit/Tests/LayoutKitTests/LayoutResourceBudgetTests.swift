import Darwin
import Foundation
import XCTest

@testable import LayoutKit

final class LayoutResourceBudgetTests: XCTestCase {
    private let key = LayoutKey(label: "键", action: .init(.literal, value: "值"))

    private func layout(
        rows: [LayoutRow]? = nil, areas: [LayoutAuxiliaryArea]? = nil,
        note: String? = nil, id: String = "custom"
    ) -> LayoutDefinition {
        LayoutDefinition(
            id: id, name: "自定义", input: .init(builtinLayout: .qwerty26),
            rows: rows ?? [.init(keys: [key])], auxiliaryAreas: areas, note: note)
    }

    private func withStore(_ body: (LayoutStore, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(LayoutStore(directoryURL: root.appendingPathComponent("catalog")), root)
    }

    func testOversizedButValidJSONRejectedInMemoryAndFromFile() throws {
        var data = try layout().encoded()
        data.append(Data(repeating: 0x20, count: LayoutResourceBudget.definitionBytes))
        XCTAssertNoThrow(try JSONDecoder().decode(LayoutDefinition.self, from: data))
        XCTAssertThrowsError(try LayoutDefinition.decode(data))
        try withStore { store, root in
            let old = try LayoutRegistry()
            try store.save(old)
            let before = try Data(contentsOf: store.catalogURL)
            let source = root.appendingPathComponent("large.json")
            try data.write(to: source)
            XCTAssertThrowsError(try LayoutDefinition.read(from: source))
            XCTAssertThrowsError(try store.importLayout(from: source))
            XCTAssertEqual(try Data(contentsOf: store.catalogURL), before)
            XCTAssertEqual(try store.load(), old)
        }
    }

    func testModelBudgetsRejectStructurallyValidJSON() throws {
        let option = LayoutOption(label: "选", action: .init(.literal, value: "值"))
        let manyAlternates = LayoutKey(
            label: "键", action: key.action,
            longPress: Array(repeating: option, count: 17))
        let longLabel = LayoutKey(label: String(repeating: "界", count: 86), action: key.action)
        let longValue = LayoutKey(label: "键", action: .init(.literal, value: String(repeating: "a", count: 4097)))
        let textHeavy = LayoutKey(label: "键", action: .init(.literal, value: String(repeating: "a", count: 4096)))
        let fullAlternates = LayoutKey(label: "键", action: key.action, longPress: Array(repeating: option, count: 16))
        let invalid = [
            layout(rows: Array(repeating: .init(keys: [key]), count: 17)),
            layout(rows: [.init(keys: Array(repeating: key, count: 33))]),
            layout(rows: Array(repeating: .init(keys: Array(repeating: key, count: 32)), count: 9)),
            layout(areas: Array(repeating: .init(position: .leading, role: .punctuation), count: 5)),
            layout(rows: [.init(keys: [manyAlternates])]),
            layout(rows: [.init(keys: [longLabel])]),
            layout(rows: [.init(keys: [longValue])]),
            layout(rows: [.init(keys: Array(repeating: textHeavy, count: 16))]),
            layout(rows: Array(repeating: .init(keys: Array(repeating: fullAlternates, count: 32)), count: 3)),
            layout(note: String(repeating: "n", count: 8193)),
            layout(id: String(repeating: "i", count: 257)),
        ]
        for value in invalid {
            // Bypass the public encoder to prove that legal JSON can still exceed a model budget.
            let data = try JSONEncoder().encode(value)
            XCTAssertLessThan(data.count, LayoutResourceBudget.definitionBytes)
            XCTAssertNoThrow(try JSONDecoder().decode(LayoutDefinition.self, from: data))
            XCTAssertThrowsError(try LayoutDefinition.decode(data))
            XCTAssertThrowsError(try value.encoded())
        }
    }

    func testCatalogBudgetsAndFailedMutationsPreservePreviousValues() throws {
        let full = try LayoutRegistry(layouts: (0..<64).map { layout(id: "l\($0)") })
        var mutable = full
        XCTAssertThrowsError(try mutable.install(layout().encoded()))
        XCTAssertEqual(mutable, full)
        let tooMany = (0..<65).map { layout(id: "l\($0)") }
        let heavy = (0..<17).map {
            layout(rows: Array(repeating: .init(keys: Array(repeating: key, count: 32)), count: 8), id: "h\($0)")
        }
        try withStore { store, root in
            try store.save(full)
            let before = try Data(contentsOf: store.catalogURL)
            for values in [tooMany, heavy] {
                let data = try JSONSerialization.data(withJSONObject: [
                    "layouts": values.map { try! JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) },
                    "enabledIDs": [values[0].id],
                ])
                let invalid = try JSONDecoder().decode(LayoutRegistry.self, from: data)
                XCTAssertThrowsError(try store.save(invalid))
                XCTAssertEqual(try Data(contentsOf: store.catalogURL), before)
                try data.write(to: store.catalogURL)
                XCTAssertThrowsError(try store.load())
                XCTAssertEqual(try Data(contentsOf: store.catalogURL), data)
                try before.write(to: store.catalogURL)
            }
            var large = before
            large.append(Data(repeating: 0x20, count: LayoutResourceBudget.catalogBytes))
            try large.write(to: store.catalogURL)
            XCTAssertNoThrow(try JSONDecoder().decode(LayoutRegistry.self, from: large))
            XCTAssertThrowsError(try store.load())
            XCTAssertEqual(try Data(contentsOf: store.catalogURL), large)
        }
    }

    func testEncodedCatalogByteBudgetPreservesExistingFile() throws {
        // Control characters expand to six JSON bytes each. The in-memory model
        // remains within every complexity budget while pretty JSON exceeds 8 MiB.
        let text = String(repeating: "\u{0001}", count: 30)
        let option = LayoutOption(label: text, action: .init(.literal, value: text))
        let denseKey = LayoutKey(
            label: "k", action: .init(.literal, value: "v"),
            longPress: Array(repeating: option, count: 16))
        let values = (0..<64).map {
            layout(rows: [.init(keys: Array(repeating: denseKey, count: 16))], id: "dense\($0)")
        }
        let registry = try LayoutRegistry(layouts: values)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        XCTAssertGreaterThan(try encoder.encode(registry).count, LayoutResourceBudget.catalogBytes)
        try withStore { store, _ in
            try store.save(LayoutRegistry())
            let before = try Data(contentsOf: store.catalogURL)
            XCTAssertThrowsError(try store.save(registry))
            XCTAssertEqual(try Data(contentsOf: store.catalogURL), before)
        }
    }

    func testRegularFilesOnlyAndExistingLayoutsRemainReadable() throws {
        try withStore { store, root in
            let source = root.appendingPathComponent("source.json")
            try BuiltinLayouts.qwerty26.encoded().write(to: source)
            XCTAssertEqual(try LayoutDefinition.read(from: source), BuiltinLayouts.qwerty26)
            XCTAssertThrowsError(try LayoutDefinition.read(from: root))
            let fifo = root.appendingPathComponent("fifo")
            XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
            XCTAssertThrowsError(try LayoutDefinition.read(from: fifo))
            XCTAssertThrowsError(try LayoutDefinition.read(from: URL(string: "https://example.com/layout.json")!))
            try store.save(LayoutRegistry())
            XCTAssertEqual(try store.load(), try LayoutRegistry())
        }
    }
}
