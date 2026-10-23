import KeyboardCore
import XCTest
import Yams

@testable import PackageManager

/// The 18-key layout reuses the letter-group adapter: only the fold differs from 14-key.
final class EighteenKeyAdapterTests: XCTestCase {
    private func repoFile(_ path: String) throws -> Data {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try Data(contentsOf: root.appendingPathComponent(path))
    }

    private func fixture(_ name: String) throws -> CompactSchemaAdapter.SourceProjection {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: name, withExtension: "json",
                subdirectory: "Fixtures"))
        return try XCTUnwrap(CompactSchemaAdapter.SourceProjection.decode(json: Data(contentsOf: url)))
    }

    private func generate(_ schema: String, fold: CompactFold) throws -> String {
        let data = try CompactSchemaAdapter.generate(
            compiled: try repoFile("Resources/BuiltinPackages/Basic/\(schema).schema.yaml"),
            sourceID: schema, fold: fold, displayCapability: nil,
            sourceProjection: try fixture("\(schema).projection"))
        return String(decoding: data, as: UTF8.self)
    }

    private func root(_ yaml: String) throws -> [String: Any] {
        try XCTUnwrap(Yams.load(yaml: yaml) as? [String: Any])
    }

    func testLayoutSuppliesTheFold() {
        XCTAssertEqual(KeyboardLayoutKind.merged18.compactFold, .merged18)
        XCTAssertEqual(KeyboardLayoutKind.merged18.keyFold, .letterGroups)
        XCTAssertTrue(KeyboardLayoutKind.merged18.requiresSpellingDisplay)
        XCTAssertNil(KeyboardLayoutKind.qwerty26.compactFold)
        XCTAssertEqual(String(CompactFold.merged18.keysSent.sorted()), "abfhijlmpqrsuvwxyz")
        XCTAssertFalse(CompactFold.merged18.isPhoneDigits)
        XCTAssertTrue(CompactFold.phone9.isPhoneDigits)
        // Every key sends a letter that folds to itself.
        let map = CompactFold.merged18.map
        for key in CompactFold.merged18.keysSent { XCTAssertEqual(map[key], key) }
    }

    func testIdentifiersKeepTheirSuffixes() {
        XCTAssertTrue(CompactSchemaAdapter.identifier(sourceID: "s", fold: .merged14).hasSuffix("_14"))
        XCTAssertTrue(CompactSchemaAdapter.identifier(sourceID: "s", fold: .merged18).hasSuffix("_18"))
        XCTAssertTrue(CompactSchemaAdapter.identifier(sourceID: "s", fold: .phone9).hasSuffix("_9"))
        XCTAssertTrue(
            CompactSchemaAdapter.isGeneratedCompanionID(
                CompactSchemaAdapter.identifier(sourceID: "s", fold: .merged18)))
    }

    func testQuanpinSourceFoldsOntoEighteenKeys() throws {
        let root = try root(try generate("songyan_quanpin", fold: .merged18))
        let schema = try XCTUnwrap(root["schema"] as? [String: Any])
        XCTAssertEqual(
            schema["schema_id"] as? String,
            CompactSchemaAdapter.identifier(sourceID: "songyan_quanpin", fold: .merged18))
        let speller = try XCTUnwrap(root["speller"] as? [String: Any])
        let algebra = try XCTUnwrap(speller["algebra"] as? [String])
        XCTAssertEqual(
            Array(algebra.suffix(8)),
            [
                "derive/c/x/", "derive/d/s/", "derive/e/w/", "derive/g/f/", "derive/k/j/", "derive/n/b/", "derive/o/i/",
                "derive/t/r/",
            ])
        XCTAssertFalse(algebra.contains { $0.hasPrefix("xlit/") })
        let alphabet = try XCTUnwrap(speller["alphabet"] as? String)
        XCTAssertTrue(CompactFold.merged18.keysSent.isSubset(of: Set(alphabet)))
        // The lock alias layer stays out of reach of every key the layout sends.
        let rewrite = try XCTUnwrap(root["keyboard_rewrite"] as? [String: Any])
        XCTAssertEqual(rewrite["lock"] as? String, CompactSchemaAdapter.tokenAliasLockValue)
        let lockMap = try XCTUnwrap(rewrite["lock_map"] as? [String: String])
        XCTAssertFalse(lockMap.isEmpty)
        for alias in lockMap.values {
            XCTAssertFalse(alias.allSatisfy(CompactFold.merged18.keysSent.contains))
        }
        // nihao is typed as BN IO H A IO.
        XCTAssertEqual(String("nihao".map { CompactFold.merged18.map[$0] ?? $0 }), "bihai")
    }

    func testShuangpinSourceFoldsOntoEighteenKeys() throws {
        let root = try root(try generate("songyan_flypy", fold: .merged18))
        let speller = try XCTUnwrap(root["speller"] as? [String: Any])
        let algebra = try XCTUnwrap(speller["algebra"] as? [String])
        XCTAssertEqual(
            Array(algebra.suffix(8)),
            [
                "derive/c/x/", "derive/d/s/", "derive/e/w/", "derive/g/f/", "derive/k/j/", "derive/n/b/", "derive/o/i/",
                "derive/t/r/",
            ])
        XCTAssertNotNil((root["keyboard_rewrite"] as? [String: Any])?["lock_map"])
        let schema = try XCTUnwrap(root["schema"] as? [String: Any])
        XCTAssertTrue((schema["name"] as? String)?.hasSuffix("18键适配") == true)
    }

    /// Letter groups add one derive per folded letter, keeping exact letters spellable;
    /// the 9-key digit merge stays destructive.
    func testLetterGroupFoldsKeepExactLetters() throws {
        let root = try root(try generate("songyan_quanpin", fold: .merged14))
        let speller = try XCTUnwrap(root["speller"] as? [String: Any])
        let algebra = try XCTUnwrap(speller["algebra"] as? [String])
        XCTAssertEqual(
            Array(algebra.suffix(12)),
            [
                "derive/f/d/", "derive/h/g/", "derive/i/u/", "derive/k/j/", "derive/n/b/",
                "derive/p/o/", "derive/r/e/", "derive/s/a/", "derive/v/c/", "derive/w/q/",
                "derive/x/z/", "derive/y/t/",
            ])
        // Every exact letter is accepted, alongside the keys the layout sends.
        XCTAssertEqual(
            Set(try XCTUnwrap(speller["alphabet"] as? String)).intersection("abcdefghijklmnopqrstuvwxyz").count, 26)
        // Each derive target is a key the layout sends, so taps never reach a partial fold.
        for rule in algebra.suffix(12) {
            let target = rule.split(separator: "/")[2]
            XCTAssertTrue(CompactFold.merged14.keysSent.contains(Character(String(target))))
        }
    }
}
