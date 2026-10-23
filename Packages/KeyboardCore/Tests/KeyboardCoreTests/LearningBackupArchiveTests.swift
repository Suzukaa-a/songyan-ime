import XCTest

@testable import KeyboardCore

/// Regression tests for `LearningBackupArchive`: roundtrip, integrity, identity and every bound.
///
/// Coverage (each item maps to a contract that "invalid data must never pass"):
///  * roundtrip / byte determinism / whole-second ISO8601;
///  * a tampered digest, tampered content, and digest format (uppercase/length) are all rejected;
///  * future formats (version / producer) are rejected;
///  * empty collection, count limit, duplicate names, path traversal, control characters, leading dot, illegal Unicode boundaries;
///  * boundaries of 4 MiB per item, 8 MiB total and 12 MiB input, with enforcement on the decode path;
///  * strict matching of the same source + same resource revision;
///  * user-facing error text does not leak dictionary names or entry content.
final class LearningBackupArchiveTests: XCTestCase {

    /// 2026-01-01T00:00:00Z (whole second, to avoid ISO8601 fractional-second ambiguity).
    private let fixedDate = Date(timeIntervalSince1970: 1_767_225_600)
    private let iso8601Fixed = "2026-01-01T00:00:00Z"

    // MARK: - Fixtures

    private func snapshot(_ name: String, _ text: String) throws
        -> LearningBackupArchive.DictionarySnapshot
    {
        try LearningBackupArchive.DictionarySnapshot(name: name, data: Data(text.utf8))
    }

    private func makeArchive(
        dictionaries: [LearningBackupArchive.DictionarySnapshot],
        sourceID: String = "rime-ice",
        resourceRevision: String = "rev-2026-01-01",
        sourceName: String = "雾凇拼音",
        engineVersion: String = "1.9.0",
        createdAt: Date? = nil
    ) throws -> LearningBackupArchive {
        try LearningBackupArchive(
            sourceID: sourceID,
            resourceRevision: resourceRevision,
            sourceName: sourceName,
            engineVersion: engineVersion,
            createdAt: createdAt ?? fixedDate,
            dictionaries: dictionaries)
    }

    private func assertThrows<T>(
        _ expected: LearningBackupArchiveError,
        file: StaticString = #filePath, line: UInt = #line,
        _ expression: @autoclosure () throws -> T
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            XCTAssertEqual(
                error as? LearningBackupArchiveError, expected,
                "actual error: \(error)", file: file, line: line)
        }
    }

    private func jsonObject(of archive: LearningBackupArchive) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try archive.encoded()) as? [String: Any])
    }

    private func reserialize(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func rawSnapshot(name: Any = "words", sha256: Any, data: Any) -> [String: Any] {
        ["name": name, "sha256": sha256, "data": data]
    }

    private func rawArchive(
        version: Any = 1,
        producer: Any = "keyboard-extension",
        sourceID: Any = "rime-ice",
        resourceRevision: Any = "rev-1",
        sourceName: Any = "雾凇拼音",
        engineVersion: Any = "1.9.0",
        createdAt: Any = "2026-01-01T00:00:00Z",
        dictionaries: Any
    ) throws -> Data {
        try reserialize([
            "version": version,
            "producer": producer,
            "sourceID": sourceID,
            "resourceRevision": resourceRevision,
            "sourceName": sourceName,
            "engineVersion": engineVersion,
            "createdAt": createdAt,
            "dictionaries": dictionaries,
        ])
    }

    // MARK: - Roundtrip and determinism

    func testRoundtripPreservesArchiveExactly() throws {
        let archive = try makeArchive(dictionaries: [
            try snapshot("words", "词条一\n词条二"),
            try snapshot("emoji-🀄️", "🀄️🀄️"),
        ])
        let decoded = try LearningBackupArchive.decode(try archive.encoded())
        XCTAssertEqual(decoded, archive)
        XCTAssertEqual(decoded.dictionaries.count, 2)
        XCTAssertEqual(decoded.sourceID, "rime-ice")
        XCTAssertEqual(decoded.resourceRevision, "rev-2026-01-01")
    }

    func testEncodedBytesAreDeterministicAndSortedWithISO8601Date() throws {
        // Precondition: the fixture timestamp really is a whole second (otherwise the literal assertion below would mislead).
        XCTAssertEqual(ISO8601DateFormatter().string(from: fixedDate), iso8601Fixed)

        let archive = try makeArchive(dictionaries: [try snapshot("words", "a")])
        let first = try archive.encoded()
        let second = try archive.encoded()
        XCTAssertEqual(first, second, "the same archive encoded twice must be byte-identical (sortedKeys)")

        let text = try XCTUnwrap(String(data: first, encoding: .utf8))
        XCTAssertTrue(
            text.contains("\"createdAt\":\"\(iso8601Fixed)\""),
            "the date must be whole-second ISO8601: \(text)")
        // sortedKeys: keys appear in lexicographic order.
        var cursor = text.startIndex
        for key in [
            "\"createdAt\"", "\"dictionaries\"", "\"engineVersion\"", "\"producer\"",
            "\"resourceRevision\"", "\"sourceID\"", "\"sourceName\"", "\"version\"",
        ] {
            guard let range = text.range(of: key, range: cursor..<text.endIndex) else {
                XCTFail("key \(key) does not appear in lexicographic order: \(text)")
                return
            }
            cursor = range.upperBound
        }
    }

    func testSubSecondTimestampIsNormalizedAndStillRoundtrips() throws {
        let precise = Date(timeIntervalSince1970: 1_767_225_600.75)
        let archive = try makeArchive(dictionaries: [try snapshot("words", "a")], createdAt: precise)
        XCTAssertEqual(archive.createdAt, fixedDate, "the timestamp is normalized to a whole second")
        XCTAssertEqual(try LearningBackupArchive.decode(try archive.encoded()).createdAt, fixedDate)
    }

    func testFactoryComputesLowercaseSHA256OfRealData() throws {
        let payload = Data("词条-data".utf8)
        let snapshot = try LearningBackupArchive.DictionarySnapshot(name: "words", data: payload)
        XCTAssertEqual(snapshot.sha256.count, LearningBackupArchive.digestHexLength)
        XCTAssertEqual(snapshot.sha256, try LearningBackupArchive.sha256Hex(payload))
        let allowed = CharacterSet(charactersIn: "0123456789abcdef")
        XCTAssertTrue(
            snapshot.sha256.unicodeScalars.allSatisfy { allowed.contains($0) },
            "the digest must be lowercase hex: \(snapshot.sha256)")
        XCTAssertEqual(snapshot.data, payload)
    }

    func testDigestMatchesStandardSHA256TestVector() throws {
        // A known vector independent of this implementation (FIPS 180-2 standard example), ensuring the digest is really SHA256 and not a self-consistent weak hash.
        XCTAssertEqual(
            try LearningBackupArchive.sha256Hex(Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(
            try LearningBackupArchive.sha256Hex(Data()),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testWireFormatUsesBase64DataAndRejectsInvalidBase64() throws {
        let archive = try makeArchive(dictionaries: [try snapshot("words", "hello")])
        var object = try jsonObject(of: archive)
        var dictionaries = try XCTUnwrap(object["dictionaries"] as? [[String: Any]])
        XCTAssertEqual(dictionaries[0]["data"] as? String, Data("hello".utf8).base64EncodedString())

        dictionaries[0]["data"] = "not base64 %%"
        object["dictionaries"] = dictionaries
        assertThrows(.malformedArchive, try LearningBackupArchive.decode(try reserialize(object)))
    }

    // MARK: - Decode memory bounds: count and per-item incremental validation

    /// Item 33 is **structurally malicious and incomplete** data (wrong type, invalid base64).
    /// Decoding must reject by count **before parsing it**; if the implementation decoded everything first and validated afterwards,
    /// it would hit malformedArchive / malformedDigest here instead of tooManyDictionaries.
    func testDecodeRejects33rdDictionaryWithoutParsingIt() throws {
        let payload = Data("x".utf8)
        let digest = try LearningBackupArchive.sha256Hex(payload)
        var items: [[String: Any]] = (0..<32).map { index in
            rawSnapshot(
                name: "dict-\(index)", sha256: digest,
                data: payload.base64EncodedString())
        }
        items.append(["name": "poison", "sha256": 12_345, "data": "%%%not-base64%%%"])

        let data = try rawArchive(dictionaries: items)
        XCTAssertEqual(items.count, 33)
        assertThrows(.tooManyDictionaries(count: 33), try LearningBackupArchive.decode(data))
    }

    /// 200 **individually fully valid** small items (total bytes far below the 12 MiB input limit):
    /// must be rejected immediately by count, not after instantiating all 200 objects and letting validate() find out.
    func testDecodeRejectsOverLongArrayWithoutDecodingEveryItem() throws {
        let payload = Data("y".utf8)
        let digest = try LearningBackupArchive.sha256Hex(payload)
        let items: [[String: Any]] = (0..<200).map { index in
            rawSnapshot(
                name: "d-\(index)", sha256: digest,
                data: payload.base64EncodedString())
        }
        let data = try rawArchive(dictionaries: items)
        XCTAssertLessThan(data.count, LearningBackupArchive.maximumEncodedBytes)

        XCTAssertThrowsError(try LearningBackupArchive.decode(data)) { error in
            guard case .tooManyDictionaries(let count) = error as? LearningBackupArchiveError else {
                return XCTFail("expected tooManyDictionaries, actual: \(error)")
            }
            XCTAssertEqual(count, 200, "the container's known length should be reported without parsing elements")
        }
    }

    /// Per-item incremental validation: when an invalid digest appears at index 4, decoding must **stop at index 4**.
    /// The evidence is that the trailing items are all deliberately invalid too (wrong type / invalid base64):
    /// if the implementation decoded the whole array first and validated afterwards, it would hit their errors first.
    func testMalformedDigestAtLaterIndexStopsBeforeDecodingTrailingItems() throws {
        let payload = Data("z".utf8)
        let digest = try LearningBackupArchive.sha256Hex(payload)
        var items: [[String: Any]] = (0..<4).map { index in
            rawSnapshot(
                name: "ok-\(index)", sha256: digest,
                data: payload.base64EncodedString())
        }
        items.append(
            rawSnapshot(
                name: "bad", sha256: "zzzz",
                data: payload.base64EncodedString()))
        items.append(["name": "later", "sha256": 999, "data": "%%%"])
        items.append(["name": "later2", "sha256": 999, "data": "%%%"])

        assertThrows(
            .malformedDigest(dictionaryIndex: 4),
            try LearningBackupArchive.decode(try rawArchive(dictionaries: items)))
    }

    /// An over-limit item is rejected by **size** first (before the digest format check), avoiding follow-up work on over-limit data.
    func testOversizedItemIsRejectedBySizeBeforeDigestFormatCheck() throws {
        let oversize = Data(
            repeating: 0x41,
            count: LearningBackupArchive.maximumDictionaryBytes + 1)
        let data = try rawArchive(dictionaries: [
            rawSnapshot(sha256: "NOT-A-HEX-DIGEST", data: oversize.base64EncodedString())
        ])
        // After base64 inflation it is about 5.4 MiB, still within the 12 MiB input limit; only the per-item size check can stop it.
        XCTAssertLessThan(data.count, LearningBackupArchive.maximumEncodedBytes)
        assertThrows(
            .dictionaryTooLarge(dictionaryIndex: 0, bytes: oversize.count),
            try LearningBackupArchive.decode(data))
    }

    /// The cumulative limit is discovered **incrementally** at index 2 (the first two items are valid, cumulative 5.6 MiB <= 8 MiB).
    func testCumulativeLimitIsDetectedIncrementallyAtTheOffendingIndex() throws {
        let chunk = Data(repeating: 0x44, count: 2_800_000)
        let digest = try LearningBackupArchive.sha256Hex(chunk)
        let base64 = chunk.base64EncodedString()
        let items: [[String: Any]] = [
            rawSnapshot(name: "one", sha256: digest, data: base64),
            rawSnapshot(name: "two", sha256: digest, data: base64),
            rawSnapshot(name: "three", sha256: digest, data: base64),
        ]
        let data = try rawArchive(dictionaries: items)
        XCTAssertLessThan(data.count, LearningBackupArchive.maximumEncodedBytes)
        assertThrows(
            .dictionariesTooLarge(bytes: 2_800_000 * 3),
            try LearningBackupArchive.decode(data))
    }

    // MARK: - Integrity: tampered digest / tampered content

    func testTamperedDigestIsRejected() throws {
        let archive = try makeArchive(dictionaries: [try snapshot("words", "a")])
        var object = try jsonObject(of: archive)
        var dictionaries = try XCTUnwrap(object["dictionaries"] as? [[String: Any]])
        dictionaries[0]["sha256"] = String(repeating: "0", count: 64)
        object["dictionaries"] = dictionaries
        assertThrows(
            .digestMismatch(dictionaryIndex: 0),
            try LearningBackupArchive.decode(try reserialize(object)))
    }

    func testUppercaseOrWrongLengthDigestIsRejected() throws {
        let archive = try makeArchive(dictionaries: [try snapshot("words", "a")])

        var uppercase = try jsonObject(of: archive)
        var dictsA = try XCTUnwrap(uppercase["dictionaries"] as? [[String: Any]])
        let real = try XCTUnwrap(dictsA[0]["sha256"] as? String)
        dictsA[0]["sha256"] = real.uppercased()
        uppercase["dictionaries"] = dictsA
        assertThrows(
            .malformedDigest(dictionaryIndex: 0),
            try LearningBackupArchive.decode(try reserialize(uppercase)))

        var short = try jsonObject(of: archive)
        var dictsB = try XCTUnwrap(short["dictionaries"] as? [[String: Any]])
        dictsB[0]["sha256"] = String(real.prefix(63))
        short["dictionaries"] = dictsB
        assertThrows(
            .malformedDigest(dictionaryIndex: 0),
            try LearningBackupArchive.decode(try reserialize(short)))
    }

    func testTamperedDictionaryContentIsRejected() throws {
        let archive = try makeArchive(dictionaries: [try snapshot("words", "original")])
        var object = try jsonObject(of: archive)
        var dictionaries = try XCTUnwrap(object["dictionaries"] as? [[String: Any]])
        // Change only the content and keep the original digest.
        dictionaries[0]["data"] = Data("tampered".utf8).base64EncodedString()
        object["dictionaries"] = dictionaries
        assertThrows(
            .digestMismatch(dictionaryIndex: 0),
            try LearningBackupArchive.decode(try reserialize(object)))
    }

    func testSecondDictionaryTamperingIsReportedWithItsIndex() throws {
        let archive = try makeArchive(dictionaries: [
            try snapshot("first", "a"),
            try snapshot("second", "b"),
        ])
        var object = try jsonObject(of: archive)
        var dictionaries = try XCTUnwrap(object["dictionaries"] as? [[String: Any]])
        dictionaries[1]["data"] = Data("changed".utf8).base64EncodedString()
        object["dictionaries"] = dictionaries
        assertThrows(
            .digestMismatch(dictionaryIndex: 1),
            try LearningBackupArchive.decode(try reserialize(object)))
    }

    // MARK: - Format version / producer

    func testFutureFormatVersionIsRejected() throws {
        let archive = try makeArchive(dictionaries: [try snapshot("words", "a")])
        var object = try jsonObject(of: archive)
        object["version"] = 2
        assertThrows(
            .unsupportedVersion(2),
            try LearningBackupArchive.decode(try reserialize(object)))
        // The construction path also rejects (it cannot be bypassed by "constructing it yourself").
        assertThrows(
            .unsupportedVersion(2),
            try LearningBackupArchive(
                version: 2,
                sourceID: "rime-ice",
                resourceRevision: "rev-1",
                sourceName: "雾凇拼音",
                engineVersion: "1.9.0",
                createdAt: fixedDate,
                dictionaries: [try snapshot("words", "a")]))
    }

    func testUnexpectedProducerIsRejected() throws {
        let archive = try makeArchive(dictionaries: [try snapshot("words", "a")])
        var object = try jsonObject(of: archive)
        object["producer"] = "host-app"
        assertThrows(
            .unexpectedProducer,
            try LearningBackupArchive.decode(try reserialize(object)))
    }

    func testMissingFieldIsRejected() throws {
        let archive = try makeArchive(dictionaries: [try snapshot("words", "a")])
        for key in [
            "version", "producer", "sourceID", "resourceRevision", "sourceName",
            "engineVersion", "createdAt", "dictionaries",
        ] {
            var object = try jsonObject(of: archive)
            object.removeValue(forKey: key)
            assertThrows(
                .missingField(key),
                try LearningBackupArchive.decode(try reserialize(object)))
        }
    }

    func testNonJSONAndWrongTypesAreRejected() throws {
        assertThrows(.malformedArchive, try LearningBackupArchive.decode(Data("not json".utf8)))
        assertThrows(
            .malformedArchive,
            try LearningBackupArchive.decode(
                try rawArchive(
                    version: "1",
                    dictionaries: [])))
    }

    // MARK: - Collection bounds

    func testEmptyDictionarySetIsRejected() throws {
        assertThrows(.emptyDictionaries, try makeArchive(dictionaries: []))
        assertThrows(
            .emptyDictionaries,
            try LearningBackupArchive.decode(try rawArchive(dictionaries: [])))
    }

    func testDictionaryCountBoundary() throws {
        let allowed = try (0..<LearningBackupArchive.maximumDictionaryCount).map {
            try snapshot("dict-\($0)", "d\($0)")
        }
        let archive = try makeArchive(dictionaries: allowed)
        XCTAssertEqual(try LearningBackupArchive.decode(try archive.encoded()).dictionaries.count, 32)

        let tooMany = try (0...LearningBackupArchive.maximumDictionaryCount).map {
            try snapshot("dict-\($0)", "d\($0)")
        }
        assertThrows(.tooManyDictionaries(count: 33), try makeArchive(dictionaries: tooMany))
    }

    func testDuplicateDictionaryNameIsRejected() throws {
        assertThrows(
            .duplicateDictionaryName,
            try makeArchive(dictionaries: [
                try snapshot("words", "a"),
                try snapshot("words", "b"),
            ]))
        // Names differing only in case overwrite each other on (default case-insensitive) file systems: likewise rejected.
        assertThrows(
            .duplicateDictionaryName,
            try makeArchive(dictionaries: [
                try snapshot("Words", "a"),
                try snapshot("words", "b"),
            ]))
        // Identical after Unicode normalization: likewise rejected.
        assertThrows(
            .duplicateDictionaryName,
            try makeArchive(dictionaries: [
                try snapshot("caf\u{00E9}", "a"),
                try snapshot("cafe\u{0301}", "b"),
            ]))
    }

    // MARK: - Dictionary name: path traversal / control characters / Unicode

    func testPathTraversalAndControlCharactersInNameAreRejected() throws {
        let cases: [(String, LearningBackupArchiveError.NameRejection)] = [
            ("", .empty),
            (String(repeating: "a", count: 257), .tooLong(bytes: 257)),
            ("../escape", .pathSeparator),
            ("dir/name", .pathSeparator),
            ("dir\\name", .pathSeparator),
            ("a\u{0}b", .controlCharacter),
            ("a\nb", .controlCharacter),
            ("a\rb", .controlCharacter),
            ("a\tb", .controlCharacter),
            (".", .relativePathComponent),
            ("..", .relativePathComponent),
            (".hidden", .leadingDot),
            ("..hidden", .leadingDot),
            ("/absolute", .pathSeparator),
        ]
        for (name, rejection) in cases {
            assertThrows(
                .invalidDictionaryName(rejection),
                try LearningBackupArchive.DictionarySnapshot(name: name, data: Data("x".utf8)))
            assertThrows(
                .invalidDictionaryName(rejection),
                try makeArchive(dictionaries: [try snapshot(name, "x")]))
        }
    }

    func testDecodePathRejectsPathTraversalAndControlNames() throws {
        let payload = Data("x".utf8)
        let digest = try LearningBackupArchive.sha256Hex(payload)
        let base64 = payload.base64EncodedString()

        for name in ["../escape", "dir/name", ".hidden", "a\nb"] {
            let data = try rawArchive(dictionaries: [rawSnapshot(name: name, sha256: digest, data: base64)])
            XCTAssertThrowsError(try LearningBackupArchive.decode(data)) { error in
                guard case .invalidDictionaryName = error as? LearningBackupArchiveError else {
                    return XCTFail("expected invalidDictionaryName, actual: \(error)")
                }
            }
        }
    }

    func testLegalUnicodeNamesAreAccepted() throws {
        let names = [
            "词库", "emoji-🀄️", "user.dict.yaml", "a b", "É-Ünïcode", "jp-かな",
            String(repeating: "a", count: 256),
        ]
        for name in names {
            let archive = try makeArchive(dictionaries: [try snapshot(name, "payload")])
            XCTAssertEqual(try LearningBackupArchive.decode(try archive.encoded()).dictionaries[0].name, name)
        }
    }

    // MARK: - Identity metadata bounds

    func testMetadataEmptinessAndBounds() throws {
        let dictionary = try snapshot("words", "a")

        assertThrows(
            .emptyMetadata(field: .sourceID),
            try makeArchive(dictionaries: [dictionary], sourceID: ""))
        assertThrows(
            .emptyMetadata(field: .resourceRevision),
            try makeArchive(dictionaries: [dictionary], resourceRevision: ""))
        assertThrows(
            .emptyMetadata(field: .sourceName),
            try makeArchive(dictionaries: [dictionary], sourceName: ""))
        assertThrows(
            .emptyMetadata(field: .engineVersion),
            try makeArchive(dictionaries: [dictionary], engineVersion: ""))

        assertThrows(
            .metadataTooLong(field: .sourceID, bytes: 513),
            try makeArchive(
                dictionaries: [dictionary],
                sourceID: String(repeating: "s", count: 513)))
        assertThrows(
            .metadataTooLong(field: .resourceRevision, bytes: 257),
            try makeArchive(
                dictionaries: [dictionary],
                resourceRevision: String(repeating: "r", count: 257)))
        assertThrows(
            .metadataTooLong(field: .sourceName, bytes: 257),
            try makeArchive(
                dictionaries: [dictionary],
                sourceName: String(repeating: "n", count: 257)))
        assertThrows(
            .metadataTooLong(field: .engineVersion, bytes: 129),
            try makeArchive(
                dictionaries: [dictionary],
                engineVersion: String(repeating: "v", count: 129)))

        // Exactly at the limit: accepted.
        let atLimit = try makeArchive(
            dictionaries: [dictionary],
            sourceID: String(repeating: "s", count: 512),
            resourceRevision: String(repeating: "r", count: 256),
            sourceName: String(repeating: "n", count: 256),
            engineVersion: String(repeating: "v", count: 128))
        XCTAssertEqual(try LearningBackupArchive.decode(try atLimit.encoded()), atLimit)
    }

    func testMetadataControlCharactersAreRejectedIncludingOnDecode() throws {
        assertThrows(
            .metadataControlCharacter(field: .sourceName),
            try makeArchive(dictionaries: [try snapshot("words", "a")], sourceName: "方\n案"))
        assertThrows(
            .metadataControlCharacter(field: .sourceID),
            try LearningBackupArchive.decode(
                try rawArchive(
                    sourceID: "rime\u{0}ice",
                    dictionaries: [])))
    }

    func testDecodeEnforcesMetadataBounds() throws {
        let payload = Data("x".utf8)
        let digest = try LearningBackupArchive.sha256Hex(payload)
        let dictionaries = [rawSnapshot(sha256: digest, data: payload.base64EncodedString())]

        assertThrows(
            .emptyMetadata(field: .sourceID),
            try LearningBackupArchive.decode(
                try rawArchive(
                    sourceID: "",
                    dictionaries: dictionaries)))
        assertThrows(
            .metadataTooLong(field: .engineVersion, bytes: 129),
            try LearningBackupArchive.decode(
                try rawArchive(
                    engineVersion: String(repeating: "v", count: 129),
                    dictionaries: dictionaries)))
        assertThrows(
            .metadataControlCharacter(field: .sourceName),
            try LearningBackupArchive.decode(
                try rawArchive(
                    sourceName: "a\rb",
                    dictionaries: dictionaries)))
    }

    func testNonFiniteCreatedAtIsRejected() throws {
        assertThrows(
            .invalidCreatedAt,
            try makeArchive(
                dictionaries: [try snapshot("words", "a")],
                createdAt: Date(timeIntervalSince1970: .infinity)))
    }

    // MARK: - Size bounds

    func testSingleDictionarySizeBoundary() throws {
        let exactLimit = Data(repeating: 0x41, count: LearningBackupArchive.maximumDictionaryBytes)
        let overLimit = Data(repeating: 0x41, count: LearningBackupArchive.maximumDictionaryBytes + 1)

        // Exactly 4 MiB: accepted.
        let accepted = try makeArchive(dictionaries: [
            try LearningBackupArchive.DictionarySnapshot(name: "words", data: exactLimit)
        ])
        XCTAssertEqual(
            try LearningBackupArchive.decode(try accepted.encoded()).dictionaries[0].data,
            exactLimit)

        // 4 MiB + 1: both the construction path and the decode path must reject.
        assertThrows(
            .dictionaryTooLarge(dictionaryIndex: 0, bytes: overLimit.count),
            try makeArchive(dictionaries: [
                try LearningBackupArchive.DictionarySnapshot(name: "words", data: overLimit)
            ]))
        assertThrows(
            .dictionaryTooLarge(dictionaryIndex: 0, bytes: overLimit.count),
            try LearningBackupArchive.decode(
                try rawArchive(dictionaries: [
                    rawSnapshot(
                        sha256: try LearningBackupArchive.sha256Hex(overLimit),
                        data: overLimit.base64EncodedString())
                ])))
    }

    func testTotalDictionaryBytesBoundaryIsEnforcedOnDecode() throws {
        // Three items of 2.8 MiB each: each is valid, total 8.4 MiB > 8 MiB; still < 12 MiB after base64, so
        // only the "validate the raw total after decoding" layer can stop it.
        let chunk = Data(repeating: 0x42, count: 2_800_000)
        let digest = try LearningBackupArchive.sha256Hex(chunk)
        let base64 = chunk.base64EncodedString()
        let payload = try rawArchive(dictionaries: [
            rawSnapshot(name: "one", sha256: digest, data: base64),
            rawSnapshot(name: "two", sha256: digest, data: base64),
            rawSnapshot(name: "three", sha256: digest, data: base64),
        ])
        XCTAssertLessThan(payload.count, LearningBackupArchive.maximumEncodedBytes)
        assertThrows(
            .dictionariesTooLarge(bytes: 2_800_000 * 3),
            try LearningBackupArchive.decode(payload))

        // The construction path also rejects.
        assertThrows(
            .dictionariesTooLarge(bytes: 2_800_000 * 3),
            try makeArchive(dictionaries: [
                try LearningBackupArchive.DictionarySnapshot(name: "one", data: chunk),
                try LearningBackupArchive.DictionarySnapshot(name: "two", data: chunk),
                try LearningBackupArchive.DictionarySnapshot(name: "three", data: chunk),
            ]))
    }

    func testExactlyEightMiBRawRoundtripsWithinEncodedLimit() throws {
        let half = Data(repeating: 0x43, count: LearningBackupArchive.maximumDictionaryBytes)
        let archive = try makeArchive(dictionaries: [
            try LearningBackupArchive.DictionarySnapshot(name: "left", data: half),
            try LearningBackupArchive.DictionarySnapshot(name: "right", data: half),
        ])
        let encoded = try archive.encoded()
        XCTAssertLessThanOrEqual(
            encoded.count, LearningBackupArchive.maximumEncodedBytes,
            "the maximum legal raw size must still encode within 12 MiB")
        XCTAssertEqual(try LearningBackupArchive.decode(encoded), archive)
    }

    func testEncodedInputSizeGateRunsBeforeParsing() throws {
        let overLimit = Data(
            repeating: 0x20,
            count: LearningBackupArchive.maximumEncodedBytes + 1)
        assertThrows(
            .encodedTooLarge(bytes: overLimit.count),
            try LearningBackupArchive.decode(overLimit))

        // Exactly 12 MiB: passes the size gate but must still be rejected by parsing/validation (not a crash, not accepted).
        let atLimit = Data(repeating: 0x20, count: LearningBackupArchive.maximumEncodedBytes)
        assertThrows(.malformedArchive, try LearningBackupArchive.decode(atLimit))
    }

    // MARK: - Same source / same resource revision

    func testIdentityValidationRequiresExactMatch() throws {
        let archive = try makeArchive(
            dictionaries: [try snapshot("words", "a")],
            sourceID: "rime-ice",
            resourceRevision: "rev-2026-01-01")
        XCTAssertNoThrow(
            try archive.validateIdentity(
                sourceID: "rime-ice",
                resourceRevision: "rev-2026-01-01"))

        assertThrows(
            .identityMismatch(field: .sourceID),
            try archive.validateIdentity(
                sourceID: "rime-ice-other",
                resourceRevision: "rev-2026-01-01"))
        // A prefix/substring is not a match: must be exactly equal.
        assertThrows(
            .identityMismatch(field: .sourceID),
            try archive.validateIdentity(
                sourceID: "rime",
                resourceRevision: "rev-2026-01-01"))
        assertThrows(
            .identityMismatch(field: .resourceRevision),
            try archive.validateIdentity(
                sourceID: "rime-ice",
                resourceRevision: "rev-2026-01-02"))
        // An identity string that is itself invalid is rejected first by the metadata rules.
        assertThrows(
            .emptyMetadata(field: .sourceID),
            try archive.validateIdentity(
                sourceID: "",
                resourceRevision: "rev-2026-01-01"))
        assertThrows(
            .metadataTooLong(field: .resourceRevision, bytes: 257),
            try archive.validateIdentity(
                sourceID: "rime-ice",
                resourceRevision: String(repeating: "r", count: 257)))
    }

    // MARK: - User-facing text does not leak content

    func testErrorMessagesDoNotLeakDictionaryNamesOrEntries() throws {
        let secretName = "秘密词典名"
        let secretEntry = "SECRET-ENTRY-词条"
        let archive = try makeArchive(dictionaries: [try snapshot(secretName, secretEntry)])

        var tampered = try jsonObject(of: archive)
        var dictionaries = try XCTUnwrap(tampered["dictionaries"] as? [[String: Any]])
        dictionaries[0]["data"] = Data("changed".utf8).base64EncodedString()
        tampered["dictionaries"] = dictionaries

        var badName = try jsonObject(of: archive)
        badName["sourceName"] = "方\n案"

        let samples: [LearningBackupArchiveError] = [
            .cryptoUnavailable,
            .unsupportedVersion(2),
            .unexpectedProducer,
            .malformedDigest(dictionaryIndex: 0),
            .digestMismatch(dictionaryIndex: 0),
            .emptyDictionaries,
            .tooManyDictionaries(count: 33),
            .duplicateDictionaryName,
            .invalidDictionaryName(.pathSeparator),
            .dictionaryTooLarge(dictionaryIndex: 0, bytes: 5),
            .dictionariesTooLarge(bytes: 9),
            .encodedTooLarge(bytes: 13),
            .emptyMetadata(field: .sourceID),
            .metadataTooLong(field: .engineVersion, bytes: 129),
            .metadataControlCharacter(field: .sourceName),
            .identityMismatch(field: .sourceID),
        ]
        for error in samples {
            let description = try XCTUnwrap(error.errorDescription)
            XCTAssertFalse(description.isEmpty)
            XCTAssertFalse(description.contains(secretName), "the text leaks the dictionary name: \(description)")
            XCTAssertFalse(description.contains("SECRET"), "the text leaks entry content: \(description)")
        }

        // Text on the real failure path likewise contains no name/content.
        for data in [try reserialize(tampered), try reserialize(badName)] {
            XCTAssertThrowsError(try LearningBackupArchive.decode(data)) { error in
                let description = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                XCTAssertFalse(description.contains(secretName), "the text leaks the dictionary name: \(description)")
                XCTAssertFalse(description.contains("SECRET"), "the text leaks entry content: \(description)")
            }
        }
    }
}
