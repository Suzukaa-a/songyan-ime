import Foundation

// MARK: - Declarative composition display capability (runtime contract)
//
// Display modes. The capability is written explicitly into the source/companion
// schema at generation time; it is never inferred from the layout, comments,
// the dictionary, or candidate text.
//   * `native`         - engine preedit unchanged (default; also used for a missing
//                        block or unknown version).
//   * `canonical`      - verified canonical pinyin display.
//   * `source_code`    - the source scheme's unique normal algebra code, joined with the
//                        display `separator`; the source `preedit_format` is NOT applied
//                        (it would expand shuangpin codes back into full pinyin).
//   * `source_rendered`- reserved; not implemented, always decoded as unsupported
//                        and falls back to native.
//
// This file holds only pure functions: given the syllable tokens of a trusted candidate
// (canonical syllables from the engine's `Dictionary::Decode`) and an explicit capability
// block, compute the display value. It does not read comments, write rawInput/preedit/control flow, or guess
// layouts or alphabets.
//
// Trust boundary: callers must invoke this only after the existing native gates pass
// (unique script translator, candidate type, exact code/text, byte-identical range,
// matching language; see `rime_spelling.cc:182-241`). If any token cannot be proven
// (missing, empty, unsupported), the whole segment falls back to native; spellings are
// never mixed.
//
// A missing block, unknown versions, and invalid `mapping_policy` decode as no
// capability (native).

/// Composition display mode. `sourceRendered` is reserved and unimplemented.
public enum CompositionDisplayMode: String, Codable, Equatable, Sendable {
    case native
    case canonical
    case sourceCode = "source_code"
    case sourceRendered = "source_rendered"
}

/// The `keyboard_adapter` capability block written at the top of a schema at generation
/// time (read-only value type at runtime).
///
/// The wire format (YAML/JSON keys) is a production contract; the PackageManager
/// generator must write the same field names:
/// ```yaml
/// keyboard_adapter:
///   version: 1
///   display_mode: source_code
///   source_schema: songyan_flypy
///   translator_namespace: translator
///   separator: "'"
///   mapping_policy: unique_normal
///   syllables: { zao: zc, shang: uh, hao: hc, ... }
/// ```
public struct SchemaDisplayCapability: Equatable, Sendable {
    /// The only supported version; unknown versions must not take part in re-expression.
    public static let supportedVersion = 1
    /// The only supported mapping policy: each token has exactly one normal
    /// (non-fuzzy/abbrev/correction) spelling.
    public static let uniqueNormalPolicy = "unique_normal"

    public let version: Int
    public let mode: CompositionDisplayMode
    public let sourceSchema: String
    public let translatorNamespace: String
    public let separator: String
    public let mappingPolicy: String
    /// Id of the companion adapter schema that owns the block; it must equal the schema id
    /// of the current producer at runtime, so a valid block copied to another companion
    /// scheme is not trusted.
    public let adapterSchema: String
    public let syllables: [String: String]

    public init(
        version: Int, mode: CompositionDisplayMode, sourceSchema: String,
        translatorNamespace: String, separator: String,
        mappingPolicy: String, adapterSchema: String = "",
        syllables: [String: String]
    ) {
        self.version = version
        self.mode = mode
        self.sourceSchema = sourceSchema
        self.translatorNamespace = translatorNamespace
        self.separator = separator
        self.mappingPolicy = mappingPolicy
        self.adapterSchema = adapterSchema
        self.syllables = syllables
    }

    public enum DecodeError: Error, Equatable {
        case unsupportedVersion(Int)
        case unknownDisplayMode(String)
        case unsupportedMappingPolicy(String)
        case emptySourceSchema
        case emptyTranslatorNamespace
        case emptySeparator
        case emptyAdapterSchema
        case emptySyllableKey
        case emptySyllableValue(String)
    }

    /// Strict decode: returns nil if any gate fails (callers must fall back to native).
    /// `canonical`/`source_code`/`source_rendered` must carry `adapter_schema`;
    /// `source_code` also needs `unique_normal` and a non-empty mapping.
    public init?(wire: [String: Any]) {
        guard let version = (wire["version"] as? NSNumber)?.intValue else { return nil }
        guard version == Self.supportedVersion else { return nil }
        guard let rawMode = wire["display_mode"] as? String,
            let mode = CompositionDisplayMode(rawValue: rawMode)
        else { return nil }
        guard let sourceSchema = wire["source_schema"] as? String, !sourceSchema.isEmpty else { return nil }
        guard let namespace = wire["translator_namespace"] as? String, !namespace.isEmpty else { return nil }
        guard let separator = wire["separator"] as? String, !separator.isEmpty else { return nil }
        let policy = wire["mapping_policy"] as? String ?? ""
        let adapterSchema = wire["adapter_schema"] as? String ?? ""
        var syllables: [String: String] = [:]
        if let rawSyllables = wire["syllables"] as? [String: String] {
            for (token, spelling) in rawSyllables {
                guard !token.isEmpty else { return nil }
                guard !spelling.isEmpty else { return nil }
                syllables[token] = spelling
            }
        }
        if mode == .canonical || mode == .sourceCode || mode == .sourceRendered {
            guard !adapterSchema.isEmpty else { return nil }
        }
        if mode == .sourceCode || mode == .sourceRendered {
            guard policy == Self.uniqueNormalPolicy else { return nil }
            guard !syllables.isEmpty else { return nil }
        }
        self.version = version
        self.mode = mode
        self.sourceSchema = sourceSchema
        self.translatorNamespace = namespace
        self.separator = separator
        self.mappingPolicy = policy
        self.adapterSchema = adapterSchema
        self.syllables = syllables
    }

    /// Decodes JSON produced by the native bridge; returns nil (native) on any failure.
    public static func decode(json data: Data) -> SchemaDisplayCapability? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
            let wire = object as? [String: Any]
        else { return nil }
        return SchemaDisplayCapability(wire: wire)
    }

    /// Wire-format dictionary for generation/tests (keys match the generator).
    public func wireDictionary() -> [String: Any] {
        [
            "version": version,
            "display_mode": mode.rawValue,
            "source_schema": sourceSchema,
            "translator_namespace": translatorNamespace,
            "separator": separator,
            "mapping_policy": mappingPolicy,
            "adapter_schema": adapterSchema,
            "syllables": syllables,
        ]
    }
}

extension SchemaDisplayCapability: Codable {
    private enum CodingKeys: String, CodingKey {
        case version
        case displayMode = "display_mode"
        case sourceSchema = "source_schema"
        case translatorNamespace = "translator_namespace"
        case separator
        case mappingPolicy = "mapping_policy"
        case adapterSchema = "adapter_schema"
        case syllables
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var wire: [String: Any] = [:]
        wire["version"] = try container.decode(Int.self, forKey: .version)
        wire["display_mode"] = try container.decode(String.self, forKey: .displayMode)
        wire["source_schema"] = try container.decode(String.self, forKey: .sourceSchema)
        wire["translator_namespace"] = try container.decode(String.self, forKey: .translatorNamespace)
        wire["separator"] = try container.decode(String.self, forKey: .separator)
        wire["mapping_policy"] = try container.decodeIfPresent(String.self, forKey: .mappingPolicy) ?? ""
        wire["adapter_schema"] = try container.decodeIfPresent(String.self, forKey: .adapterSchema) ?? ""
        wire["syllables"] = try container.decodeIfPresent([String: String].self, forKey: .syllables) ?? [:]
        guard let capability = SchemaDisplayCapability(wire: wire) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "invalid keyboard_adapter capability"))
        }
        self = capability
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(mode.rawValue, forKey: .displayMode)
        try container.encode(sourceSchema, forKey: .sourceSchema)
        try container.encode(translatorNamespace, forKey: .translatorNamespace)
        try container.encode(separator, forKey: .separator)
        if !mappingPolicy.isEmpty {
            try container.encode(mappingPolicy, forKey: .mappingPolicy)
        }
        if !adapterSchema.isEmpty {
            try container.encode(adapterSchema, forKey: .adapterSchema)
        }
        if !syllables.isEmpty {
            try container.encode(syllables, forKey: .syllables)
        }
    }
}

/// Resolution result. Anything other than `.display` means "keep the engine preedit";
/// no partial rewrite is produced.
public enum CompositionDisplayOutcome: Equatable, Sendable {
    case display(String)
    case native(Reason)

    public enum Reason: Equatable, Sendable {
        /// No `keyboard_adapter` block in the current schema/session (default path).
        case noCapability
        /// Explicitly declared `native`.
        case modeNative
        /// Reserved/unknown mode (`source_rendered` is unimplemented).
        case unsupportedMode(CompositionDisplayMode)
        /// The engine gave no decodable syllables.
        case emptyTokens
        /// A token is missing from the full mapping (including erase/uncovered); the whole segment falls back.
        case missingSyllable(String)
        /// Display separator missing or empty.
        case emptySeparator
    }
}

public enum CompositionDisplayPolicy {
    /// A proven phone-keypad definition emits ASCII digits as engine transport
    /// input. This predicate deliberately inspects only `rawInput` (never candidate
    /// text or schema identity): spaces inserted by an engine preedit formatter do
    /// not make `55 5` safe to show, while normal source-code input remains native.
    public static func isNumericTransport(rawInput: String) -> Bool {
        !rawInput.isEmpty && rawInput.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
    }

    public static func resolve(
        canonicalSyllables: [String],
        capability: SchemaDisplayCapability?
    ) -> CompositionDisplayOutcome {
        guard let capability else { return .native(.noCapability) }
        guard canonicalSyllables.allSatisfy({ !$0.isEmpty }), !canonicalSyllables.isEmpty else {
            return .native(.emptyTokens)
        }
        guard !capability.separator.isEmpty else { return .native(.emptySeparator) }

        switch capability.mode {
        case .native:
            return .native(.modeNative)
        case .sourceRendered:
            // Reserved: never declared until source-semantics joining + preedit_format are verified.
            return .native(.unsupportedMode(.sourceRendered))
        case .canonical:
            return .display(canonicalSyllables.joined(separator: capability.separator))
        case .sourceCode:
            var mapped: [String] = []
            mapped.reserveCapacity(canonicalSyllables.count)
            for token in canonicalSyllables {
                guard let spelling = capability.syllables[token], !spelling.isEmpty else {
                    // Never default to identity or pick the first entry for a missing token; fall back as a whole.
                    return .native(.missingSyllable(token))
                }
                mapped.append(spelling)
            }
            return .display(mapped.joined(separator: capability.separator))
        }
    }

    /// Applies the production display resolution to a snapshot and returns the
    /// EXACT outcome. Runtime (`RimeBackend.applyDisplay`) and installer
    /// verification both call this, so there is one display path — no
    /// re-implementation and no "authorized mode == displayed" assumption.
    /// Never touches `preedit`/`rawInput`/`sel`; only the display fields.
    public static func applied(
        to base: EngineSnapshot,
        canonicalSyllables: [String],
        capability: SchemaDisplayCapability?,
        hasCapability: Bool
    )
        -> (snapshot: EngineSnapshot, outcome: CompositionDisplayOutcome)
    {
        var snapshot = base
        snapshot.hasDisplayCapability = hasCapability
        // An authorized `canonical` capability is the explicit 9-key numeric display
        // contract: the engine preedit is a transport code, so the consumer must never
        // fall back to echoing it. `source_code` (14-key letters) and native keep the
        // existing partial-map/native-fallback semantics.
        snapshot.hidesNumericTransportCode =
            snapshot.hidesNumericTransportCode
            || capability?.mode == .canonical
        guard let capability else {
            snapshot.highlightedDisplay = ""
            snapshot.displayMode = .native
            return (snapshot, .native(.noCapability))
        }
        let outcome = resolve(
            canonicalSyllables: canonicalSyllables,
            capability: capability)
        switch outcome {
        case .display(let value):
            snapshot.highlightedDisplay = value
            snapshot.displayMode = capability.mode
        case .native:
            snapshot.highlightedDisplay = ""
            snapshot.displayMode = .native
        }
        return (snapshot, outcome)
    }

    /// The exact display span a resolved snapshot must mark: the production
    /// `MarkedComposition` for `[selStart, selEnd)` replaced by the display value.
    /// Returns nil when the production rewrite refuses (caller falls back).
    public static func markedSegment(
        for snapshot: EngineSnapshot,
        spellingPreedit: Bool = true
    ) -> MarkedComposition {
        MarkedComposition(snapshot: snapshot, spellingPreedit: spellingPreedit)
    }
}
