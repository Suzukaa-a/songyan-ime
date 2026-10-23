"""The source's declared entry leads the production keyboard recommendation."""
import sys
import unittest

from swift_probe import ROOT, compile_swift, run, scratch_directory, section


@unittest.skipUnless(sys.platform == "darwin", "requires macOS Swift")
class KeyboardSourceRecommendationTests(unittest.TestCase):
    def test_declared_entry_first_without_reordering_other_sources(self):
        adapter = (ROOT / "Apps/HostApp/DictionaryImportCenterUserKeyboards.swift").read_text()
        method = section(adapter, "    func addableKeyboards()", "    func addKeyboard(")
        source = r'''
import Foundation
import KeyboardCore
struct Transaction {
    func addableKeyboards() async throws -> [PublishedKeyboard] {
        [.init(schemaID: "alpha", layout: .qwerty26), .init(schemaID: "alpha", layout: .phone9),
         .init(schemaID: "declared_entry", layout: .qwerty26), .init(schemaID: "declared_entry", layout: .merged14),
         .init(schemaID: "omega", layout: .qwerty26)]
    }
}
struct Adapter {
    var preferred: String?
    func currentContext() async throws -> (schemas: [KeyboardSchemaDescriptor], transaction: Transaction, preferredSchemaID: String?) {
        ([.init(id: "alpha", name: "甲"), .init(id: "declared_entry", name: "入口"), .init(id: "omega", name: "乙")], Transaction(), preferred)
    }
// METHOD
}
@main struct Probe {
    static func main() async throws {
        let chosen = try await Adapter(preferred: "declared_entry").addableKeyboards()
        precondition(chosen.map { $0.inputMethodID } == ["declared_entry", "declared_entry", "alpha", "alpha", "omega"])
        precondition(chosen.first?.layout == .qwerty26)
        precondition(chosen.first?.inputMethodName == "入口")
        let unknown = try await Adapter(preferred: "not_installed").addableKeyboards()
        let noPreference = try await Adapter(preferred: nil).addableKeyboards()
        precondition(unknown.map { $0.id } == noPreference.map { $0.id })
        precondition(noPreference.map { $0.inputMethodID } == ["alpha", "alpha", "declared_entry", "declared_entry", "omega"])
        print("source entry recommendation behavior passed")
    }
}
'''.replace("// METHOD", method)
        with scratch_directory("keyboard-source-recommendation") as directory:
            generated = directory / "RecommendationProbe.swift"
            generated.write_text(source)
            binary = compile_swift(directory, [generated], library=True, dependencies=("KeyboardCore",))
            print(run([str(binary)]), end="")


if __name__ == "__main__":
    unittest.main()
