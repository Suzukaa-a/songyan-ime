import Foundation

#if canImport(CryptoKit)
    import CryptoKit
#endif

// MARK: - Learning-data backup archive (bounded, pure data, validated on every path)
//
// Purpose: the wire-format value type used when the keyboard extension exports/imports a snapshot
// of the user dictionaries the engine has learned.
//
// Hard boundaries:
//  * Pure data: no file I/O, no engine calls, no UIKit/SwiftUI; shared by host and extension.
//  * Single validation entry: `validate()` is the only rule implementation; the `public init`,
//    `encoded()` and `decode(_:)` all go through it. The decode path has no skip-validation branch:
//    invalid bytes can never become a usable archive.
//  * Fail closed: any non-conforming input throws; a partially trusted archive is never returned
//    and success is never faked.
//  * Describes source identity only (sourceID / resourceRevision / sourceName / engineVersion);
//    it does not parse Rime's internal snapshot content (db_name / db_type and merge semantics are validated by the engine layer).
//
// Wire format (version = 1, JSON):
//   {
//     "version": 1,
//     "producer": "keyboard-extension",
//     "sourceID": "...",            // input-method/source identifier (bounded)
//     "resourceRevision": "...",     // resource revision (bounded)
//     "sourceName": "...",           // display name (bounded)
//     "engineVersion": "...",        // engine version (bounded)
//     "createdAt": "2026-01-01T00:00:00Z",   // ISO8601 (whole seconds)
//     "dictionaries": [ { "name": "...", "sha256": "<64 lowercase hex chars>", "data": "<base64>" } ]
//   }
//
// Bounds (bytes always means UTF-8 bytes):
//   * 1...32 dictionaries; names non-empty and <= 256 B;
//   * each data <= 4 MiB; all data combined <= 8 MiB; encoded input <= 12 MiB;
//   * sourceID <= 512 B, resourceRevision <= 256 B, sourceName <= 256 B, engineVersion <= 128 B.
public struct LearningBackupArchive: Codable, Equatable, Sendable {

    // MARK: - Format constants (must match exactly)

    /// Format version written by this implementation.
    public static let currentVersion = 1
    /// Producer written by this implementation; together with version it declares whose backup this is.
    public static let expectedProducer = "keyboard-extension"
    /// Length of the lowercase hex SHA256 digest.
    public static let digestHexLength = 64

    // MARK: - Bound constants

    public static let maximumDictionaryCount = 32
    public static let maximumDictionaryBytes = 4 * 1_024 * 1_024
    public static let maximumTotalDictionaryBytes = 8 * 1_024 * 1_024
    public static let maximumEncodedBytes = 12 * 1_024 * 1_024
    public static let maximumDictionaryNameBytes = 256
    public static let maximumSourceIDBytes = 512
    public static let maximumResourceRevisionBytes = 256
    public static let maximumSourceNameBytes = 256
    public static let maximumEngineVersionBytes = 128

    // MARK: - Fields

    public let version: Int
    public let producer: String
    public let sourceID: String
    public let resourceRevision: String
    public let sourceName: String
    public let engineVersion: String
    /// Archive creation time, normalized to whole seconds (the wire format is whole-second ISO8601; see `normalizedTimestamp`),
    /// so the Date is bit-identical after encode -> decode.
    public let createdAt: Date
    public let dictionaries: [DictionarySnapshot]

    // MARK: - Construction

    /// Constructs and fully validates immediately; any violation throws (no half-built result).
    ///
    /// `version` / `producer` have defaults; passing any other value must throw (e.g. rejecting a future
    /// format or a foreign producer). `createdAt` is normalized to whole seconds.
    public init(
        version: Int = LearningBackupArchive.currentVersion,
        producer: String = LearningBackupArchive.expectedProducer,
        sourceID: String,
        resourceRevision: String,
        sourceName: String,
        engineVersion: String,
        createdAt: Date,
        dictionaries: [DictionarySnapshot]
    ) throws {
        self.version = version
        self.producer = producer
        self.sourceID = sourceID
        self.resourceRevision = resourceRevision
        self.sourceName = sourceName
        self.engineVersion = engineVersion
        self.createdAt = LearningBackupArchive.normalizedTimestamp(createdAt)
        self.dictionaries = dictionaries
        try validate()
    }

    /// Normalizes a timestamp to whole seconds: the wire format is whole-second ISO8601, and without
    /// normalizing, input with fractional seconds would change across encode -> decode (breaking Equatable round-tripping).
    public static func normalizedTimestamp(_ date: Date) -> Date {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite else { return date }
        return Date(timeIntervalSince1970: seconds.rounded(.down))
    }

    // MARK: - Validation (the single rule entry)

    /// Full validation. Every public entry point calls it.
    public func validate() throws {
        guard version == LearningBackupArchive.currentVersion else {
            throw LearningBackupArchiveError.unsupportedVersion(version)
        }
        guard producer == LearningBackupArchive.expectedProducer else {
            throw LearningBackupArchiveError.unexpectedProducer
        }
        guard createdAt.timeIntervalSinceReferenceDate.isFinite else {
            throw LearningBackupArchiveError.invalidCreatedAt
        }

        try LearningBackupArchive.validateMetadata(
            sourceID, field: .sourceID,
            limit: LearningBackupArchive.maximumSourceIDBytes)
        try LearningBackupArchive.validateMetadata(
            resourceRevision, field: .resourceRevision,
            limit: LearningBackupArchive.maximumResourceRevisionBytes)
        try LearningBackupArchive.validateMetadata(
            sourceName, field: .sourceName,
            limit: LearningBackupArchive.maximumSourceNameBytes)
        try LearningBackupArchive.validateMetadata(
            engineVersion, field: .engineVersion,
            limit: LearningBackupArchive.maximumEngineVersionBytes)

        guard dictionaries.count <= LearningBackupArchive.maximumDictionaryCount else {
            throw LearningBackupArchiveError.tooManyDictionaries(count: dictionaries.count)
        }
        guard !dictionaries.isEmpty else {
            throw LearningBackupArchiveError.emptyDictionaries
        }

        var seenNames = Set<String>()
        var totalBytes = 0
        for (index, snapshot) in dictionaries.enumerated() {
            try LearningBackupArchive.validateDictionaryName(snapshot.name)
            // Dictionary names end up as file names: besides exact duplicates, names equal after case /
            // Unicode normalization are rejected so they can't overwrite each other on (default case-insensitive) file systems.
            let uniquenessKey = snapshot.name
                .precomposedStringWithCanonicalMapping
                .lowercased()
            guard seenNames.insert(uniquenessKey).inserted else {
                throw LearningBackupArchiveError.duplicateDictionaryName
            }
            // Do the cheap bound checks first, then compute the digest (no useless hashing of over-limit data).
            guard snapshot.data.count <= LearningBackupArchive.maximumDictionaryBytes else {
                throw LearningBackupArchiveError.dictionaryTooLarge(
                    dictionaryIndex: index,
                    bytes: snapshot.data.count)
            }
            totalBytes += snapshot.data.count
            guard totalBytes <= LearningBackupArchive.maximumTotalDictionaryBytes else {
                throw LearningBackupArchiveError.dictionariesTooLarge(bytes: totalBytes)
            }
            try LearningBackupArchive.validateDigest(snapshot.sha256, dictionaryIndex: index)
            let actual = try LearningBackupArchive.sha256Hex(snapshot.data)
            guard actual == snapshot.sha256 else {
                throw LearningBackupArchiveError.digestMismatch(dictionaryIndex: index)
            }
        }
    }

    /// Strict same source + same resource revision. Compares identity strings only and does not parse Rime's internal snapshot
    /// content (db_name / db_type etc. are validated by the engine layer).
    public func validateIdentity(
        sourceID otherSourceID: String,
        resourceRevision otherRevision: String
    ) throws {
        try LearningBackupArchive.validateMetadata(
            otherSourceID, field: .sourceID,
            limit: LearningBackupArchive.maximumSourceIDBytes)
        try LearningBackupArchive.validateMetadata(
            otherRevision, field: .resourceRevision,
            limit: LearningBackupArchive.maximumResourceRevisionBytes)
        guard otherSourceID == sourceID else {
            throw LearningBackupArchiveError.identityMismatch(field: .sourceID)
        }
        guard otherRevision == resourceRevision else {
            throw LearningBackupArchiveError.identityMismatch(field: .resourceRevision)
        }
    }

    // MARK: - Encode / decode

    /// Fixed encoding strategy: `sortedKeys` (byte-level determinism) + ISO8601 whole-second dates.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// Decoding strategy paired with `makeEncoder()`.
    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Encodes to JSON (full validation first; exceeding `maximumEncodedBytes` also throws,
    /// guaranteeing that `decode(try archive.encoded())` is within the input limit).
    public func encoded() throws -> Data {
        try validate()
        let data: Data
        do {
            data = try LearningBackupArchive.makeEncoder().encode(self)
        } catch {
            throw LearningBackupArchiveError.malformedArchive
        }
        guard data.count <= LearningBackupArchive.maximumEncodedBytes else {
            throw LearningBackupArchiveError.encodedTooLarge(bytes: data.count)
        }
        return data
    }

    /// Decodes from JSON. Checks the input size first (no parser allocated for oversized input), then parses and fully validates;
    /// no invalid data can bypass `validate()`.
    public static func decode(_ data: Data) throws -> LearningBackupArchive {
        guard data.count <= LearningBackupArchive.maximumEncodedBytes else {
            throw LearningBackupArchiveError.encodedTooLarge(bytes: data.count)
        }
        do {
            return try LearningBackupArchive.makeDecoder().decode(LearningBackupArchive.self, from: data)
        } catch let error as LearningBackupArchiveError {
            throw error
        } catch {
            // Underlying decoding descriptions aren't passed on (they may contain the raw parsed values).
            throw LearningBackupArchiveError.malformedArchive
        }
    }

    // MARK: - Codable (hand-written: missing fields/type errors are controlled and raw values aren't leaked)

    private enum CodingKeys: String, CodingKey {
        case version, producer, sourceID, resourceRevision, sourceName, engineVersion, createdAt, dictionaries
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func field<T: Decodable>(_ key: CodingKeys, _ type: T.Type) throws -> T {
            guard let value = try container.decodeIfPresent(T.self, forKey: key) else {
                throw LearningBackupArchiveError.missingField(key.rawValue)
            }
            return value
        }
        // Scalar fields are decoded first, then the dictionary array incrementally (see decodeDictionaries).
        // Finally it delegates to the public init, so the decode and construct paths share the same validation
        // (the full SHA256 comparison therefore happens once, in validate()).
        try self.init(
            version: try field(.version, Int.self),
            producer: try field(.producer, String.self),
            sourceID: try field(.sourceID, String.self),
            resourceRevision: try field(.resourceRevision, String.self),
            sourceName: try field(.sourceName, String.self),
            engineVersion: try field(.engineVersion, String.self),
            createdAt: try field(.createdAt, Date.self),
            dictionaries: try LearningBackupArchive.decodeDictionaries(from: container))
    }

    /// Decodes the dictionary array incrementally, keeping memory bounded in terms of allocation.
    ///
    /// Why not `decode([DictionarySnapshot].self)` directly: 12 MiB of malicious JSON can hold tens of
    /// thousands of tiny dictionary objects, and `[DictionarySnapshot]` would instantiate all of them first
    /// (each with base64-decoded `Data`) before `validate()` notices the count exceeds 32, by which time the memory is spent.
    ///
    /// Instead:
    ///  1. if the container already reports a length above 32, reject immediately without decoding any element;
    ///  2. otherwise decode item by item and run cheap bound checks right after each
    ///     (name format in `DictionarySnapshot.init(from:)`, data <= 4 MiB, cumulative <= 8 MiB,
    ///     digest must be 64 lowercase hex); stop at the first non-conforming item;
    ///  3. the loop index itself also enforces 32, without relying on `count` being available (`count` may be nil).
    ///
    /// The full SHA256 <-> Data comparison (the only expensive step) is not done here; it is left to `validate()`
    /// so the same data isn't hashed twice.
    private static func decodeDictionaries(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> [DictionarySnapshot] {
        // A missing key and a key that isn't an array are reported separately: the former is missingField, the latter malformedArchive.
        guard container.contains(.dictionaries) else {
            throw LearningBackupArchiveError.missingField(CodingKeys.dictionaries.rawValue)
        }
        guard var items = try? container.nestedUnkeyedContainer(forKey: .dictionaries) else {
            throw LearningBackupArchiveError.malformedArchive
        }
        // Fast path: a known length is rejected up front without touching any element.
        if let reported = items.count, reported > maximumDictionaryCount {
            throw LearningBackupArchiveError.tooManyDictionaries(count: reported)
        }
        var dictionaries: [DictionarySnapshot] = []
        dictionaries.reserveCapacity(
            min(
                items.count ?? maximumDictionaryCount,
                maximumDictionaryCount))
        var totalBytes = 0
        while !items.isAtEnd {
            let index = dictionaries.count
            // Fallback for containers of unknown length: the 33rd item is rejected before decoding.
            guard index < maximumDictionaryCount else {
                throw LearningBackupArchiveError.tooManyDictionaries(
                    count: maximumDictionaryCount + 1)
            }
            guard let snapshot = try items.decodeIfPresent(DictionarySnapshot.self) else {
                throw LearningBackupArchiveError.malformedArchive
            }
            guard snapshot.data.count <= maximumDictionaryBytes else {
                throw LearningBackupArchiveError.dictionaryTooLarge(
                    dictionaryIndex: index,
                    bytes: snapshot.data.count)
            }
            totalBytes += snapshot.data.count
            guard totalBytes <= maximumTotalDictionaryBytes else {
                throw LearningBackupArchiveError.dictionariesTooLarge(bytes: totalBytes)
            }
            try validateDigest(snapshot.sha256, dictionaryIndex: index)
            dictionaries.append(snapshot)
        }
        return dictionaries
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(producer, forKey: .producer)
        try container.encode(sourceID, forKey: .sourceID)
        try container.encode(resourceRevision, forKey: .resourceRevision)
        try container.encode(sourceName, forKey: .sourceName)
        try container.encode(engineVersion, forKey: .engineVersion)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(dictionaries, forKey: .dictionaries)
    }

    // MARK: - Single dictionary snapshot

    /// One dictionary snapshot: name + content digest + raw bytes.
    ///
    /// The digest can't be filled in by callers: the only public factory `init(name:data:)` computes it from the real Data;
    /// the initializer that carries an external digest is internal, for the decode path only (the archive layer then validates consistency).
    public struct DictionarySnapshot: Codable, Equatable, Sendable {

        public let name: String
        /// SHA256(data) as 64 lowercase hex characters.
        public let sha256: String
        public let data: Data

        // MARK: - Public factory (digest computed from the real data)

        public init(name: String, data: Data) throws {
            try LearningBackupArchive.validateDictionaryName(name)
            self.name = name
            self.data = data
            self.sha256 = try LearningBackupArchive.sha256Hex(data)
        }

        /// Decode path only: the digest comes from the wire format and the archive layer validates it (so it can't be recomputed from data).
        init(name: String, sha256: String, data: Data) {
            self.name = name
            self.sha256 = sha256
            self.data = data
        }

        // MARK: - Codable

        private enum CodingKeys: String, CodingKey {
            case name, sha256, data
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            func field<T: Decodable>(_ key: CodingKeys, _ type: T.Type) throws -> T {
                guard let value = try container.decodeIfPresent(T.self, forKey: key) else {
                    throw LearningBackupArchiveError.missingField("dictionaries." + key.rawValue)
                }
                return value
            }
            let name = try field(.name, String.self)
            try LearningBackupArchive.validateDictionaryName(name)
            self.init(
                name: name,
                sha256: try field(.sha256, String.self),
                data: try field(.data, Data.self))
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encode(sha256, forKey: .sha256)
            try container.encode(data, forKey: .data)
        }
    }

    // MARK: - Validation primitives

    /// Dictionary name rules: non-empty, <= 256 B, no path separators, no control characters, not `.` / `..`, no leading dot;
    /// any other valid Unicode (CJK, emoji, combining marks, etc.) is allowed.
    static func validateDictionaryName(_ name: String) throws {
        let byteCount = name.utf8.count
        guard byteCount > 0 else {
            throw LearningBackupArchiveError.invalidDictionaryName(.empty)
        }
        guard byteCount <= maximumDictionaryNameBytes else {
            throw LearningBackupArchiveError.invalidDictionaryName(.tooLong(bytes: byteCount))
        }
        guard !name.contains("/"), !name.contains("\\") else {
            throw LearningBackupArchiveError.invalidDictionaryName(.pathSeparator)
        }
        guard name.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw LearningBackupArchiveError.invalidDictionaryName(.controlCharacter)
        }
        guard name != ".", name != ".." else {
            throw LearningBackupArchiveError.invalidDictionaryName(.relativePathComponent)
        }
        guard !name.hasPrefix(".") else {
            throw LearningBackupArchiveError.invalidDictionaryName(.leadingDot)
        }
    }

    /// Identity metadata rules: non-empty, bounded, no control characters.
    static func validateMetadata(_ value: String, field: LearningBackupArchiveError.Field, limit: Int) throws {
        let byteCount = value.utf8.count
        guard byteCount > 0 else {
            throw LearningBackupArchiveError.emptyMetadata(field: field)
        }
        guard byteCount <= limit else {
            throw LearningBackupArchiveError.metadataTooLong(field: field, bytes: byteCount)
        }
        guard value.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw LearningBackupArchiveError.metadataControlCharacter(field: field)
        }
    }

    /// The digest must be 64 lowercase hex characters (mixed or upper case is rejected so one value can't have several forms).
    static func validateDigest(_ digest: String, dictionaryIndex: Int) throws {
        let allowed = CharacterSet(charactersIn: "0123456789abcdef")
        guard digest.utf8.count == digestHexLength,
            digest.unicodeScalars.allSatisfy({ allowed.contains($0) })
        else {
            throw LearningBackupArchiveError.malformedDigest(dictionaryIndex: dictionaryIndex)
        }
    }

    /// Real SHA256 as lowercase hex. Fails closed without CryptoKit (a weak hash never stands in for SHA256).
    static func sha256Hex(_ data: Data) throws -> String {
        #if canImport(CryptoKit)
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
            throw LearningBackupArchiveError.cryptoUnavailable
        #endif
    }
}

// MARK: - Failure reasons

/// Failure reasons of the archive. User-facing messages contain no dictionary names or entries (only field categories and byte counts).
public enum LearningBackupArchiveError: Error, LocalizedError, Equatable, Sendable {

    /// Identity metadata field (for precise messages; carries no field values).
    public enum Field: String, Sendable, Equatable {
        case sourceID
        case resourceRevision
        case sourceName
        case engineVersion

        /// User-facing field description.
        public var localizedName: String {
            switch self {
            case .sourceID: return "输入方案标识"
            case .resourceRevision: return "方案版本"
            case .sourceName: return "输入方案名称"
            case .engineVersion: return "引擎版本"
            }
        }
    }

    /// Why a dictionary name was rejected (also without the name itself).
    public enum NameRejection: Equatable, Sendable {
        case empty
        case tooLong(bytes: Int)
        case pathSeparator
        case controlCharacter
        case relativePathComponent
        case leadingDot
    }

    /// SHA256 can't be computed on this platform (no CryptoKit).
    case cryptoUnavailable
    /// `version` isn't a supported format version.
    case unsupportedVersion(Int)
    /// `producer` isn't `keyboard-extension`.
    case unexpectedProducer
    /// The wire format lacks a required field.
    case missingField(String)
    /// JSON can't be parsed or has mismatched types.
    case malformedArchive
    /// The digest isn't 64 lowercase hex characters.
    case malformedDigest(dictionaryIndex: Int)
    /// The digest doesn't match the real Data (content was rewritten or corrupted).
    case digestMismatch(dictionaryIndex: Int)
    /// The dictionary set is empty.
    case emptyDictionaries
    /// More than 32 dictionaries.
    case tooManyDictionaries(count: Int)
    /// Duplicate dictionary name (including duplicates after normalization/case folding).
    case duplicateDictionaryName
    /// Invalid dictionary name.
    case invalidDictionaryName(NameRejection)
    /// A single dictionary exceeds 4 MiB.
    case dictionaryTooLarge(dictionaryIndex: Int, bytes: Int)
    /// All dictionaries combined exceed 8 MiB.
    case dictionariesTooLarge(bytes: Int)
    /// Encoded input exceeds 12 MiB.
    case encodedTooLarge(bytes: Int)
    /// Identity metadata is empty.
    case emptyMetadata(field: Field)
    /// Identity metadata exceeds the length limit.
    case metadataTooLong(field: Field, bytes: Int)
    /// Identity metadata contains control characters.
    case metadataControlCharacter(field: Field)
    /// Creation time isn't a finite value.
    case invalidCreatedAt
    /// Backup source/resource revision doesn't match the current one.
    case identityMismatch(field: Field)

    public var errorDescription: String? {
        switch self {
        case .cryptoUnavailable:
            return "当前设备无法校验备份的完整性。"
        case .unsupportedVersion(let version):
            return "备份格式版本（\(version)）不受支持。"
        case .unexpectedProducer:
            return "备份不是由键盘扩展生成的，无法导入。"
        case .missingField(let key):
            return "备份缺少必需字段（\(key)）。"
        case .malformedArchive:
            return "备份内容已损坏或格式不正确。"
        case .malformedDigest:
            return "备份中的词典摘要格式不正确。"
        case .digestMismatch:
            return "备份中的词典内容与摘要不一致，可能已损坏。"
        case .emptyDictionaries:
            return "备份不包含任何词典。"
        case .tooManyDictionaries:
            return "备份包含的词典数量超过上限。"
        case .duplicateDictionaryName:
            return "备份中存在重复的词典名。"
        case .invalidDictionaryName:
            return "备份中存在不合法的词典名。"
        case .dictionaryTooLarge:
            return "备份中的单个词典超过大小上限。"
        case .dictionariesTooLarge:
            return "备份的词典总大小超过上限。"
        case .encodedTooLarge:
            return "备份文件超过大小上限。"
        case .emptyMetadata(let field):
            return "备份缺少\(field.localizedName)。"
        case .metadataTooLong(let field, _):
            return "\(field.localizedName)超过长度上限。"
        case .metadataControlCharacter(let field):
            return "\(field.localizedName)包含不允许的控制字符。"
        case .invalidCreatedAt:
            return "备份的创建时间无效。"
        case .identityMismatch(let field):
            return "备份与当前的\(field.localizedName)不一致，无法导入。"
        }
    }
}
