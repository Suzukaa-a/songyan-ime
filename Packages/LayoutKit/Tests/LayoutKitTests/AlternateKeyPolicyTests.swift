import XCTest

@testable import LayoutKit

/// The pure long-press alternate policy: the set of options, their order, their
/// explicit `code` / `literal` semantics and the alphabet/full-width gates.
/// Nothing here touches the panel; these are the rules the single later wiring
/// call site will consume.
final class AlternateKeyPolicyTests: XCTestCase {

    private let fullAlphabet = "abcdefghijklmnopqrstuvwxyz"
    /// A representative-only 14-key alphabet: merged representatives + digits only.
    private let clover14Alphabet = "0123456789abcdegjlmoqtuz"

    private func options(
        key: String,
        mergedGroup: String? = nil,
        secondary: [String] = [],
        page: AlternateKeyPolicy.Page = .letters,
        language: AlternateKeyPolicy.Language = .chinese,
        uppercase: Bool = false,
        asciiPunctuation: Bool = false,
        alphabet: String = ""
    ) -> [AlternateKeyPolicy.Option] {
        AlternateKeyPolicy.options(
            for: .init(
                keyLabel: key,
                mergedGroup: mergedGroup,
                secondaryLiterals: secondary,
                page: page,
                language: language,
                isUppercase: uppercase,
                usesASCIIPunctuation: asciiPunctuation,
                schemaAlphabet: alphabet))
    }

    private func bundled(_ key: String) -> [String] {
        AlternateKeyPolicy.defaultLetterLiterals(for: key)
    }

    // MARK: 26-key letters keep their declared digits/symbols

    func testChineseLetterKeepsItsDigitsAndSymbolsInOrder() {
        // Top-row defaults keep their digit first, without repeated @ options.
        let q = options(key: "q", secondary: bundled("q"), language: .chinese, alphabet: fullAlphabet)
        XCTAssertEqual(q, [.init(label: "1", payload: .literal("1"))])
        // The letters the bundled data leaves without a digit still emit the
        // declared digit+symbol pair — the policy never drops them.
        let a = options(key: "a", secondary: ["1", "@"], language: .chinese, alphabet: fullAlphabet)
        XCTAssertEqual(a.map(\.label), ["1", "@"])
        XCTAssertTrue(a.allSatisfy { $0.payload == .literal($0.label) })
    }

    func testChineseLetterPreservesExplicitDIYAccentSecondaries() {
        let a = options(
            key: "a", secondary: ["á", "à", "â", "ä"], language: .chinese,
            alphabet: fullAlphabet)
        XCTAssertEqual(a.map(\.label), ["á", "à", "â", "ä"])
        XCTAssertTrue(a.allSatisfy { $0.payload == .literal($0.label) })
        let mixed = options(
            key: "a", secondary: ["1", "á", "@"], language: .chinese,
            alphabet: fullAlphabet)
        XCTAssertEqual(mixed.map(\.label), ["1", "á", "@"])
    }

    func testTheFirstOptionIsTheKeyFaceHint() {
        // The panel renders `alternates.first` as the key hint, so the policy must
        // put the declared digit first on every 26-key letter.
        for letter in "qwertyuiop".map(String.init) {
            let first = options(
                key: letter, secondary: bundled(letter),
                language: .chinese, alphabet: fullAlphabet
            ).first
            XCTAssertEqual(
                first?.label, bundled(letter).first,
                "\(letter) must hint its digit")
        }
    }

    func testChineseLetterWithoutDeclaredSecondariesOffersNothing() {
        // Missing layout data is a fail-closed gap, never a fabricated pinyin form.
        for letter in ["q", "a", "e", "z"] {
            XCTAssertTrue(options(key: letter, language: .chinese, alphabet: fullAlphabet).isEmpty)
        }
    }

    func testEnglishLetterKeepsOnlyExplicitOptions() {
        let a = options(key: "a", secondary: ["1", "@"], language: .english, alphabet: fullAlphabet)
        XCTAssertEqual(a.map(\.label), ["1", "@"])
        let e = options(key: "e", secondary: ["3", "@"], language: .english, alphabet: fullAlphabet)
        XCTAssertEqual(e.map(\.label), ["3", "@"])
        for letter in fullAlphabet.map(String.init) {
            XCTAssertTrue(options(key: letter, language: .english).isEmpty)
            XCTAssertTrue(options(key: letter, language: .chinese).isEmpty)
        }
    }

    func testEnglishShiftUppercasesExplicitLettersButNeverDigitsSymbols() {
        let upper = options(
            key: "a", secondary: ["1", "@", "á", "é", "ß"], language: .english,
            uppercase: true, alphabet: fullAlphabet)
        XCTAssertEqual(upper.map(\.label), ["1", "@", "Á", "É", "ß"])
        XCTAssertTrue(upper.allSatisfy { $0.payload == .literal($0.label) })
    }

    func testEveryDefaultLetterHasUsefulSymbolsWithoutAccents() {
        for letter in fullAlphabet.map(String.init) {
            let values = bundled(letter)
            XCTAssertFalse(values.isEmpty)
            XCTAssertEqual(values, bundled(letter.uppercased()))
            XCTAssertFalse(values.contains(where: AlternateKeyPolicy.containsNonASCIILetter))
            for language in [AlternateKeyPolicy.Language.chinese, .english] {
                let result = options(
                    key: letter, secondary: values, language: language,
                    asciiPunctuation: language == .english)
                XCTAssertFalse(result.isEmpty)
                XCTAssertTrue(result.allSatisfy { $0.payload == .literal($0.label) })
                if language == .english {
                    XCTAssertTrue(result.allSatisfy { AlternateKeyPolicy.isASCIIWidth($0.label) })
                }
            }
        }
        for (letter, digit) in zip("qwertyuiop", "1234567890") {
            XCTAssertEqual(bundled(String(letter)), [String(digit)])
        }
        XCTAssertEqual(options(key: "d", secondary: bundled("d")).map(\.label), ["？", "?"])
        XCTAssertEqual(options(key: "f", secondary: bundled("f")).map(\.label), ["！", "!"])
        let asciiMarks = Set(
            fullAlphabet.flatMap { letter in
                options(
                    key: String(letter), secondary: bundled(String(letter)), language: .english,
                    asciiPunctuation: true
                ).map(\.label)
            })
        for mark in [",", ".", "?", "!", "@", "/", "\\", ":", ";", "-", "_", "(", ")", "[", "]", "<", ">", "\"", "'"] {
            XCTAssertTrue(asciiMarks.contains(mark), "Missing everyday symbol \(mark)")
        }
        XCTAssertTrue(bundled("ABC").isEmpty)
    }

    /// A symbol reachable from two letters reads as a mistake on the key faces (G and M
    /// both showed `/` on the ABC page), so every offered symbol belongs to one letter in
    /// Chinese mode, English mode and ASCII fields alike.
    func testNoTwoLettersOfferTheSameSymbolInAnyMode() {
        let modes: [(AlternateKeyPolicy.Language, Bool)] = [(.chinese, false), (.chinese, true), (.english, true)]
        for (language, ascii) in modes {
            var owner: [String: String] = [:]
            var hints: [String: String] = [:]
            for letter in fullAlphabet.map(String.init) {
                let labels = options(
                    key: letter, secondary: bundled(letter), language: language,
                    asciiPunctuation: ascii, alphabet: fullAlphabet
                ).map(\.label)
                for label in labels {
                    if let other = owner[label] {
                        XCTFail("\(language) ascii=\(ascii): \(label) on both \(other) and \(letter)")
                    }
                    owner[label] = letter
                }
                // The corner glyph is the first option; it must be unique too.
                if let hint = labels.first {
                    XCTAssertNil(hints[hint], "\(language) ascii=\(ascii): hint \(hint) repeats on \(letter)")
                    hints[hint] = letter
                }
            }
        }
    }

    /// The merged pads' own declared extras (14-key QW `1 !`, single L `，`, single M `。`)
    /// must not repeat one another either.
    func testMergedPadDeclaredSymbolsDoNotRepeat() {
        for layout in [BuiltinLayouts.merged14, BuiltinLayouts.merged18] {
            var seen: [String: String] = [:]
            for key in layout.rows.flatMap(\.keys) where key.action.type == .code {
                let partners = Set(key.label.lowercased().map(String.init))
                let symbols = (key.longPress ?? []).compactMap(\.action.value).filter { !partners.contains($0) }
                for symbol in symbols {
                    XCTAssertNil(seen[symbol], "\(layout.id): \(symbol) on \(seen[symbol] ?? "") and \(key.label)")
                    seen[symbol] = key.label
                }
            }
        }
    }

    func testExplicitDIYAccentsHaveMatchingLabelAndLiteral() {
        let lower = options(key: "a", secondary: ["á"], language: .english)
        let upper = options(key: "a", secondary: ["á"], language: .english, uppercase: true)
        XCTAssertEqual(lower, [.init(label: "á", payload: .literal("á"))])
        XCTAssertEqual(upper, [.init(label: "Á", payload: .literal("Á"))])
    }

    // MARK: 14-key partners gated by the schema alphabet

    func testClover14RepresentativeOnlyAlphabetHidesEveryPartner() {
        // This alphabet accepts only the merged representatives, so a literal or a
        // code for the second letter would both be wrong: the option is hidden.
        for group in ["qw", "er", "ty", "ui", "op", "as", "df", "gh", "jk", "zx", "cv", "bn"] {
            let representative = String(group.prefix(1))
            XCTAssertTrue(
                options(
                    key: representative, mergedGroup: group,
                    language: .chinese, alphabet: clover14Alphabet
                ).isEmpty,
                "partner of \(group) is not in the 14-key alphabet")
        }
    }

    func testMergedPartnerIsACodeWhenTheAlphabetContainsIt() {
        let result = options(key: "q", mergedGroup: "qw", language: .chinese, alphabet: fullAlphabet)
        XCTAssertEqual(result, [.init(label: "w", payload: .code("w"))])
    }

    func testMergedPartnersPreserveGroupOrderAndNeverLiteral() {
        let result = options(key: "q", mergedGroup: "qwe", language: .chinese, alphabet: fullAlphabet)
        XCTAssertEqual(result.map(\.payload), [.code("w"), .code("e")])
        XCTAssertTrue(
            result.allSatisfy { option in
                if case .literal = option.payload { return false }
                return AlternateKeyPolicy.isValid(option)
            })
    }

    func testMergedPartnerAlphabetMatchIsCaseInsensitive() {
        let result = options(
            key: "q", mergedGroup: "qw", language: .chinese,
            alphabet: fullAlphabet.uppercased())
        XCTAssertEqual(result.map(\.payload), [.code("w")])
    }

    func testUnknownAlphabetFailsClosed() {
        XCTAssertTrue(options(key: "q", mergedGroup: "qw", language: .chinese, alphabet: "").isEmpty)
    }

    // MARK: T9 ABC is deliberately deferred

    func testPhoneLetterGroupYieldsNothingYet() {
        XCTAssertTrue(
            options(
                key: "ABC", page: .letters, language: .chinese,
                alphabet: "0123456789abcdefghijklmnopqrstuvwxyz"
            ).isEmpty,
            "T9 ABC waits for the real harness evidence")
        XCTAssertTrue(options(key: "WXYZ", page: .letters, language: .english).isEmpty)
    }

    func testDigitKeyOnTheLetterPageYieldsNothingYet() {
        // The T9 digit cap's single-letter gesture is not implemented; the digit
        // must not be turned into a spelling code or literal here.
        XCTAssertTrue(
            options(
                key: "2", page: .letters, language: .chinese,
                alphabet: "0123456789"
            ).isEmpty)
    }

    // MARK: Numeric / symbol pages

    func testNumericPageDigitsOfferChineseNumeralsInFullWidthOnly() {
        let one = options(key: "1", page: .numeric, language: .chinese)
        XCTAssertEqual(one.map(\.label), ["一", "壹", "①"])
        XCTAssertTrue(one.allSatisfy { $0.payload == .literal($0.label) })
        XCTAssertEqual(options(key: "0", page: .numeric, language: .chinese).map(\.label), ["零", "〇", "°"])
        // Half-width: Chinese numerals would pass the ASCII field's letter rule, so
        // that table never holds them; only the degree sign remains on 0.
        XCTAssertTrue(options(key: "1", page: .numeric, language: .english, asciiPunctuation: true).isEmpty)
        XCTAssertEqual(
            options(key: "0", page: .numeric, language: .english, asciiPunctuation: true).map(\.label), ["°"])
    }

    /// Every 123-page key's first option is its corner hint, so no list may
    /// offer a mark the same page already shows as a key.
    func testNumericPageListsNeverOfferAVisibleKey() {
        let pages: [(ascii: Bool, keys: [String])] = [
            (
                false,
                "1234567890".map(String.init) + ["-", "/", "：", "；", "（", "）", "¥", "@", "“", "”"]
                    + ["。", "，", "、", "？", "！", "."]
            ),
            (true, "1234567890-/:;()$&@\".,?!'".map(String.init)),
        ]
        for page in pages {
            let visible = Set(page.keys)
            for key in page.keys {
                let labels = options(key: key, page: .numeric, asciiPunctuation: page.ascii).map(\.label)
                XCTAssertTrue(visible.isDisjoint(with: labels), "\(key) offers a visible key: \(labels)")
            }
        }
    }

    func testNumericPagePunctuationVariantDoesNotRepeatTheKey() {
        let dash = options(key: "-", page: .numeric, language: .chinese)
        XCTAssertFalse(dash.contains { $0.label == "-" }, "the key's own label is not an alternate")
        XCTAssertTrue(dash.contains { $0.label == "—" })
    }

    func testSymbolsPageOperatorsOfferVariants() {
        let star = options(key: "*", page: .symbols, language: .chinese)
        XCTAssertTrue(star.contains { $0.label == "×" })
        XCTAssertTrue(star.contains { $0.label == "°" })
    }

    func testUnknownSymbolKeyOffersNothing() {
        XCTAssertTrue(options(key: "☃", page: .symbols, language: .chinese).isEmpty)
    }

    // MARK: Full/half-width field policy

    /// The CJK-priority grouping predicate (used when a CJK field orders forms).
    /// It is deliberately **not** the ASCII contract: `… — “ · • 〈` live outside
    /// these blocks (see `testASCIIFieldRejectsNonASCIIPunctuationOutsideFullwidthBlocks`).
    func testFullwidthPredicateCoversCJKAndFullwidthFormsOnly() {
        for value in ["，", "。", "、", "；", "：", "？", "！", "「", "」", "￥"] {
            XCTAssertTrue(AlternateKeyPolicy.isFullwidthOrCJKPunctuation(value), value)
        }
        for value in [
            ",", ".", "?", "!", ";", ":", "…", "—", "–", "“", "”", "$", "€", "¥", "£", "÷", "×", "±", "≈", "≠", "№",
            "‰", "°", "¦", "·", "•",
        ] {
            XCTAssertFalse(AlternateKeyPolicy.isFullwidthOrCJKPunctuation(value), value)
        }
    }

    func testASCIIFieldAllowListIsExactlyTheNamedCurrencyAndMathSymbols() {
        for value in [
            "€", "£", "¥", "±", "÷", "×", "≈", "≠", "№", "‰", "°",
            ".", ",", "a", "1", "á", "é",
        ] {
            XCTAssertTrue(AlternateKeyPolicy.isAllowedInASCIIField(value), value)
        }
        for value in [
            "…", "—", "–", "“", "”", "‘", "’", "¿", "¡", "·", "•",
            "〈", "〉", "‹", "›", "¦", "©", "®", "™", "§", "′",
            "￥", "，", "。", "「", "」", "？！",
        ] {
            XCTAssertFalse(AlternateKeyPolicy.isAllowedInASCIIField(value), value)
        }
    }

    func testASCIIFieldOffersNoFullwidthPunctuation() {
        // A URL/email/number field must never receive `。` or `、`.
        for key in ["。", "，", "、", "“", "（", "-", "/", "¥", "￥", "1"] {
            let labels = options(key: key, page: .numeric, language: .chinese, asciiPunctuation: true).map(\.label)
            XCTAssertTrue(labels.allSatisfy(AlternateKeyPolicy.isAllowedInASCIIField), "\(key): \(labels)")
            XCTAssertFalse(labels.contains { AlternateKeyPolicy.isFullwidthOrCJKPunctuation($0) }, key)
        }
    }

    /// `… — – “ ” ¿ ¡ · • 〈 〉` are non-ASCII but outside U+3000/FE30/FF00; the
    /// ASCII field must still reject them, not only the full-width forms.
    func testASCIIFieldRejectsNonASCIIPunctuationOutsideFullwidthBlocks() {
        let period = options(key: "。", page: .numeric, language: .chinese, asciiPunctuation: true)
        XCTAssertFalse(period.contains { $0.label == "…" }, "ellipsis is U+2026, not ASCII")

        let dash = options(key: "-", page: .numeric, language: .chinese, asciiPunctuation: true)
        XCTAssertFalse(dash.contains { $0.label == "—" })
        XCTAssertFalse(dash.contains { $0.label == "–" })
        XCTAssertFalse(dash.contains { $0.label == "·" }, "middle dot is U+00B7, not ASCII")
        XCTAssertTrue(dash.allSatisfy { AlternateKeyPolicy.isASCIIWidth($0.label) })

        let quote = options(key: "\"", page: .symbols, language: .chinese, asciiPunctuation: true)
        XCTAssertFalse(quote.contains { $0.label == "“" })
        XCTAssertFalse(quote.contains { $0.label == "”" })
        XCTAssertFalse(quote.contains { $0.label == "「" })
        XCTAssertTrue(quote.allSatisfy { AlternateKeyPolicy.isASCIIWidth($0.label) })

        let question = options(key: "?", page: .numeric, language: .chinese, asciiPunctuation: true)
        XCTAssertFalse(question.contains { $0.label == "¿" }, "inverted question is U+00BF")
        let bang = options(key: "!", page: .symbols, language: .chinese, asciiPunctuation: true)
        XCTAssertFalse(bang.contains { $0.label == "¡" }, "inverted exclamation is U+00A1")

        let bullet = options(key: "•", page: .symbols, language: .chinese, asciiPunctuation: true)
        XCTAssertFalse(bullet.contains { $0.label == "·" })
        XCTAssertFalse(bullet.contains { $0.label == "…" })
        let bracket = options(key: "<", page: .symbols, language: .chinese, asciiPunctuation: true)
        XCTAssertFalse(bracket.contains { $0.label == "〈" }, "angle bracket is U+2329")
        XCTAssertTrue(bracket.allSatisfy { AlternateKeyPolicy.isASCIIWidth($0.label) })
    }

    func testASCIIFieldFiltersSecondariesToo() {
        // A declared CJK/typographic secondary is removed (not reordered) in an
        // ASCII field.
        let ascii = options(
            key: "a", secondary: ["1", "，", "@", "…", "—"], language: .chinese,
            asciiPunctuation: true, alphabet: fullAlphabet)
        XCTAssertEqual(ascii.map(\.label), ["1", "@"])
    }

    /// The letter branch is not collateral damage: English accents are letter
    /// variants, not punctuation, and stay offered in an ASCII field.
    func testASCIIFieldKeepsEnglishAccentVariants() {
        let a = options(
            key: "a", secondary: ["1", "…", "á"], language: .english,
            asciiPunctuation: true, alphabet: fullAlphabet)
        XCTAssertEqual(a.first?.label, "1")
        XCTAssertFalse(a.contains { $0.label == "…" })
        XCTAssertTrue(a.contains { $0.label == "á" }, "accents survive the ASCII field")
        let upper = options(key: "e", secondary: ["é"], language: .english, uppercase: true, asciiPunctuation: true)
        XCTAssertTrue(upper.contains { $0.label == "É" })
    }

    func testFullwidthMarksOfferTheirHalfwidthFormFirst() {
        XCTAssertEqual(options(key: "，", page: .numeric).map(\.label), [","])
        XCTAssertEqual(options(key: "：", page: .numeric).map(\.label), [":"])
        XCTAssertEqual(options(key: "（", page: .numeric).map(\.label), ["(", "【", "[", "{"])
        XCTAssertEqual(options(key: "“", page: .numeric).first?.label, "「")
    }

    func testCurrencyAndMathFormsAreNotWidthVariantsAndSurviveASCII() {
        let yen = options(key: "¥", page: .numeric, language: .chinese, asciiPunctuation: true)
        XCTAssertEqual(yen.map(\.label), ["$", "€", "£"], "￥ is fullwidth and filtered; $ € £ stay")
        let fullwidthYen = options(key: "￥", page: .numeric, language: .chinese, asciiPunctuation: true)
        XCTAssertEqual(fullwidthYen.map(\.label), ["¥", "$", "€", "£"], "¥ itself is allow-listed")
        let times = options(key: "×", page: .symbols, language: .chinese, asciiPunctuation: true)
        XCTAssertEqual(times.map(\.label), ["*", "°"], "× offers * and °, both allowed")
        let divide = options(key: "÷", page: .symbols, language: .chinese, asciiPunctuation: true)
        XCTAssertEqual(divide.map(\.label), ["/"])
        let plusMinus = options(key: "+", page: .symbols, language: .chinese, asciiPunctuation: true)
        XCTAssertEqual(plusMinus.map(\.label), ["±"])
        let approx = options(key: "=", page: .symbols, language: .chinese, asciiPunctuation: true)
        XCTAssertEqual(approx.map(\.label), ["≈", "≠"])
        let hash = options(key: "#", page: .symbols, language: .chinese, asciiPunctuation: true)
        XCTAssertEqual(hash.map(\.label), ["№"])
        let percent = options(key: "%", page: .symbols, language: .chinese, asciiPunctuation: true)
        XCTAssertEqual(percent.map(\.label), ["‰"])
    }

    func testOrderedByFieldWidthIsStableAndFiltering() {
        XCTAssertEqual(
            AlternateKeyPolicy.orderedByFieldWidth(["，", ",", "、", ";"], asciiFirst: true),
            [",", ";"])
        XCTAssertEqual(
            AlternateKeyPolicy.orderedByFieldWidth(["，", ",", "、", ";"], asciiFirst: false),
            ["，", "、", ",", ";"])
        // Filtering preserves source order, keeps ASCII + the allow-list, and a CJK
        // field keeps every form.
        let mixed = [
            ".", ",", "…", "—", "“", "·", "•", "〈",
            "€", "£", "¥", "±", "÷", "×", "≈", "≠", "№", "‰", "°",
        ]
        XCTAssertEqual(
            AlternateKeyPolicy.orderedByFieldWidth(mixed, asciiFirst: true),
            [".", ",", "€", "£", "¥", "±", "÷", "×", "≈", "≠", "№", "‰", "°"])
        XCTAssertEqual(
            Set(AlternateKeyPolicy.orderedByFieldWidth(mixed, asciiFirst: false)),
            Set(mixed), "a CJK field keeps every form")
    }

    func testASCIIWidthHelper() {
        XCTAssertTrue(AlternateKeyPolicy.isASCIIWidth(","))
        XCTAssertFalse(AlternateKeyPolicy.isASCIIWidth("，"))
        XCTAssertFalse(AlternateKeyPolicy.isASCIIWidth(""))
    }

    // MARK: Contract: every emitted option is well typed

    func testEveryEmittableOptionObeysThePayloadContract() {
        var requests: [AlternateKeyPolicy.Request] = []
        for key in ["a", "q", "1", ".", "，", "—", "*", "ABC", "☃"] {
            for page in [AlternateKeyPolicy.Page.letters, .numeric, .symbols] {
                for language in [AlternateKeyPolicy.Language.chinese, .english] {
                    for ascii in [false, true] {
                        requests.append(
                            .init(
                                keyLabel: key, mergedGroup: "qw",
                                secondaryLiterals: ["1", "，", "@"],
                                page: page,
                                language: language, isUppercase: ascii,
                                usesASCIIPunctuation: ascii,
                                schemaAlphabet: fullAlphabet))
                    }
                }
            }
        }
        for request in requests {
            for option in AlternateKeyPolicy.options(for: request) {
                XCTAssertTrue(
                    AlternateKeyPolicy.isValid(option),
                    "\(request) produced invalid option \(option)")
                if case .code(let value) = option.payload {
                    XCTAssertTrue(AlternateKeyPolicy.isValidCode(value))
                }
            }
        }
    }

    // MARK: Sideways swipe on two-letter keys

    func testLetterSwipeNeedsBothExactLetters() {
        XCTAssertEqual(
            AlternateKeyPolicy.letterSwipeCodes(group: ["w", "e"], schemaAlphabet: "abcdefghijklmnopqrstuvwxyz"),
            ["w", "e"])
        XCTAssertEqual(
            AlternateKeyPolicy.letterSwipeCodes(group: ["W", "E"], schemaAlphabet: "zyxwvutsrqponmlkjihgfedcba"),
            ["w", "e"])
        // A schema that only knows the folded keys cannot take the exact right letter.
        XCTAssertNil(
            AlternateKeyPolicy.letterSwipeCodes(group: ["u", "i"], schemaAlphabet: "0123456789abcdegjlmoqtuz"))
        XCTAssertNil(AlternateKeyPolicy.letterSwipeCodes(group: ["q"], schemaAlphabet: "q"))
        XCTAssertNil(AlternateKeyPolicy.letterSwipeCodes(group: ["a", "b", "c"], schemaAlphabet: "abc"))
    }
}
