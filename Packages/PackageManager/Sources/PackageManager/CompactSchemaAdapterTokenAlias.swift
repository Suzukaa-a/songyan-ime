import Foundation
import KeyboardCore
import Yams

public extension CompactSchemaAdapter {
    // MARK: - Bounded token alias layer (schema-agnostic)
    //
    // THE DISAMBIGUATION AUTHORITY IS THE ENGINE, NOT THIS GENERATOR. The bridge
    // enumerates exactly the interpretations the active schema's live
    // prism/segment graph proves for the current `abc` segment, and `apply`
    // re-proves every offered option against that same live prism. This section
    // only supplies an OPAQUE, deterministic rewrite target per token so a chosen
    // interpretation can be written back into the raw input.
    //
    // It is deliberately schema-agnostic: pinyin, double-pinyin, shape codes
    // (Wubi/Cangjie), Bopomofo, dialect or custom `script_translator` syllables
    // are handled identically. Authorization never inspects whether a token
    // "looks like" pinyin and never requires a `canonical_pinyin` declaration; it
    // relies on (a) an explicitly generated capability, (b) an unforgeable
    // adapter/source binding, (c) a finite, deterministic, prefix-free alias
    // domain, and (d) exact escaping (or fail-closed) for every token, with the
    // runtime live-prism re-proof as the final safety anchor.
    //
    // The alias is `9` + a deterministic zero-padded index over the SORTED token
    // domain, prepended as `derive/^<escaped token>$/9<index>/` BEFORE the source
    // algebra. The physical key caps never send it; only the bridge rewrite does,
    // and the runtime refuses any alias that does not enumerate to exactly the
    // chosen token.

    /// Alias lock (script sources): `lock_map` maps each token to its opaque alias.
    static let tokenAliasLockValue = "bounded_token_alias_rewrite_v2"
    /// Direct-code lock (table sources). No lock_map; the token is its own target.
    static let directTokenLockValue = "direct_token_rewrite_v3"
    /// Letter-class PREFIX lock (numeric script sources that explicitly opted in).
    /// No lock_map and no per-token metadata: a bounded sample of single-character
    /// live prism keys, each re-proven per segment to NARROW the typed code.
    static let prefixTokenLockValue = "prefix_token_rewrite_v4"
    /// Wire version of the `keyboard_rewrite` block in alias mode.
    static let rewriteWireVersion = 2
    /// Wire version of the `keyboard_rewrite` block in direct mode.
    static let rewriteWireVersionDirect = 3
    /// Wire version of the `keyboard_rewrite` block in prefix mode.
    static let rewriteWireVersionPrefix = 4

    // MARK: - Letter-class prefix layer (v4)
    //
    // The compact keypad question: on a 9-key layout the digit `2` physically
    // means a/b/c, so a long press should be able to say "the first letter is b"
    // and have that choice CONSTRAIN the encoding instead of merely labelling a
    // key. That needs a grammar in which a single letter is a real prism key whose
    // meaning is the letter class — which is exactly librime's abbreviation
    // calculus (`abbrev/^([a-z]).+$/$1/`, the same layer the upstream rime-ice t9
    // scheme uses for super-abbreviated pinyin).
    //
    // This is deliberately NOT a general upgrade of every script source:
    //   * the SOURCE must explicitly opt in with `keyboard_rewrite_prefix`
    //     so no upstream scheme is silently
    //     rewritten and no already-installed companion changes meaning;
    //   * the source must be a numeric (2–9) code space over a unique default
    //     `script_translator` — the shape a compact digital layout actually types;
    //   * the layer is added to the GENERATED companion only, never to the source,
    //     and only when the source's own prism does not already provide the
    //     letter keys (so a scheme that already has abbreviated pinyin keeps its own grammar);
    //   * the wire capability is versioned (v4) and bounded: the declared
    //     `prefix_keys` sample is regenerated and re-proven live at deploy time,
    //     and every runtime option is re-proven per segment against the live prism.
    //
    // Nothing here hardcodes "abc": the option set is derived from the live prism
    // interpretation sets, and the sampled keys are the real first letters of the
    // source's own token inventory.

    /// The grammar-layer version a v4 companion declares.
    static let letterClassPrefixLayerValue = "letter_class_v1"
    /// The bounded abbreviation rule that turns every first letter into a live
    /// prism key for its letter class. Applied to the source's canonical letter
    /// spellings BEFORE the compact fold, so the single-letter key is folded into
    /// its digit class too (that is what makes `b` a narrowing of `2`).
    static let letterClassPrefixRule = "abbrev/^([a-z]).+$/$1/"
    /// Versioned hard cap on the sampled prefix keys (at most the 26 Latin
    /// letters). Exceeding it is unsupported (no v4 capability) rather than
    /// truncated.
    static let letterClassPrefixKeyLimit = 26

    /// The source's explicit opt-in (`keyboard_rewrite_prefix`).
    static func declaresLetterClassPrefixSource(_ projection: SourceProjection) -> Bool {
        projection.prefixDeclaration == letterClassPrefixLayerValue
    }

    /// The bounded key sample for a projection: the distinct lowercase-ASCII first
    /// letters of the source's OWN token inventory, sorted. Derived entirely from
    /// the real token domain; nil (fail closed) when there is none or the domain
    /// exceeds the versioned cap.
    static func letterClassPrefixKeys(_ projection: SourceProjection) -> [String]? {
        var keys = Set<String>()
        for syllable in projection.syllables {
            guard let first = syllable.token.first, first.isASCII,
                first >= "a", first <= "z"
            else { continue }
            keys.insert(String(first))
        }
        guard !keys.isEmpty, keys.count <= letterClassPrefixKeyLimit else { return nil }
        return keys.sorted()
    }

    /// Whether the source's own prism ALREADY provides every class key, judged on
    /// the real projection (some token has that exact single-letter spelling). When
    /// it does, the companion inherits the grammar and no rule is added.
    static func hasLetterClassKeys(
        _ projection: SourceProjection,
        keys: [String]
    ) -> Bool {
        var provided = Set<String>()
        for syllable in projection.syllables {
            for spelling in syllable.spellings where spelling.isNormal && !spelling.isCorrection {
                provided.insert(spelling.text)
            }
        }
        return keys.allSatisfy { provided.contains($0) }
    }

    /// Authorization for a generated v4 companion: the SAME structural contract as
    /// the alias path (the companion's own declaration must be exactly the
    /// capability the caller is about to write), plus the bounded key sample must
    /// be accepted by the companion's alphabet/initials so a rewritten key can
    /// re-syllabify. The runtime re-proves liveness live; this only keeps the
    /// generator from writing a capability its own product cannot support.
    static func prefixLockAuthorized(
        sourceProjection: SourceProjection?,
        companion: Data, keys: [String],
        layerAlreadyPresent: Bool
    ) -> Bool {
        guard let projection = sourceProjection,
            declaresLetterClassPrefixSource(projection),
            !keys.isEmpty, keys.count <= letterClassPrefixKeyLimit,
            let text = String(data: companion, encoding: .utf8),
            let root = try? BoundedYAML.load(yaml: text) as? [String: Any],
            let speller = root["speller"] as? [String: Any],
            let alphabet = speller["alphabet"] as? String
        else { return false }
        let initials = (speller["initials"] as? String) ?? alphabet
        let algebra = (speller["algebra"] as? [String]) ?? []
        let hasRule = algebra.contains(letterClassPrefixRule)
        if !hasRule && !layerAlreadyPresent { return false }
        return keys.allSatisfy { key in
            key.allSatisfy { alphabet.contains($0) && initials.contains($0) }
        }
    }

    /// Alias prefix. Two characters on purpose: the `0` makes every alias contain
    /// a character that NO compact physical layout emits (14-key sends letters,
    /// 9-key sends 2–9), so an alias can never be produced by typing. The rest of
    /// the alias is a fixed-width zero-padded index.
    static let tokenAliasSentinel = "90"

    /// Versioned hard cap on the alias domain. The alias layer maps the schema's
    /// own primary token inventory one-to-one; it never enumerates combinations.
    /// A domain larger than this is explicitly unsupported (no alias layer, no
    /// capability) rather than truncated.
    ///
    /// 4096 is chosen from measured real resources: the largest observed
    /// single-`script_translator` syllabary is Cantonese Jyutping at 2166 tokens;
    /// Bopomofo/Terra-Pinyin are ~1300; Mandarin pinyin ~400–500. 4096 gives
    /// headroom while keeping the added `derive` rules + prism keys bounded
    /// (~0.1–0.2 MB of prism for a full 4096-token domain), which is acceptable
    /// for an on-device companion.
    static let tokenAliasLimit = 4096
    /// Minimum index width (kept >= 1 so the alias is at least `90` + 1 digit).
    static let tokenAliasMinWidth = 1

    /// Fixed index width for a domain of `count` tokens: enough decimal digits for
    /// `count - 1`, so the alias set is equal-length (hence prefix-free) and
    /// distinct. Deterministic in the domain size.
    static func tokenAliasWidth(for count: Int) -> Int {
        max(tokenAliasMinWidth, String(max(0, count - 1)).count)
    }

    /// Whether a scalar can be represented exactly in an algebra rule. The
    /// librime algebra parser splits a rule on the first non-lowercase-letter
    /// character (`/`), so a `/` inside a token is unrecoverable; whitespace and
    /// control characters would break the rule and the syllabary tokenization. A
    /// domain containing any of them fails closed (no partial map).
    private static func isRepresentableTokenScalar(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "/" { return false }
        if scalar.value < 0x20 || scalar.value == 0x7F { return false }
        if scalar.properties.isWhitespace { return false }
        return true
    }

    /// Regex metacharacters escaped in the anchored LHS (boost::regex Perl
    /// syntax). Escaping keeps a token with punctuation exactly expressible; the
    /// runtime re-proof still refuses any alias that does not enumerate to exactly
    /// the token, so a wrong escape fails closed instead of mislocking.
    private static let aliasPatternMetacharacters: Set<Unicode.Scalar> =
        [".", "^", "$", "|", "(", ")", "[", "]", "{", "}", "*", "+", "?", "\\"]

    /// `^<regex-escaped token>$`, or nil when the token cannot be represented
    /// exactly. Returning nil fails the WHOLE domain closed — never a partial map.
    static func aliasPattern(for token: String) -> String? {
        guard !token.isEmpty else { return nil }
        var out = "^"
        for scalar in token.unicodeScalars {
            guard isRepresentableTokenScalar(scalar) else { return nil }
            if aliasPatternMetacharacters.contains(scalar) { out.unicodeScalars.append("\\") }
            out.unicodeScalars.append(scalar)
        }
        out += "$"
        return out
    }

    /// Inverse of `aliasPattern` for an already-escaped LHS body (without the
    /// `^`/`$` anchors). Returns the token only when re-escaping reproduces the
    /// input byte-for-byte, so a hand-edited/foreign rule is never trusted.
    static func aliasToken(fromPattern pattern: String) -> String? {
        var token = String.UnicodeScalarView()
        let scalars = Array(pattern.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\\" {
                index += 1
                guard index < scalars.count else { return nil }
                token.append(scalars[index])
            } else {
                token.append(scalar)
            }
            index += 1
        }
        let value = String(token)
        guard aliasPattern(for: value) == "^" + pattern + "$" else { return nil }
        return value
    }

    // MARK: - 14-key internal lock alias
    //
    // The 14-key merged code is ambiguous (`ug` = {chang,cheng,shang,sheng}), and
    // the double-pinyin source codes are not unique either (`sheng`'s source code
    // is `ug` itself). So instead of trusting a source code, we mint an INTERNAL,
    // OPAQUE alias per canonical token and lock to that.
    //
    // The alias is `9` + a deterministic zero-padded index over the SORTED primary
    // canonical tokens (bounded by the token count). It is inserted as
    // `derive/^<canonical>$/9<index>/` BEFORE the source algebra; the digits are
    // not touched by any letter-based `xform`/`xlit` (verified on real librime:
    // all aliases resolve uniquely and the merged key set is unchanged). The
    // physical 14 keys never send these characters; only the bridge rewrite does.
    //
    // The runtime NEVER trusts the map alone: it re-enumerates each alias and
    // locks only when the alias' full-span set is exactly the chosen canonical.

    /// Bounded, SCHEMA-AGNOSTIC probes derived purely from the real source
    private static let numericSpellingDigits: Set<Character> = Set("23456789")

    /// Whether the source's OWN spellings already form a numeric (2–9) code space,
    /// i.e. EVERY primary token has at least one final normal non-correction
    /// spelling that is a bare numeric code. Scans the COMPLETE projection (never a
    /// prefix and never sorted-order dependent), so registering a native numeric
    /// scheme cannot depend on token or spelling order. The semantics are explicit:
    /// a source is a numeric scheme iff that predicate holds for every token.
    static func isNumericCodeSource(_ projection: SourceProjection) -> Bool {
        guard !projection.syllables.isEmpty else { return false }
        for syllable in projection.syllables {
            let numeric = syllable.spellings.contains { spelling in
                spelling.isNormal && !spelling.isCorrection
                    && !spelling.text.isEmpty
                    && spelling.text.allSatisfy(numericSpellingDigits.contains)
                    && spelling.text.unicodeScalars.allSatisfy { $0.isASCII }
            }
            if !numeric { return false }
        }
        return true
    }

    /// The bounded, deterministic alias domain: every primary token, sorted. nil
    /// (fail closed) when the domain is empty, over the versioned hard limit, has
    /// a duplicate, or contains a token that cannot be represented exactly.
    static func tokenAliasDomain(_ projection: SourceProjection) -> [String]? {
        let tokens = projection.syllables.map(\.token)
        guard !tokens.isEmpty, tokens.count <= tokenAliasLimit else { return nil }
        let sorted = tokens.sorted()
        guard Set(sorted).count == sorted.count else { return nil }  // duplicate token
        for token in sorted where aliasPattern(for: token) == nil { return nil }
        return sorted
    }

    /// Deterministic, bounded alias assignment. Empty when the domain is not
    /// aliasable (callers must treat that as unauthorized).
    static func tokenAliasAssignments(_ projection: SourceProjection)
        -> [(token: String, alias: String)]
    {
        guard let domain = tokenAliasDomain(projection) else { return [] }
        let width = tokenAliasWidth(for: domain.count)
        return domain.enumerated().map { index, token in
            (token, tokenAliasSentinel + String(format: "%0\(width)d", index))
        }
    }

    /// A canonical token is non-empty lowercase ASCII letters, length bounded, and
    /// a standard pinyin syllable. This is the ONLY shape allowed to be spliced
    /// into a `derive/^token$/.../` rule, so no regex metacharacter can enter.
    static func isCanonicalPinyinToken(_ token: String) -> Bool {
        guard !token.isEmpty, token.utf8.count <= 6,
            token.allSatisfy({ $0 >= "a" && $0 <= "z" })
        else { return false }
        return isPinyinSyllable(token)
    }

    /// The ONLY non-pinyin token shape this generator tolerates: a single ASCII
    /// uppercase abbreviation letter (`A`–`Z`). This is the evidenced shape of the
    /// 26 extras carried by the real rime-ice `double_pinyin_flypy` primary Table
    /// (native projection fixture: 440 tokens, `A`–`Z` all present). It is
    /// deliberately minimal — a multi-character or mixed-case token (`english`,
    /// `ABC123`, `Ni`) is NOT benign, so a foreign/shape schema that happens to mix
    /// a few pinyin-like tokens into a larger non-pinyin domain is still refused.
    /// Extras are display-only and never spliced into a `derive` rule.
    static func isUppercaseAbbreviationToken(_ token: String) -> Bool {
        guard token.utf8.count == 1, let scalar = token.unicodeScalars.first else { return false }
        return scalar.value >= 0x41 && scalar.value <= 0x5A  // 'A'...'Z'
    }

    /// Extracts an already-baked alias layer from a companion's `speller/algebra`.
    /// Used when a companion is re-injected after a dictionary change so the baked
    /// domain is preserved instead of re-derived against a different live token
    /// set. Returns nil (fail closed) unless the map is non-empty, bounded, has
    /// unique token/alias entries, and every entry round-trips through
    /// `aliasPattern`/`aliasToken`. Non-alias `derive` rules are skipped.
    static func existingAliasMap(from companion: Data) -> [String: String]? {
        guard let text = String(data: companion, encoding: .utf8),
            let root = try? BoundedYAML.load(yaml: text) as? [String: Any],
            let speller = root["speller"] as? [String: Any],
            let algebra = speller["algebra"] as? [String]
        else { return nil }
        var map: [String: String] = [:]
        var width: Int?
        for rule in algebra {
            guard rule.hasPrefix("derive/^"), rule.hasSuffix("/") else { continue }
            let body = rule.dropFirst("derive/^".count).dropLast()
            // A literal `$` in a token is escaped, so the first unescaped `$/`
            // marks the end of the anchored pattern.
            guard let anchor = body.range(of: "$/") else { continue }
            let alias = String(body[anchor.upperBound...])
            guard alias.hasPrefix(tokenAliasSentinel),
                alias.dropFirst(tokenAliasSentinel.count).allSatisfy(\.isNumber),
                alias.count > tokenAliasSentinel.count
            else { continue }
            let thisWidth = alias.count - tokenAliasSentinel.count
            if let width, width != thisWidth { return nil }  // ragged widths fail closed
            width = thisWidth
            guard let token = aliasToken(fromPattern: String(body[..<anchor.lowerBound])) else {
                return nil  // malformed alias rule -> fail closed
            }
            guard map[token] == nil else { return nil }  // duplicate token
            map[token] = alias
        }
        guard !map.isEmpty, map.count <= tokenAliasLimit,
            Set(map.values).count == map.count
        else { return nil }
        return map
    }

    /// `derive/^<escaped token>$/9<index>/`, prepended before the source algebra.
    static func tokenAliasDerives(_ projection: SourceProjection) -> [String] {
        tokenAliasAssignments(projection).compactMap { assignment in
            aliasPattern(for: assignment.token).map { "derive/\($0)/\(assignment.alias)/" }
        }
    }

    /// The distinct characters the aliases need in `speller/alphabet`/`initials`.
    static func tokenAliasCharacters(_ projection: SourceProjection) -> String {
        String(Set(tokenAliasAssignments(projection).flatMap { $0.alias }).sorted())
    }

    /// The token→alias map for the deterministic assignment. `nil` when the domain
    /// is not aliasable. Also folds in exact `Dictionary` construction so callers
    /// can compare a baked map with `==`.
    static func tokenAliasAssignmentMap(_ projection: SourceProjection) -> [String: String]? {
        guard let domain = tokenAliasDomain(projection) else { return nil }
        var map: [String: String] = [:]
        let width = tokenAliasWidth(for: domain.count)
        for (index, token) in domain.enumerated() {
            map[token] = tokenAliasSentinel + String(format: "%0\(width)d", index)
        }
        return map
    }

    /// Legacy name kept for callers/tests: the deterministic assignment map.
    static func lockMap(_ projection: SourceProjection) -> [String: String] {
        tokenAliasAssignmentMap(projection) ?? [:]
    }

    /// Authorization for the versioned alias rewrite. It is INDEPENDENT of the
    /// display mode and of any pinyin-specific proof: a shape/dialect/Bopomofo
    /// source is authorized exactly like a pinyin one. It requires an EXACT
    /// domain/map binding, so any added/removed token, wrong alias, or a companion
    /// generated for a different source fails closed:
    ///   1. the live projection yields a bounded, duplicate-free, exactly
    ///      representable alias domain;
    ///   2. the companion's baked alias map EQUALS the current deterministic
    ///      assignment (same keys, same aliases, same count) — not merely overlaps;
    ///   3. the companion prepends exactly `derive/^token$/alias/` for every entry
    ///      and its alphabet AND initials accept every alias character.
    /// The runtime additionally re-validates the adapter binding and re-enumerates
    /// every alias from the live prism (the real trust anchor).
    static func tokenAliasLockAuthorized(
        sourceProjection: SourceProjection?,
        companion: Data
    ) -> Bool {
        guard let projection = sourceProjection,
            let expected = tokenAliasAssignmentMap(projection), !expected.isEmpty
        else { return false }
        guard let baked = existingAliasMap(from: companion), baked == expected else { return false }
        guard let text = String(data: companion, encoding: .utf8),
            let root = try? BoundedYAML.load(yaml: text) as? [String: Any],
            let speller = root["speller"] as? [String: Any],
            let alphabet = speller["alphabet"] as? String
        else { return false }
        let initials = (speller["initials"] as? String) ?? alphabet
        let algebra = (speller["algebra"] as? [String]) ?? []
        for (token, alias) in expected {
            guard let pattern = aliasPattern(for: token),
                algebra.contains("derive/\(pattern)/\(alias)/")
            else { return false }
            guard alias.allSatisfy({ alphabet.contains($0) && initials.contains($0) })
            else { return false }
        }
        return true
    }

    private static let pinyinInitials = [
        "zh", "ch", "sh", "b", "p", "m", "f", "d", "t", "n",
        "l", "g", "k", "h", "j", "q", "x", "r", "z", "c", "s",
    ]
    private static let pinyinFinals: Set<String> = [
        "a", "o", "e", "ai", "ei", "ao", "ou", "an", "en", "ang", "eng", "ong", "er",
        "i", "ia", "ie", "iao", "iu", "ian", "in", "iang", "ing", "iong",
        "u", "ua", "uo", "uai", "ui", "uan", "un", "uang", "ueng",
        "v", "ve", "van", "vn", "ue",
    ]
    private static let jqxFinals: Set<String> = [
        "i", "ia", "ie", "iao", "iu", "ian", "in", "iang", "ing", "iong",
        "u", "ue", "uan", "un", "v", "ve", "van", "vn",
    ]
    private static let pinyinStandalone: Set<String> = [
        "a", "o", "e", "ai", "ei", "ao", "ou", "an", "en", "ang", "eng", "er",
        "yi", "ya", "ye", "yo", "yao", "you", "yan", "yin", "yang", "ying", "yong",
        "wu", "wa", "wo", "wai", "wei", "wan", "wen", "wang", "weng",
        "yu", "yue", "yuan", "yun", "m", "n", "ng", "hm", "hng",
    ]

    /// Structure check: a zero-initial syllable must be on the allowlist; otherwise take the longest
    /// valid initial and the remainder must be a valid final (j/q/x have extra final restrictions, ruling out shape-code tokens like `xx`).
    internal static func isPinyinSyllable(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 6 else { return false }
        guard value.allSatisfy({ $0.isASCII && $0.isLowercase }) else { return false }
        if pinyinStandalone.contains(value) { return true }
        for initial in pinyinInitials where value.hasPrefix(initial) {
            let final = String(value.dropFirst(initial.count))
            guard !final.isEmpty else { continue }
            if ["j", "q", "x"].contains(initial) {
                return jqxFinals.contains(final)
            }
            if pinyinFinals.contains(final) { return true }
        }
        return false
    }
}
