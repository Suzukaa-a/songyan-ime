import Foundation
import KeyboardCore
import Yams

// MARK: - Generation time: forward projection of the source algebra -> the single normal spelling capability block
//
// The direction is a **forward projection**, not an inversion: the trusted source dictionary's
// primary syllabary tokens (canonical syllables) are projected through the source's effective
// `speller/algebra` (**without the 14/9 merge rules appended**) into a final spelling set;
// a mapping is written only when a token has exactly one final **normal, non-correction** string.
// Missing entries, erase, several normals, fuzzy/abbrev/correction only, and non-letters
// (e.g. bopomofo) all reject that entry; if verification fails no capability is declared
// (the companion schema stays native).
//
// The generated companion is trusted as written; the runtime only falls back to native
// when the companion or its display data is missing or unloadable.

public extension CompactSchemaAdapter {
    /// Capability generation / adapter behavior version. **Any change that alters the semantics of generated artifacts must bump it**
    /// (mapping table, injected `keyboard_adapter` block, 14/9-key alias/lock layers, authorization criteria).
    ///
    /// This is the **generation invalidation criterion**, not a wire format version: it is written
    /// to `display_generator_version` in `keyboard-adapter-display.json` and, with the source's
    /// compiled digest, decides whether an installed generation must be rebuilt. The wire
    /// `keyboard_adapter` `version` is controlled separately by `SchemaDisplayCapability.supportedVersion`.
    static let displayGeneratorVersion = 9

    /// One spelling after source-algebra projection. `isNormal`/`isCorrection` come from librime's
    /// `Spelling.properties.type == kNormalSpelling` and `is_correction`, tagged by the native
    /// primitive from the **final Script properties**, never guessed from rule names.
    struct ProjectedSpelling: Equatable, Sendable {
        public let text: String
        public let isNormal: Bool
        public let isCorrection: Bool
        public init(text: String, isNormal: Bool, isCorrection: Bool) {
            self.text = text
            self.isNormal = isNormal
            self.isCorrection = isCorrection
        }
    }

    /// One source syllabary token and all of its final spellings.
    struct ProjectedSyllable: Equatable, Sendable {
        public let token: String
        public let spellings: [ProjectedSpelling]
        public init(token: String, spellings: [ProjectedSpelling]) {
            self.token = token
            self.spellings = spellings
        }
    }

    /// Product of the native primitive `rb_syllable_display_map_json`: source identity + config facts +
    /// projection.
    struct SourceProjection: Equatable, Sendable {
        public let sourceSchema: String
        public let translatorNamespace: String
        public let dictionary: String
        public let alphabet: String
        public let algebra: [String]
        public let separator: String
        /// The source's explicit semantic declaration (`keyboard_adapter_source`).
        public let declaration: String
        /// The source's explicit opt-in for the bounded letter-class prefix lock
        /// layer (`keyboard_rewrite_prefix`, e.g. `letter_class_v1`). Empty means
        /// the source does NOT opt in, so no v4 companion is generated for it.
        public let prefixDeclaration: String
        /// The single producer's class (`script_translator` / `table_translator`),
        /// or "" when the native primitive did not report one (legacy fixture).
        public let producerClass: String
        public let syllables: [ProjectedSyllable]
        public init(
            sourceSchema: String, translatorNamespace: String, dictionary: String,
            alphabet: String, algebra: [String], separator: String,
            declaration: String = "", producerClass: String = "",
            prefixDeclaration: String = "",
            syllables: [ProjectedSyllable]
        ) {
            self.sourceSchema = sourceSchema
            self.translatorNamespace = translatorNamespace
            self.dictionary = dictionary
            self.alphabet = alphabet
            self.algebra = algebra
            self.separator = separator
            self.declaration = declaration
            self.prefixDeclaration = prefixDeclaration
            self.producerClass = producerClass
            self.syllables = syllables
        }

        /// Whether this source's tokens come from a table (shape-code) translator.
        public var isTableSource: Bool { producerClass == "table_translator" }

        /// Parses the native JSON. `syllables` looks like
        /// `{ "zao": [ {"text":"zc","normal":true,"correction":false}, ... ], ... }`。
        public static func decode(json data: Data) -> SourceProjection? {
            guard let object = try? JSONSerialization.jsonObject(with: data),
                let root = object as? [String: Any],
                let sourceSchema = root["source_schema"] as? String, !sourceSchema.isEmpty,
                let namespace = root["translator_namespace"] as? String, !namespace.isEmpty,
                let dictionary = root["dictionary"] as? String, !dictionary.isEmpty,
                let rawSyllables = root["syllables"] as? [String: Any]
            else { return nil }
            let alphabet = root["alphabet"] as? String ?? ""
            let algebra = root["algebra"] as? [String] ?? []
            let separator = root["separator"] as? String ?? " "
            let declaration = root["declaration"] as? String ?? ""
            let prefixDeclaration = root["prefix_declaration"] as? String ?? ""
            let producerClass = root["producer_class"] as? String ?? ""
            var syllables: [ProjectedSyllable] = []
            for (token, value) in rawSyllables {
                guard let entries = value as? [[String: Any]] else { return nil }
                var spellings: [ProjectedSpelling] = []
                for entry in entries {
                    guard let text = entry["text"] as? String else { return nil }
                    let normal =
                        (entry["normal"] as? Bool)
                        ?? ((entry["normal"] as? NSNumber)?.boolValue ?? false)
                    let correction =
                        (entry["correction"] as? Bool)
                        ?? ((entry["correction"] as? NSNumber)?.boolValue ?? false)
                    spellings.append(ProjectedSpelling(text: text, isNormal: normal, isCorrection: correction))
                }
                syllables.append(ProjectedSyllable(token: token, spellings: spellings))
            }
            return SourceProjection(
                sourceSchema: sourceSchema, translatorNamespace: namespace,
                dictionary: dictionary, alphabet: alphabet, algebra: algebra,
                separator: separator, declaration: declaration,
                producerClass: producerClass,
                prefixDeclaration: prefixDeclaration,
                syllables: syllables)
        }
    }

    /// The `keyboard_adapter` capability written at generation time (shares wire key names with the
    /// runtime `SchemaDisplayCapability`). `source_code` carries no `preedit_format`: the source
    /// encoding mode the user asked for must not be polluted by the source's expansion rules.
    struct DisplayCapability: Equatable, Sendable {
        public let version: Int
        public let mode: String
        public let sourceSchema: String
        public let translatorNamespace: String
        public let separator: String
        public let mappingPolicy: String
        /// Companion adapter schema id the capability block belongs to; injected by `generate` per target and at
        /// runtime must equal the actual producer schema id, so a valid block copied to another companion is not trusted.
        public let adapterSchema: String
        /// Tokens with a **unique normal code** only; ambiguous/missing/non-letter tokens are not in this table.
        public let syllables: [String: String]
        /// Internal opaque lock alias mapping (canonical -> alias). Written only when the source can prove it;
        /// the runtime bridge still verifies each alias against a fresh prism and does not trust this table itself.
        public let lockMap: [String: String]
        /// Rejected tokens and reasons (`missing_normal` / `ambiguous_normal` /
        /// `non_alphabetic`), for deploy-time diagnostics only; at runtime these tokens fall back for the whole segment.
        public let rejectedTokens: [String: String]

        public func settingAdapterSchema(_ schemaID: String) -> DisplayCapability {
            DisplayCapability(
                version: version, mode: mode, sourceSchema: sourceSchema,
                translatorNamespace: translatorNamespace, separator: separator,
                mappingPolicy: mappingPolicy, adapterSchema: schemaID,
                syllables: syllables, lockMap: lockMap,
                rejectedTokens: rejectedTokens)
        }

        /// YAML/JSON wire format (key names match the runtime decoding contract; the runtime ignores unknown fields).
        public func wireDictionary() -> [String: Any] {
            var wire: [String: Any] = [
                "version": version,
                "display_mode": mode,
                "source_schema": sourceSchema,
                "translator_namespace": translatorNamespace,
                "separator": separator,
                "mapping_policy": mappingPolicy,
                "adapter_schema": adapterSchema,
                "syllables": syllables,
                "rejected_tokens": rejectedTokens,
            ]
            if !lockMap.isEmpty { wire["lock_map"] = lockMap }
            return wire
        }

        public init(
            version: Int, mode: String, sourceSchema: String,
            translatorNamespace: String, separator: String, mappingPolicy: String,
            adapterSchema: String = "", syllables: [String: String],
            lockMap: [String: String] = [:],
            rejectedTokens: [String: String] = [:]
        ) {
            self.version = version
            self.mode = mode
            self.sourceSchema = sourceSchema
            self.translatorNamespace = translatorNamespace
            self.separator = separator
            self.mappingPolicy = mappingPolicy
            self.adapterSchema = adapterSchema
            self.syllables = syllables
            self.lockMap = lockMap
            self.rejectedTokens = rejectedTokens
        }
    }

    /// Structured result of one generation: capability mapping + per-token rejection reasons.
    struct DisplayCapabilityBuild: Equatable, Sendable {
        public let capability: DisplayCapability
        public let rejections: [DisplayCapabilityRejection]
    }

    /// The **schema-agnostic input-rewrite** declaration (`keyboard_rewrite`). It
    /// is entirely independent of the display capability: a companion whose display
    /// is native still carries this complete, versioned block, and the native bridge
    /// checks it against the live producer before allowing any lock or rewrite.
    ///
    /// Three wire shapes:
    ///   * alias (v2, `bounded_token_alias_rewrite_v2`): `lockMap` maps each source
    ///     token to an opaque internal alias; the runtime re-enumerates every alias
    ///     against the live prism and requires the full-span set to be exactly the
    ///     chosen token.
    ///   * direct (v3, `direct_token_rewrite_v3`): table sources keep their own
    ///     codes as the rewrite target; `directTokens` is a bounded deploy-check
    ///     sample.
    ///   * prefix (v4, `prefix_token_rewrite_v4`): numeric script sources that
    ///     explicitly opted in carry `prefixKeys`, a bounded sample of the
    ///     single-character live prism keys their own grammar adds. The runtime
    ///     proves per segment that each offered key narrows the current code, so
    ///     the rewrite can only constrain the reading.
    struct RewriteCapability: Equatable, Sendable {
        public let version: Int
        public let lock: String
        public let sourceSchema: String
        public let translatorNamespace: String
        public let adapterSchema: String
        /// ALIAS mode (version 2): token → opaque alias. Empty in direct/prefix mode.
        public let lockMap: [String: String]
        /// DIRECT mode (version 3): a bounded deploy-check sample of source codes.
        /// Empty in alias/prefix mode.
        public let directTokens: [String]
        /// PREFIX mode (version 4): a bounded sample of the single-character live
        /// prism keys the companion's letter-class layer adds. Empty otherwise.
        public let prefixKeys: [String]
        /// PREFIX mode (version 4): the grammar-layer version this companion was
        /// generated with. Empty otherwise.
        public let prefixLayer: String

        public init(
            version: Int, lock: String, sourceSchema: String,
            translatorNamespace: String,
            adapterSchema: String, lockMap: [String: String],
            directTokens: [String] = [], prefixKeys: [String] = [],
            prefixLayer: String = ""
        ) {
            self.version = version
            self.lock = lock
            self.sourceSchema = sourceSchema
            self.translatorNamespace = translatorNamespace
            self.adapterSchema = adapterSchema
            self.lockMap = lockMap
            self.directTokens = directTokens
            self.prefixKeys = prefixKeys
            self.prefixLayer = prefixLayer
        }

        public func settingAdapterSchema(_ schemaID: String) -> RewriteCapability {
            RewriteCapability(
                version: version, lock: lock, sourceSchema: sourceSchema,
                translatorNamespace: translatorNamespace,
                adapterSchema: schemaID, lockMap: lockMap,
                directTokens: directTokens, prefixKeys: prefixKeys,
                prefixLayer: prefixLayer)
        }

        /// YAML/JSON wire form. Alias mode emits the validated deterministic
        /// `lock_map`, direct mode the bounded `direct_tokens` sample, prefix mode
        /// the bounded `prefix_keys` + `prefix_layer`.
        public func wireDictionary() -> [String: Any] {
            var wire: [String: Any] = [
                "version": version,
                "lock": lock,
                "adapter_schema": adapterSchema,
                "source_schema": sourceSchema,
                "translator_namespace": translatorNamespace,
            ]
            if !lockMap.isEmpty { wire["lock_map"] = lockMap }
            if !directTokens.isEmpty { wire["direct_tokens"] = directTokens }
            if !prefixKeys.isEmpty {
                wire["prefix_keys"] = prefixKeys
                wire["prefix_layer"] = prefixLayer
            }
            return wire
        }
    }

    struct DisplayCapabilityRejection: Equatable, Sendable {
        public enum Reason: String, Equatable, Sendable {
            /// No final normal non-correction spelling (including erase / uncovered).
            case missingNormal = "missing_normal"
            /// Several final normal non-correction spellings: ambiguous, never pick the first.
            case ambiguousNormal = "ambiguous_normal"
            /// Source code is not pure ASCII letters (e.g. bopomofo): needs a verified source_rendered.
            case nonAlphabetic = "non_alphabetic"
        }
        public let token: String
        public let reason: Reason
        public let detail: String
    }

    enum DisplayCapabilityError: Error, Equatable {
        case emptySourceSchema
        case emptyTokenDomain
        case duplicateToken(String)
        /// Every token was rejected: no provable display capability; an empty capability block must not be written.
        case emptyResolvedDomain
        /// Display separator is empty (especially an explicit override to the empty string).
        case emptySeparator
        /// Whole-domain uniqueness was explicitly required but some tokens were rejected.
        case incompleteDomain([String])
    }

    /// Builds the capability from a verified source projection.
    ///
    /// A token is written only when its final normal non-correction string is **unique**;
    /// ambiguity (e.g. Flyhe `derive/^([jqxy])u$/$1v/` yields two normals ju/jv), missing entries,
    /// erase and non-letter symbols **reject that entry** with a recorded reason. A partial domain
    /// is allowed: at runtime a rejected token makes the whole segment fall back (see
    /// `CompositionDisplayPolicy`), so a partial domain is safe.
    ///
    /// - Parameter displaySeparator: display joiner; when nil, the first character of the source delimiter.
    ///   The apostrophe required for acceptance must be passed explicitly; "same as the source's space separator" is not assumed.
    /// - Parameter wireVersion: `keyboard_adapter/version` written into the wire capability block;
    ///   defaults to `SchemaDisplayCapability.supportedVersion`, matching the runtime's strict decode.
    ///   The generation/invalidation version is expressed separately by `displayGeneratorVersion`; do not mix them.
    static func makeDisplayCapability(
        from projection: SourceProjection,
        wireVersion: Int = SchemaDisplayCapability.supportedVersion,
        displaySeparator: String? = nil,
        requireFullDomain: Bool = false
    )
        throws -> DisplayCapabilityBuild
    {
        guard !projection.sourceSchema.isEmpty else { throw DisplayCapabilityError.emptySourceSchema }
        guard !projection.syllables.isEmpty else { throw DisplayCapabilityError.emptyTokenDomain }
        // Display separator: explicit config wins; default is the first character of the source delimiter. The
        // acceptance apostrophe must be passed explicitly as `'`; it must not claim byte equality with the source's space separator.
        let separator = displaySeparator ?? projection.separator
        guard !separator.isEmpty else { throw DisplayCapabilityError.emptySeparator }

        var seen = Set<String>()
        var resolved: [String: String] = [:]
        var rejections: [DisplayCapabilityRejection] = []
        for syllable in projection.syllables.sorted(by: { $0.token < $1.token }) {
            guard !syllable.token.isEmpty else { throw DisplayCapabilityError.emptyTokenDomain }
            guard seen.insert(syllable.token).inserted else {
                throw DisplayCapabilityError.duplicateToken(syllable.token)
            }
            // Only distinct final normal non-correction strings count; fuzzy/abbrev/correction do not degrade.
            var distinct = Set<String>()
            for spelling in syllable.spellings where spelling.isNormal && !spelling.isCorrection {
                guard !spelling.text.isEmpty else { continue }
                distinct.insert(spelling.text)
            }
            if distinct.isEmpty {
                rejections.append(
                    .init(
                        token: syllable.token, reason: .missingNormal,
                        detail: "no final normal non-correction spelling"))
                continue
            }
            if distinct.count > 1 {
                rejections.append(
                    .init(
                        token: syllable.token, reason: .ambiguousNormal,
                        detail: distinct.sorted().joined(separator: ",")))
                continue
            }
            guard let only = distinct.first, Self.isAsciiLetterCode(only) else {
                rejections.append(
                    .init(
                        token: syllable.token, reason: .nonAlphabetic,
                        detail: distinct.first ?? ""))
                continue
            }
            resolved[syllable.token] = only
        }

        if requireFullDomain, !rejections.isEmpty {
            throw DisplayCapabilityError.incompleteDomain(rejections.map(\.token).sorted())
        }
        guard !resolved.isEmpty else { throw DisplayCapabilityError.emptyResolvedDomain }

        let rejected = Dictionary(uniqueKeysWithValues: rejections.map { ($0.token, $0.reason.rawValue) })
        let capability = DisplayCapability(
            version: wireVersion, mode: "source_code",
            sourceSchema: projection.sourceSchema,
            translatorNamespace: projection.translatorNamespace,
            separator: separator,
            mappingPolicy: "unique_normal",
            syllables: resolved,
            rejectedTokens: rejected)
        return DisplayCapabilityBuild(capability: capability, rejections: rejections.sorted { $0.token < $1.token })
    }

    /// Pure ASCII source code points: letters, or `; ' \`` that compact layouts use (same cap as the
    /// existing adapter alphabet). Non-ASCII such as bopomofo is not source_code and needs source_rendered.
    private static func isAsciiLetterCode(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            let v = scalar.value
            return (v >= 65 && v <= 90) || (v >= 97 && v <= 122) || v == 59 || v == 39 || v == 96
        }
    }

    /// T9 sources explicitly declared as canonical pinyin display: `canonical` joins the native Code
    /// Decode result with the source delimiter, keeping existing semantics, with no preedit_format.
    /// Like `source_code`, `canonical` carries the target `adapter_schema` (injected by `generate`).
    static func canonicalDisplayCapability(
        sourceSchema: String,
        separator: String
    ) -> DisplayCapability {
        DisplayCapability(
            version: SchemaDisplayCapability.supportedVersion, mode: "canonical",
            sourceSchema: sourceSchema,
            translatorNamespace: "translator", separator: separator.isEmpty ? " " : separator,
            mappingPolicy: "", syllables: [:])
    }

    /// Whether the source **explicitly declares** itself a canonical pinyin source. Generation
    /// follows this (a declaration carried by the native product takes priority); canonical must
    /// not be granted when pinyin cannot be proven, falling back to native. The declaration is the
    /// source schema's top-level `keyboard_adapter_source: canonical_pinyin`, which the runtime
    /// also re-reads from the source. Compiled data is read only when the native projection is missing.
    static func declaresCanonicalPinyinSource(projection: SourceProjection) -> Bool {
        projection.declaration == "canonical_pinyin"
    }

    static func declaresCanonicalPinyinSource(compiled: Data) -> Bool {
        guard let text = String(data: compiled, encoding: .utf8),
            let root = try? BoundedYAML.load(yaml: text) as? [String: Any]
        else { return false }
        return (root["keyboard_adapter_source"] as? String) == "canonical_pinyin"
    }

    /// Canonical pinyin token domain check: a `_9` companion may be declared `canonical` only when
    /// **all** syllable tokens of the source's primary Table are standard pinyin syllables. A single
    /// "nihao" candidate oracle cannot prove the whole dictionary is canonical pinyin (counterexample:
    /// token `xx` + `xform/^xx$/nihao/`); non-pinyin tokens are always rejected, never emitting a guessed canonical.
    static func isCanonicalPinyinDomain(_ tokens: [String]) -> Bool {
        guard !tokens.isEmpty else { return false }
        return tokens.allSatisfy(Self.isPinyinSyllable)
    }

    /// Canonical-pinyin domain proof that tolerates the single, evidenced
    /// non-pinyin extra shape real pinyin dictionaries carry (the 26 uppercase
    /// `A`–`Z` abbreviation entries). It is still a domain proof, not a "contains
    /// some pinyin" heuristic: every token must be either a canonical pinyin
    /// syllable or an uppercase-abbreviation extra, and at least one canonical
    /// token is required. Any other token shape (e.g. a shape-code source that
    /// happens to include `ni` plus `english`) is rejected.
    static func isCanonicalPinyinDomainAllowingBenignExtras(_ tokens: [String]) -> Bool {
        guard !tokens.isEmpty else { return false }
        var canonicalCount = 0
        for token in tokens {
            if isCanonicalPinyinToken(token) {
                canonicalCount += 1
            } else if !isUppercaseAbbreviationToken(token) {
                return false
            }
        }
        return canonicalCount > 0
    }

    /// Injects the capability block into existing schema data, binding an explicit `adapterSchema`.
    /// Used by generated companions: first removes any inherited `keyboard_adapter`/`keyboard_rewrite`, then injects
    /// per target; nil keeps native, never inheriting the source's old block.
    ///
    /// DISPLAY and REWRITE are independent:
    ///   * a non-nil `displayCapability` writes `keyboard_adapter` (display capability, may be native);
    ///   * a non-nil `rewriteCapability` writes `keyboard_rewrite` (an independent, schema-agnostic
    ///     input-rewrite capability declaration). Any combination is valid; native display + rewrite is legal.
    static func injectingCapability(
        into compiled: Data, adapterSchema: String,
        displayCapability: DisplayCapability?,
        rewriteCapability: RewriteCapability? = nil
    ) throws -> Data {
        guard let text = String(data: compiled, encoding: .utf8),
            var root = try BoundedYAML.load(yaml: text) as? [String: Any]
        else {
            throw RecipeInstallError.invalidResource("无法重新读取输入方案以添加展示能力")
        }
        // Strip any inherited blocks: a source clone must never carry a stale
        // capability for a different adapter.
        root.removeValue(forKey: "keyboard_adapter")
        root.removeValue(forKey: "keyboard_rewrite")
        if let displayCapability {
            root["keyboard_adapter"] = displayCapability.settingAdapterSchema(adapterSchema).wireDictionary()
        }
        if let rewriteCapability {
            root["keyboard_rewrite"] = rewriteCapability.settingAdapterSchema(adapterSchema).wireDictionary()
        }
        return Data(try Yams.dump(object: root, sortKeys: true).utf8)
    }

    /// Writes capability blocks onto an existing companion schema result.
    ///
    /// `displayCapability == nil` **explicitly removes** the old `keyboard_adapter` block inherited
    /// from the source clone; likewise `rewriteCapability == nil` removes `keyboard_rewrite`. All
    /// generation paths (including migration regeneration) go through this method, so failure means native.
    ///
    /// `sourceProjection` (formerly `canonicalProjection`) is the **only** data source:
    ///   * display: 9-key canonical needs an explicit `canonical_pinyin` declaration + canonical token
    ///     domain; 14-key source_code needs a unique normal code. The display mode itself authorizes no rewrite.
    ///   * rewrite: **script** sources prepend an opaque alias to every token (v2, baked layer equals
    ///     the current domain item by item); **table** sources keep the source code and add
    ///     character-level folding (v3 direct, no per-code alias); **explicit opt-in 9-key digit-code
    ///     script sources** use v4: only a bounded `prefix_keys` sample is declared, and the rewrite
    ///     target is a single character key of the live prism (provided by the companion's own
    ///     abbreviation layer), generating no per-token alias. All three are declared by the independent
    ///     `keyboard_rewrite`, unrelated to display.
    static func generate(
        compiled: Data, sourceID: String, fold compactFold: CompactFold,
        displayCapability: DisplayCapability?,
        sourceProjection: SourceProjection? = nil
    ) throws -> Data {
        // Dispatch on the SAME primary-producer contract `adaptability` uses (read
        // from the compiled schema, not the projection's cached class), so a table
        // source can never be mis-routed into the script generator and a named-only
        // producer can never be judged adaptable and then throw here. A table
        // (shape-code) source uses the bounded DIRECT-code companion: the source
        // codes stay intact and the compact fold is added per letter.
        guard let producer = Self.autoAdaptableProducer(inCompiled: compiled) else {
            throw RecipeInstallError.invalidResource(
                "输入方案缺少默认主转换器，无法自动适配")
        }
        let nineKey = compactFold.isPhoneDigits
        if producer.klass == .table {
            guard let projection = sourceProjection else {
                throw RecipeInstallError.invalidResource("码表适配方案缺少必要数据")
            }
            return try generateTableCompanion(
                compiled: compiled, sourceID: sourceID,
                fold: compactFold, projection: projection)
        }
        // canonical DISPLAY (9-key) still needs the explicit canonical-pinyin
        // declaration; the input-rewrite capability below does not.
        let proven =
            sourceProjection.map {
                declaresCanonicalPinyinSource(projection: $0)
                    && isCanonicalPinyinDomainAllowingBenignExtras($0.syllables.map(\.token))
            } ?? false
        let preserveCanonical = nineKey && proven

        // ---- v4 letter-class prefix layer (explicit, bounded, opt-in) --------
        // Only a 9-key companion of a source that EXPLICITLY opted in, whose own
        // spelling space is a numeric (2–9) code space, qualifies. It replaces the
        // opaque alias layer with a DIRECT rewrite to the live key, so nothing
        // per-token is baked and no key is ever synthesized from a token shape.
        let prefixKeys: [String]? = {
            guard nineKey, let projection = sourceProjection,
                declaresLetterClassPrefixSource(projection),
                isNumericCodeSource(projection)
            else { return nil }
            return letterClassPrefixKeys(projection)
        }()
        let prefixLayerAlreadyPresent = {
            guard let projection = sourceProjection, let keys = prefixKeys else { return false }
            return hasLetterClassKeys(projection, keys: keys)
        }()
        let prefixRewrite = prefixKeys != nil

        // Schema-agnostic alias layer: mint an opaque alias for every token of the
        // source's bounded, exactly-representable token domain, for BOTH the 9- and
        // 14-key companions. No pinyin shape/declaration gate — a shape, Bopomofo,
        // dialect or custom `script_translator` source is treated identically. The
        // alias layer is skipped (legacy output) only when the domain is unbounded
        // or contains a token that cannot be represented exactly. The prefix mode
        // supersedes it for opted-in numeric sources.
        let aliasRewrite =
            !prefixRewrite
            && (sourceProjection.map { tokenAliasDomain($0) != nil } ?? false)
        let prependAlgebra: [String]?
        if prefixRewrite {
            // The abbreviation layer must precede the fold derives so the
            // single-letter key is folded into its digit class too.
            prependAlgebra = prefixLayerAlreadyPresent ? nil : [letterClassPrefixRule]
        } else {
            prependAlgebra = aliasRewrite ? tokenAliasDerives(sourceProjection!) : nil
        }
        let base = try generate(
            compiled: compiled, sourceID: sourceID, fold: compactFold,
            canonicalTelephoneDerive: preserveCanonical,
            prependAlgebra: prependAlgebra,
            extraAlphabet: aliasRewrite ? tokenAliasCharacters(sourceProjection!) : "")
        let target = identifier(sourceID: sourceID, fold: compactFold)
        // The rewrite capability is authorized only when the companion's OWN baked
        // layer is exactly what this generator intended. It is independent of
        // `displayCapability`: a native-display companion still carries a complete,
        // versioned rewrite declaration.
        var rewrite: RewriteCapability?
        if let keys = prefixKeys, let projection = sourceProjection,
            prefixLockAuthorized(
                sourceProjection: projection, companion: base,
                keys: keys, layerAlreadyPresent: prefixLayerAlreadyPresent)
        {
            rewrite = RewriteCapability(
                version: rewriteWireVersionPrefix,
                lock: prefixTokenLockValue,
                sourceSchema: projection.sourceSchema,
                translatorNamespace: projection.translatorNamespace,
                adapterSchema: target,
                lockMap: [:],
                prefixKeys: keys,
                prefixLayer: letterClassPrefixLayerValue)
        } else if aliasRewrite, let projection = sourceProjection,
            tokenAliasLockAuthorized(sourceProjection: projection, companion: base),
            let assignments = tokenAliasAssignmentMap(projection)
        {
            rewrite = RewriteCapability(
                version: rewriteWireVersion,
                lock: tokenAliasLockValue,
                sourceSchema: projection.sourceSchema,
                translatorNamespace: projection.translatorNamespace,
                adapterSchema: target,
                lockMap: assignments)
        }
        return try injectingCapability(
            into: base, adapterSchema: target,
            displayCapability: displayCapability,
            rewriteCapability: rewrite)
    }
}
