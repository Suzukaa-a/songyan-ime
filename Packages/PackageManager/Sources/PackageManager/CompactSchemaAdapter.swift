import CryptoKit
import Foundation
import KeyboardCore
import Yams

/// Generated encoding configuration, kept outside the original recipe source catalog.
/// The original effective algebra is retained in order, then its spelling space is folded.
public enum CompactSchemaAdapter {
    /// The eight standard telephone-digit derives, in canonical rule order. Used
    /// for the 9-key companion of a canonical-pinyin source instead of a
    /// destructive `xlit`: `derive` ADDS the digit spelling while the canonical
    /// pinyin key survives, which is what the `canonical` DISPLAY mode needs. The
    /// input-rewrite capability is independent (see `tokenAliasLockValue`).
    static let telephoneDerives: [String] = [
        "derive/[abc]/2/", "derive/[def]/3/", "derive/[hgi]/4/", "derive/[jkl]/5/",
        "derive/[omn]/6/", "derive/[pqrs]/7/", "derive/[tuv]/8/", "derive/[wxyz]/9/",
    ]

    public static func identifier(sourceID: String, fold: CompactFold) -> String {
        let hash = SHA256.hash(data: Data(sourceID.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        return "keyboard_" + hash + "_" + fold.id
    }

    public static func generate(
        compiled: Data, sourceID: String, fold compactFold: CompactFold,
        canonicalTelephoneDerive: Bool = false,
        prependAlgebra: [String]? = nil,
        extraAlphabet: String = ""
    ) throws -> Data {
        guard compiled.count <= RecipeResourceBudget.sourceFile,
            let text = String(data: compiled, encoding: .utf8),
            var root = try BoundedYAML.load(yaml: text) as? [String: Any],
            var schema = root["schema"] as? [String: Any],
            schema["schema_id"] as? String == sourceID,
            // The SAME primary-producer contract as `adaptability` and the native
            // bridge: this generator adapts ONLY a unique DEFAULT
            // `script_translator`. A table source must go to the table generator
            // (never here), and a named-only producer is not auto-adaptable.
            let producer = Self.autoAdaptableProducer(inCompiled: compiled),
            producer.klass == .script,
            var speller = root["speller"] as? [String: Any],
            var translator = root[producer.namespace] as? [String: Any],
            let dictionary = translator["dictionary"] as? String, !dictionary.isEmpty
        else {
            throw RecipeInstallError.invalidResource("输入方案不是可自动适配的拼音或双拼配置")
        }
        let alphabet = speller["alphabet"] as? String ?? "abcdefghijklmnopqrstuvwxyz"
        // ONE shared physical-alphabet contract, consumed by BOTH `adaptability`
        // and `generate`, so a source can never pass one and fail the other. The
        // fold rules and target alphabet are built from the letters this source
        // ACTUALLY declares (`presentLetters`); a key the source does not have is
        // never invented.
        let foldMap = compactFold.map
        let nineKey = compactFold.isPhoneDigits
        guard let fold = Self.physicalFold(sourceAlphabet: alphabet, fold: compactFold) else {
            throw RecipeInstallError.invalidResource("输入方案的字母表无法适配紧凑键盘布局")
        }
        let presentLetters = Self.foldableLetters.filter { alphabet.contains($0) }
        // Non-letter characters the source declares (pass-through punctuation).
        let sourceExtras = String(alphabet.filter { !presentLetters.contains($0) })
        // Merge over the source's OWN letters only.
        let mergeSource = presentLetters
        let mergeTarget = String(presentLetters.map { foldMap[$0] ?? $0 })
        let target = identifier(sourceID: sourceID, fold: compactFold)
        schema["schema_id"] = target
        schema["name"] = "\(schema["name"] as? String ?? sourceID) · \(compactFold.id)键适配"
        root["schema"] = schema
        // Dictionary default user_dict is the dictionary name, NOT the new schema ID.
        if translator["user_dict"] == nil { translator["user_dict"] = dictionary }
        translator["prism"] = target
        // Typo correction substitutes physical QWERTY neighbours; on merged (14/18) or numeric
        // (9) keys it is meaningless, so a companion never inherits the source's switch.
        if translator[TypoCorrection.configLeaf] != nil { translator[TypoCorrection.configLeaf] = false }
        if !nineKey { Self.addExactTokenPreedit(fold.exactTokenPreedit, to: &translator) }
        // Post-commit prediction (predictor / predict_translator and their config) is inherited
        // as is: it keys on commits, not on the spelling, so compact input predicts the same.
        root[producer.namespace] = translator
        var algebra = speller["algebra"] as? [String] ?? []
        let preserveCanonical = nineKey && canonicalTelephoneDerive
        if let prependAlgebra {
            // Alias layer: inserted BEFORE the untouched source algebra so the
            // merged grammar (and every source key) stays byte-identical. The
            // opaque aliases are digits no source rule is expected to touch; the
            // runtime re-proves each alias against the live prism regardless.
            algebra.insert(contentsOf: prependAlgebra, at: 0)
        }
        if preserveCanonical {
            // Preserve canonical pinyin keys and ADD the telephone digits. A
            // destructive `xlit/a-z/2-9/` would replace the canonical spelling
            // space outright and make an exact-spelling rewrite impossible.
            algebra.append(contentsOf: telephoneDerives)
        } else if !nineKey {
            // Letter groups ADD the folded spelling per letter and keep the source
            // letters, so a key's exact letter (picked by a sideways swipe) still
            // spells. Every key sends a fold fixpoint, so tapped input matches exactly
            // the spellings the old destructive merge produced; partial folds need an
            // unfolded letter, which only an exact pick sends. The key's own letter is
            // its tap code, so its exact pick sends a token derived from that letter
            // alone, ahead of the fold. Lowercase only: the merge never folded a
            // source's uppercase abbreviation keys either.
            algebra.append(contentsOf: fold.exactTokenRules)
            algebra.append(
                contentsOf: mergeSource.compactMap { letter in
                    guard let folded = foldMap[letter], folded != letter else { return nil }
                    return "derive/\(letter)/\(folded)/"
                })
        } else {
            // Digit merge for a non-canonical 9-key source. For the alias layer this is
            // REQUIRED (it turns the source codes into the numeric codes); the
            // prepended aliases are digit-only so it cannot touch them.
            algebra.append("xlit/\(mergeSource)/\(mergeTarget)/")
        }
        speller["algebra"] = algebra
        // The companion alphabet is the union of the compact physical keys, the
        // source's own (present) letters, its pass-through punctuation, and the
        // alias characters when the alias layer is used. No inventing: only keys
        // that exist in the source or in the compact layout are accepted.
        let typeable = String(
            Set(fold.typeableAlphabet)
                .union(Set(sourceExtras))
                .union(Set(extraAlphabet)).sorted())
        speller["alphabet"] = typeable
        speller["initials"] = typeable
        root["speller"] = speller
        // A bare numeric spelling must reach abc_segmentor, not a number recognizer.
        // Sample the 9-key digit alphabet generically (single digits AND multi-digit
        // runs) so no particular word/code is hardcoded. On letter groups an exact
        // token, alone or after a letter, must not read as an email or similar either.
        let digits = "23456789"
        let samples =
            nineKey
            ? Array(digits).map(String.init)
                + [String(digits), String(digits.prefix(2)), String(digits.prefix(5))]
            : fold.exactTokens.flatMap { [String($0), "a\($0)"] }
        if !samples.isEmpty, var recognizer = root["recognizer"] as? [String: Any],
            var patterns = recognizer["patterns"] as? [String: String]
        {
            for (name, pattern) in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern) else {
                    throw RecipeInstallError.invalidResource("无法检查识别规则：\(name)")
                }
                if samples.contains(where: {
                    regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil
                }) {
                    patterns.removeValue(forKey: name)
                }
            }
            recognizer["patterns"] = patterns
            root["recognizer"] = recognizer
        }
        // Numeric candidate shortcuts must not consume the adapter's composition keys.
        if nineKey, var binder = root["key_binder"] as? [String: Any],
            let bindings = binder["bindings"] as? [[String: Any]]
        {
            binder["bindings"] = bindings.filter {
                guard let accept = $0["accept"] as? String else { return true }
                return !Set("23456789").contains(Character(accept.count == 1 ? accept : "\0"))
            }
            root["key_binder"] = binder
        }
        root.removeValue(forKey: "__build_info")
        return Data(try Yams.dump(object: root, sortKeys: true).utf8)
    }
}
