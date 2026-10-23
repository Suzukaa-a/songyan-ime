import XCTest

@testable import KeyboardCore

/// Pure-logic regression for the cross-source published-keyboard cache.
///
/// User model: the shared publication record is "in use" for only one source at a time, but **each source's last successfully published full
/// keyboard roster must be kept by source identity**; when switching back to an old source the baseline is that source's own authoritative roster, not the current
/// source's roster or an empty set. A source is identified by a **structured source key** (kind (+ packageID)) and is never
/// inferred from the schema name (in Rime the same schema ID can belong to different packages).
///
/// All use **generic** fixtures, proving schema-agnosticism.
final class PublishedKeyboardRosterTests: XCTestCase {
    private let sourceAKey = "userScheme:source-a"
    private let sourceBKey = "userScheme:source-b"

    /// A's full four items (order preserved).
    private let sourceAFour = [
        PublishedKeyboard(schemaID: "alpha", layout: .qwerty26),
        PublishedKeyboard(schemaID: "alpha", layout: .merged14),
        PublishedKeyboard(schemaID: "beta", layout: .qwerty26),
        PublishedKeyboard(schemaID: "beta", layout: .phone9),
    ]
    private func k(_ schema: String, _ layout: KeyboardLayoutKind) -> PublishedKeyboard {
        PublishedKeyboard(schemaID: schema, layout: layout)
    }

    // MARK: - 1) Grouped by source key, never mixed across

    func testMergeKeysEachSourceAndNeverBleeds() {
        let sourceBOne = [k("gamma", .qwerty26)]
        let merged = PublishedKeyboardRoster.merged([
            PublishedKeyboardRoster(key: sourceAKey, keyboards: sourceAFour),
            PublishedKeyboardRoster(key: sourceBKey, keyboards: sourceBOne),
        ])
        XCTAssertTrue(merged.selfConsistent)
        XCTAssertEqual(merged.keyboards(forKey: sourceAKey), sourceAFour, "A's roster must be kept as is")
        XCTAssertEqual(merged.keyboards(forKey: sourceBKey), sourceBOne, "B's roster must be kept as is")
        XCTAssertEqual(merged.keyboards(forKey: "userScheme:absent"), [])
        XCTAssertEqual(merged.rosters.count, 2)
    }

    /// The same schema ID appears in two sources: never merged or crossed because the schema is the same.
    func testSameSchemaIdAcrossSourcesStaysSeparate() {
        let shared = k("shared", .qwerty26)
        let aOnly = k("only-a", .phone9)
        let merged = PublishedKeyboardRoster.merged([
            PublishedKeyboardRoster(key: sourceAKey, keyboards: [shared, aOnly]),
            PublishedKeyboardRoster(key: sourceBKey, keyboards: [shared]),
        ])
        XCTAssertEqual(merged.keyboards(forKey: sourceAKey), [shared, aOnly])
        XCTAssertEqual(merged.keyboards(forKey: sourceBKey), [shared])
    }

    // MARK: - 2) Counterexample: A four items -> B one item -> adding a selection on A still gives four (order preserved)

    func testAddingToAnOldSourceKeepsItsFullListInOrder() {
        let afterA = PublishedKeyboardRoster.merged([
            PublishedKeyboardRoster(key: sourceAKey, keyboards: sourceAFour)
        ])
        XCTAssertEqual(afterA.keyboards(forKey: sourceAKey), sourceAFour)

        let afterB = PublishedKeyboardRoster.merged([
            PublishedKeyboardRoster(key: sourceAKey, keyboards: afterA.keyboards(forKey: sourceAKey)),
            PublishedKeyboardRoster(key: sourceBKey, keyboards: [k("gamma", .qwerty26)]),
        ])
        XCTAssertEqual(afterB.keyboards(forKey: sourceAKey), sourceAFour, "publishing B must not drop A's roster")

        let reopeningA = PublishedKeyboard.adding(
            sourceAFour[1],
            to: afterB.keyboards(forKey: sourceAKey))
        XCTAssertEqual(reopeningA, sourceAFour, "an existing selection must not change or compact A's roster")

        let appended = PublishedKeyboard.adding(k("delta", .merged14), to: reopeningA)
        XCTAssertEqual(appended, sourceAFour + [k("delta", .merged14)])
    }

    /// The caller's roster wholly **replaces** this source (delete semantics): removed items must not come back, and other sources are untouched.
    func testExplicitListReplacesOnlyItsOwnSource() {
        let trimmedA = sourceAFour.filter { $0 != k("alpha", .merged14) }
        let merged = PublishedKeyboardRoster.merged([
            PublishedKeyboardRoster(key: sourceAKey, keyboards: trimmedA),
            PublishedKeyboardRoster(key: sourceBKey, keyboards: [k("gamma", .qwerty26)]),
        ])
        XCTAssertEqual(merged.keyboards(forKey: sourceAKey), trimmedA, "deletion must take effect")
        XCTAssertEqual(merged.keyboards(forKey: sourceBKey), [k("gamma", .qwerty26)], "deleting A must not affect B")
    }

    /// Deleting source B's cache = that key no longer appears in the merged result (re-import does not inherit old items).
    func testDroppingASourceKeyOmitsItsRoster() {
        let merged = PublishedKeyboardRoster.merged([
            PublishedKeyboardRoster(key: sourceAKey, keyboards: sourceAFour)
        ])
        XCTAssertEqual(
            merged.keyboards(forKey: sourceBKey), [],
            "a deleted source has no key => reads back empty, inheriting no old roster")
        XCTAssertEqual(merged.keyboards(forKey: sourceAKey), sourceAFour)
    }

    // MARK: - 3) Idempotence and de-duplication

    func testSameSourceMergeIsIdempotentAndDeduplicates() {
        let merged = PublishedKeyboardRoster.merged([
            PublishedKeyboardRoster(key: sourceAKey, keyboards: sourceAFour),
            PublishedKeyboardRoster(key: sourceAKey, keyboards: sourceAFour),
        ])
        XCTAssertEqual(merged.keyboards(forKey: sourceAKey), sourceAFour)
        XCTAssertEqual(merged.rosters.count, 1)
    }

    // MARK: - 4) Invalid keys fail closed, never guess the source

    func testInvalidKeyMakesMergeNonSelfConsistentAndIsSkipped() {
        let merged = PublishedKeyboardRoster.merged([
            PublishedKeyboardRoster(key: sourceAKey, keyboards: sourceAFour),
            PublishedKeyboardRoster(key: "", keyboards: [k("gamma", .qwerty26)]),
        ])
        XCTAssertFalse(merged.selfConsistent, "an empty key must fail closed")
        XCTAssertEqual(merged.keyboards(forKey: sourceAKey), sourceAFour)
        XCTAssertEqual(merged.rosters[""], nil)
    }

    // MARK: - 5) Structured source-key validation (Unicode accepted / path escape rejected)

    func testPackageIDAcceptsUnicodeButRejectsEscapes() {
        // A legal ID admitted by the install declaration (including Chinese/Unicode/common symbols) must be usable as a source key.
        for id in ["自然码", "用户-方案.1", "café", "拼音_双拼"] {
            XCTAssertTrue(PublishedKeyboardSourceKey.validPackageID(id), "a legal package identity was rejected: \(id)")
            XCTAssertTrue(PublishedKeyboardSourceKey.isValid("userScheme:" + id))
        }
        // Path escape / empty / control characters are all rejected.
        for bad in ["", ".", "..", "a/b", "a\\b", "a:b", "..\u{2F}x", "a..b", "a\nb", "\u{0}"] {
            XCTAssertFalse(
                PublishedKeyboardSourceKey.validPackageID(bad), "an illegal package identity was admitted: \(bad)")
        }
        XCTAssertFalse(PublishedKeyboardSourceKey.isValid(""))
        XCTAssertFalse(PublishedKeyboardSourceKey.isValid("userScheme:"))
        XCTAssertFalse(PublishedKeyboardSourceKey.isValid("bogus:pkg"))
        XCTAssertFalse(PublishedKeyboardSourceKey.isValid("rimeIce"))
        XCTAssertTrue(PublishedKeyboardSourceKey.isValid("userDictionary"))
    }

    func testCacheKeyMapsStructuredSources() {
        XCTAssertEqual(KeyboardPublicationSource.userDictionary.cacheKey, "userDictionary")
        XCTAssertEqual(
            KeyboardPublicationSource.userScheme(packageID: "自然码").cacheKey,
            "userScheme:自然码")
        // Invalid bridge identity -> nil (not recorded, not guessed).
        XCTAssertNil(KeyboardPublicationSource.userScheme(packageID: "../evil").cacheKey)
        XCTAssertNil(KeyboardPublicationSource.userScheme(packageID: "").cacheKey)
    }
}
