import XCTest
import ZIPFoundation

@testable import PackageManager

/// YAML alias-bomb guard and Finder ZIP metadata handling for imported schemes.
final class ImportSafetyTests: XCTestCase {
    private static let billionLaughs = """
        a: &a ["lol","lol","lol","lol","lol","lol","lol","lol","lol"]
        b: &b [*a,*a,*a,*a,*a,*a,*a,*a,*a]
        c: &c [*b,*b,*b,*b,*b,*b,*b,*b,*b]
        d: &d [*c,*c,*c,*c,*c,*c,*c,*c,*c]
        e: &e [*d,*d,*d,*d,*d,*d,*d,*d,*d]
        f: &f [*e,*e,*e,*e,*e,*e,*e,*e,*e]
        g: &g [*f,*f,*f,*f,*f,*f,*f,*f,*f]
        h: &h [*g,*g,*g,*g,*g,*g,*g,*g,*g]
        i: &i [*h,*h,*h,*h,*h,*h,*h,*h,*h]

        """

    private static let rimeStyleAnchors = """
        # Comment mentions *not_an_alias and &not_an_anchor.
        base: &base
          enable_completion: true
          enable_sentence: false
        speller:
          alphabet: "zyxwvutsrqponmlkjihgfedcba*"
          algebra:
            - xform/^(.*)$/$1/
            - "derive/^([a-z]+)*$/x/"
        translator:
          <<: *base
          dictionary: main
        melt_eng:
          <<: *base
          dictionary: melt_eng
        list: [*base, {a: 1}]

        """

    func testBillionLaughsRejectedQuickly() throws {
        let started = Date()
        XCTAssertThrowsError(try BoundedYAML.load(yaml: Self.billionLaughs)) { error in
            XCTAssertTrue(error is BoundedYAML.LimitExceeded, "\(error)")
        }
        XCTAssertThrowsError(try BoundedYAML.compose(yaml: Self.billionLaughs)) { error in
            XCTAssertTrue(error is BoundedYAML.LimitExceeded, "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testDependencyScanRejectsAliasBombWithFriendlyError() throws {
        let files: [String: Data] = [
            "main.schema.yaml": Data(("schema: {schema_id: main}\n" + Self.billionLaughs).utf8)
        ]
        let started = Date()
        XCTAssertThrowsError(try SchemeSourceCheck.missingDependencies(files)) { error in
            let message = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertTrue(message.contains("main.schema.yaml"), message)
            XCTAssertTrue(message.contains("别名展开"), message)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testAliasAsMappingKeyRejected() {
        XCTAssertThrowsError(try BoundedYAML.load(yaml: "a: &a [1, 2]\nb: {*a : 1}\n"))
        XCTAssertThrowsError(try BoundedYAML.load(yaml: "a: &a [1, 2]\n? *a\n: 1\n"))
    }

    func testOrdinaryAnchorsAndMergeKeysAccepted() throws {
        let root = try XCTUnwrap(try BoundedYAML.load(yaml: Self.rimeStyleAnchors) as? [String: Any])
        let translator = try XCTUnwrap(root["translator"] as? [String: Any])
        XCTAssertEqual(translator["enable_completion"] as? Bool, true)
        XCTAssertEqual(translator["dictionary"] as? String, "main")
        XCTAssertNotNil(try BoundedYAML.compose(yaml: Self.rimeStyleAnchors))
        // No alias token: unchanged fast path, identical to Yams.
        XCTAssertFalse(try BoundedYAML.requiresExpansionCheck("a: 1\nb: '*x'\nc: x*y\n# *z\n"))
        let files = ["main.schema.yaml": Data(("schema: {schema_id: main}\n" + Self.rimeStyleAnchors).utf8)]
        XCTAssertEqual(try SchemeSourceCheck.missingDependencies(files), ["main.dict.yaml", "melt_eng.dict.yaml"])
    }

    func testBlockScalarQuotesCannotHideAliases() throws {
        // Small enough that even a regression cannot run an unbounded bomb.
        let aliases = "a: &a [1, 2]\nb: &b [*a, *a]\nc: [*b, *b]\n"
        for scalar in ["|\n  '\n", ">-\n  \"\n", "|2+\n  '\n\n", ">2-\n  \" *literal\n"] {
            let yaml = "description: " + scalar + aliases
            XCTAssertTrue(try BoundedYAML.requiresExpansionCheck(yaml), scalar)
            let root = try XCTUnwrap(try BoundedYAML.load(yaml: yaml) as? [String: Any])
            XCTAssertEqual(root["c"] as? [[[Int]]], [[[1, 2], [1, 2]], [[1, 2], [1, 2]]])
            XCTAssertNotNil(try BoundedYAML.compose(yaml: yaml))
        }
    }

    func testScalarSyntaxAndRegexRemainLiteral() throws {
        let yaml = #"""
            block: |
              ' *fake ? [1]:
            folded: >-
              " *fake
            plain: regex ' *fake and " *fake
              continued *fake # trailing comment
            quoted: "escaped \" *fake and \\ *fake"
            single: 'escaped '' *fake'
            regex:
              - xform/^(.*)$/$1/
              - derive/^([a-z]+)*$/x/
              - xform/ :* /x/
              - xform/#*?/'/
            keys:
              a*b: one
              axb: two
              "*quoted": three
            """#
        XCTAssertFalse(try BoundedYAML.requiresExpansionCheck(yaml))
        let root = try XCTUnwrap(try BoundedYAML.load(yaml: yaml) as? [String: Any])
        XCTAssertEqual(root["block"] as? String, "' *fake ? [1]:\n")
        XCTAssertEqual(root["keys"] as? [String: String], ["a*b": "one", "axb": "two", "*quoted": "three"])
        let withAliases = yaml + "\nbase: &base [1]\ncopy: *base\n"
        XCTAssertTrue(try BoundedYAML.requiresExpansionCheck(withAliases))
        XCTAssertNotNil(try BoundedYAML.load(yaml: withAliases))
    }

    func testAliasSyntaxIsDetectedWithoutASCIINameAssumptions() throws {
        for yaml in [
            "base: &base [1]\nflow: {\"copy\":*base}\n",
            "base: &base [1]\nflow: [*base,*base]\n",
            "base: &base [1]\ncopy: *base # comment\n",
            "description: |\n  '\nbase: &base [1]\ncopy: *名字\n",
        ] {
            XCTAssertTrue(try BoundedYAML.requiresExpansionCheck(yaml), yaml)
        }
        // Pinned Yams rejects Unicode anchor names; preserve that parser error.
        XCTAssertThrowsError(try BoundedYAML.load(yaml: "base: &名字 [1]\ncopy: *名字\n"))
    }

    func testCollectionKeysAreRejectedBeforeOriginalComposition() throws {
        let base = "description: |\n  '\nbase: &base [1, 2]\n"
        for key in [
            "? *base\n: value\n",
            "mapping: {*base : value}\n",
            "? [*base, tail]\n: value\n",
            "mapping: {[head, *base]: value}\n",
            "? {nested: *base}\n: value\n",
            "? [head, {nested: [*base]}]\n: value\n",
        ] {
            // This entry point only composes the alias-free shadow. The original
            // collection key must never reach Yams' recursively hashing composer.
            XCTAssertThrowsError(try BoundedYAML.requiresExpansionCheck(base + key)) { error in
                XCTAssertEqual(
                    error as? BoundedYAML.LimitExceeded,
                    .init(reason: "不支持以别名或复杂结构作为键"))
            }
            XCTAssertThrowsError(try BoundedYAML.compose(yaml: base + key))
            XCTAssertThrowsError(try BoundedYAML.load(yaml: base + key))
        }
        XCTAssertNotNil(try BoundedYAML.load(yaml: "base: &base [1]\n? scalar\n: *base\n"))
    }

    func testAliasCountBoundaryAndLiteralStars() throws {
        let base = "base: &base 1\ncopy: ["
        let atLimit = base + Array(repeating: "*base", count: BoundedYAML.maximumAliases).joined(separator: ",") + "]\n"
        XCTAssertTrue(try BoundedYAML.requiresExpansionCheck(atLimit))
        let beyondLimit =
            base + Array(repeating: "*base", count: BoundedYAML.maximumAliases + 1).joined(separator: ",") + "]\n"
        XCTAssertThrowsError(try BoundedYAML.requiresExpansionCheck(beyondLimit)) { error in
            XCTAssertEqual(
                error as? BoundedYAML.LimitExceeded,
                .init(reason: "别名超过 \(BoundedYAML.maximumAliases) 个"))
        }
        let literal = "pattern: '" + String(repeating: "*", count: BoundedYAML.maximumAliases + 1) + "'\n"
        XCTAssertFalse(try BoundedYAML.requiresExpansionCheck(literal))
    }

    func testShadowKeepsTagsAndOriginalSyntaxValidation() throws {
        let tags = "plain: !regex*pattern x*y\nquoted: !<tag:example.org,2026:regex*> '.*'\n"
        XCTAssertFalse(try BoundedYAML.requiresExpansionCheck(tags))
        let root = try XCTUnwrap(try BoundedYAML.load(yaml: tags) as? [String: Any])
        XCTAssertEqual(root["plain"] as? String, "x*y")
        XCTAssertEqual(root["quoted"] as? String, ".*")
        XCTAssertThrowsError(try BoundedYAML.load(yaml: "same: '*a'\nsame: '*b'\n"))
        XCTAssertThrowsError(try BoundedYAML.load(yaml: "base: &a*b value\n"))
        let unicode = "说明: |\n  ' 😀\n根: &base [你好]\n副本: *base\n".replacingOccurrences(of: "\n", with: "\r\n")
        XCTAssertTrue(try BoundedYAML.requiresExpansionCheck(unicode))
        XCTAssertNotNil(try BoundedYAML.load(yaml: unicode))
    }

    func testShadowAllocationBudgetBeforeParsing() throws {
        let yaml = "pattern: '**'\n"
        // Each ASCII '*' becomes an eight-byte prefix, adding seven bytes.
        let exactSize = yaml.utf8.count + 14
        XCTAssertFalse(try BoundedYAML.requiresExpansionCheck(yaml, maximumShadowBytes: exactSize))
        for limit in [exactSize - 1, yaml.utf8.count - 1] {
            XCTAssertThrowsError(try BoundedYAML.requiresExpansionCheck(yaml, maximumShadowBytes: limit)) { error in
                XCTAssertEqual(
                    error as? BoundedYAML.LimitExceeded,
                    .init(reason: "别名安全预检超过 \(limit) 字节"))
            }
        }
        // A malformed scalar proves the byte budget wins before shadow parsing.
        XCTAssertThrowsError(try BoundedYAML.requiresExpansionCheck("x: '**", maximumShadowBytes: 8)) { error in
            XCTAssertTrue(error is BoundedYAML.LimitExceeded)
        }
    }

    func testSmallExpandedNodeBoundaryAfterBlockQuote() throws {
        let yaml = "description: |\n  '\na: &a [1, 2]\nb: &b [*a, *a]\nc: [*b, *b]\n"
        let root = try XCTUnwrap(try BoundedYAML.compose(yaml: yaml))
        // Root + description pair + a(4) + b(8) + c(16) = 31 nodes.
        XCTAssertNoThrow(try BoundedYAML.checkExpandedSize(root, maximumExpandedNodes: 31))
        XCTAssertThrowsError(try BoundedYAML.checkExpandedSize(root, maximumExpandedNodes: 30)) { error in
            XCTAssertEqual(
                error as? BoundedYAML.LimitExceeded,
                .init(reason: "展开后超过 30 个节点"))
        }
    }

    func testFinderMetadataClassification() {
        for path in [
            "__MACOSX", "__MACOSX/rime/._a.yaml", "._default.yaml", "lua/._x.lua", ".DS_Store", "lua/.DS_Store",
        ] {
            XCTAssertTrue(SchemeSourceCheck.isFinderMetadata(path), path)
        }
        for path in ["default.yaml", "lua/x.lua", "a__MACOSX/x", "lua/_x.lua", ".gitkeep"] {
            XCTAssertFalse(SchemeSourceCheck.isFinderMetadata(path), path)
        }
    }

    func testFinderZipWithMacOSXSiblingUnwrapsSingleRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("finder-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let zip = root.appendingPathComponent("rime-example.zip")
        let archive = try Archive(url: zip, accessMode: .create)
        let files: [String: Data] = [
            "rime-example/default.yaml": Data("schema_list:\n  - schema: main\n".utf8),
            "rime-example/main.schema.yaml": Data(
                "schema: {schema_id: main, name: Main}\ntranslator: {dictionary: main}\n".utf8),
            "rime-example/main.dict.yaml": Data("---\nname: main\nversion: '1'\n...\n你\tni\t100\n".utf8),
            "rime-example/.DS_Store": Data([0, 0, 0, 1]),
            "rime-example/._main.schema.yaml": Data([0, 5, 22, 7, 0xFF]),
            "__MACOSX/rime-example/._main.schema.yaml": Data([0, 5, 22, 7, 0xFF]),
            "__MACOSX/._rime-example": Data([0, 5, 22, 7]),
        ]
        for (path, bytes) in files.sorted(by: { $0.key < $1.key }) {
            try archive.addEntry(
                with: path, type: .file, uncompressedSize: Int64(bytes.count),
                provider: { position, count in
                    bytes.subdata(in: Int(position)..<(Int(position) + count))
                })
        }
        let prepared = try RecipePackageManager(rootURL: root.appendingPathComponent("store")).prepareSchemeArchive(zip)
        XCTAssertTrue(prepared.schemaIDs.contains("main"))
        XCTAssertEqual(Set(prepared.sourceFiles.keys), ["default.yaml", "main.schema.yaml", "main.dict.yaml"])
    }
}
