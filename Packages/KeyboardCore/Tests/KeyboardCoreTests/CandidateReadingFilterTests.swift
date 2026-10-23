import XCTest

@testable import KeyboardCore

final class CandidateReadingFilterTests: XCTestCase {
    func testMergedCandidateMatchesAnyWholePathWithoutMixingSyllables() {
        var state = CandidateReadingFilter()
        state.reset(revision: 1)
        state.append(
            [.init(index: 0, text: "重重", readingPaths: [["chong", "chong"], ["zhong", "zhong"]])], requested: 2,
            revision: 1)
        XCTAssertEqual(state.options, ["zhong", "chong"])
        state.select("zhong")
        XCTAssertEqual(state.options, ["zhong"])
        state.select("chong")  // Not a real path; must be ignored.
        XCTAssertEqual(state.prefix, ["zhong"])
        state.select("zhong")
        XCTAssertEqual(state.matches.map(\.index), [0])
        state.clearSelection()
        state.select("chong")
        state.select("chong")
        XCTAssertEqual(state.matches.map(\.index), [0])
        state.reset(revision: 2)
        state.append(
            [.init(index: 0, text: "部分可信", readingPaths: [["ni"]], readingsComplete: false)], requested: 2, revision: 2)
        XCTAssertEqual(state.unclassifiedCount, 1)
    }

    func testWholeCommonSyllablesComeBeforeLessCommonAndBegunOnes() {
        var state = CandidateReadingFilter()
        state.reset(revision: 1)
        // 9-key `64`: the engine ranks 米 first, the last key may also begin 好-like syllables.
        state.setCoverage(ReadingInputCoverage(input: "64", keyForLetter: Self.nineKeyMap))
        state.append(
            [
                .init(index: 0, text: "米", readingPaths: [["mi"]]),
                .init(index: 1, text: "你好", readingPaths: [["ni", "hao"]]),
                .init(index: 2, text: "你", readingPaths: [["ni"]]),
                .init(index: 3, text: "蘑菇", readingPaths: [["mo", "gu"]]),
                .init(index: 4, text: "某", readingPaths: [["mou"]]),
            ], requested: 8, revision: 1)
        XCTAssertEqual(state.options, ["ni", "mi", "mo", "mou"])
        state.select("ni")
        XCTAssertEqual(state.options, [], "ni already spells both keys")
        state.clearSelection()
        state.reset(revision: 2)
        // The last key only begins 好/会: its letters follow every whole syllable.
        state.setCoverage(ReadingInputCoverage(input: "644", keyForLetter: Self.nineKeyMap))
        state.append(
            [
                .init(index: 0, text: "你好", readingPaths: [["ni", "hao"]]),
                .init(index: 1, text: "你会", readingPaths: [["ni", "hui"]]),
                .init(index: 2, text: "你给", readingPaths: [["ni", "gei"]]),
            ], requested: 8, revision: 2)
        state.select("ni")
        XCTAssertEqual(state.options, ["h", "g"])
    }

    func testNonMandarinReadingsKeepEngineOrder() {
        var state = CandidateReadingFilter()
        state.reset(revision: 1)
        // Jyutping: `gwong` is not a Mandarin syllable, so `si` must not jump ahead of it.
        state.append(
            [
                .init(index: 0, text: "光", readingPaths: [["gwong"]]),
                .init(index: 1, text: "是", readingPaths: [["si"]]),
            ], requested: 8, revision: 1)
        XCTAssertEqual(state.options, ["gwong", "si"])
    }

    /// rime-ice 9-key derives `chang` as `hcng` (4264); the engine reports its spellings
    /// alphabetically. Spellings typed letter for letter come first.
    func testSpellingOptionsTypedLetterForLetterComeFirst() {
        let ordered = SyllableOrder.spellingOptions(
            ["chang", "cheng", "chong", "gang", "hang"],
            typedKeys: "4264", keyForLetter: Self.nineKeyMap)
        XCTAssertEqual(Array(ordered.prefix(2)), ["gang", "hang"])
        XCTAssertEqual(Set(ordered), ["chang", "cheng", "chong", "gang", "hang"])
        XCTAssertEqual(
            SyllableOrder.spellingOptions(["b", "a"], typedKeys: "2", keyForLetter: [:]), ["b", "a"],
            "without a key map the engine's order stays")
    }

    /// The real 4264 candidates: the first one (成 cheng) is a derived spelling, so the key
    /// map is not trusted, yet readings typed letter for letter still lead, longest first.
    func testUntrustedKeyMapStillPutsLiteralReadingsFirst() {
        var state = CandidateReadingFilter()
        state.reset(revision: 1)
        state.setCoverage(ReadingInputCoverage(input: "4264", keyForLetter: Self.nineKeyMap))
        state.append(
            [
                .init(index: 0, text: "成", readingPaths: [["cheng"]]),
                .init(index: 1, text: "长", readingPaths: [["chang"]]),
                .init(index: 2, text: "行", readingPaths: [["hang"]]),
                .init(index: 3, text: "哈尼", readingPaths: [["ha", "ni"]]),
                .init(index: 4, text: "刚", readingPaths: [["gang"]]),
                .init(index: 5, text: "冲", readingPaths: [["chong"]]),
            ], requested: 8, revision: 1)
        XCTAssertEqual(Array(state.options.prefix(3)), ["gang", "hang", "ha"])
        XCTAssertEqual(Set(state.options.dropFirst(3)), ["cheng", "chang", "chong"])
    }

    private static let nineKeyMap: [Character: Character] = {
        var map: [Character: Character] = [:]
        for (key, letters) in zip("23456789", ["abc", "def", "ghi", "jkl", "mno", "pqrs", "tuv", "wxyz"]) {
            for letter in letters { map[letter] = key }
        }
        return map
    }()

    func testIncompleteReadingPathsNeverBecomeSelectableMatches() {
        var state = CandidateReadingFilter()
        state.reset(revision: 3)
        state.append(
            [
                .init(index: 0, text: "部分可信", readingPaths: [["mi"]], readingsComplete: false),
                .init(index: 1, text: "你", readingPaths: [["ni"]], readingsComplete: true),
            ], requested: 2, revision: 3)
        XCTAssertEqual(state.options, ["ni"])
        state.select("mi")
        XCTAssertTrue(state.prefix.isEmpty)
        state.select("ni")
        XCTAssertEqual(state.matches.map(\.index), [1])
        state.clearSelection()
        XCTAssertEqual(
            state.matches.map(\.index), [0, 1],
            "after clearing the filter, candidates with unproven readings can still be browsed")
    }

    func testContinuousReadingSelectionKeepsAbsoluteOrderAndUnknownAccessibleOnCancel() {
        var state = CandidateReadingFilter()
        state.reset(revision: 1)
        state.append(
            [
                .init(index: 0, text: "你", syllables: ["ni"]),
                .init(index: 1, text: "你好", syllables: ["ni", "hao"]),
                .init(index: 2, text: "米", syllables: ["mi"]),
                .init(index: 3, text: "外来候选", syllables: nil),
            ], requested: 4, revision: 1)
        XCTAssertEqual(state.options, ["ni", "mi"])
        state.select("ni")
        XCTAssertEqual(state.matches.map(\.index), [0, 1])
        XCTAssertEqual(state.options, ["hao"])
        state.select("hao")
        XCTAssertEqual(state.matches.map(\.index), [0, 1], "你 spells the first chosen syllable")
        XCTAssertEqual(state.nextIndex, 4)
        state.undoSelection()
        XCTAssertEqual(state.prefix, ["ni"])
        state.clearSelection()
        XCTAssertEqual(state.matches.map(\.index), [0, 1, 2, 3])
    }

    func testNonmatchingPagesDoNotTruncateFutureMatchesAndFailuresRemainRetryable() {
        var state = CandidateReadingFilter()
        state.reset(revision: 8)
        state.append([.init(index: 0, text: "甲", syllables: ["jia"])], requested: 1, revision: 8)
        state.select("jia")
        state.append([.init(index: 1, text: "乙", syllables: ["yi"])], requested: 1, revision: 8)
        XCTAssertTrue(state.hasMore)
        state.failed()
        XCTAssertEqual(state.nextIndex, 2)
        state.append([.init(index: 2, text: "家庭", syllables: ["jia", "ting"])], requested: 1, revision: 8)
        XCTAssertEqual(state.matches.map(\.index), [0, 2])
        XCTAssertFalse(state.readFailed)
        state.append([], requested: 1, revision: 8)
        XCTAssertFalse(state.hasMore)
        state.reset(revision: 9)  // Backspace/schema/options change invalidates reading locks.
        state.append([.init(index: 0, text: "过期", syllables: ["old"])], requested: 1, revision: 8)
        XCTAssertTrue(state.entries.isEmpty)
        XCTAssertTrue(state.prefix.isEmpty)
    }

    /// Readings have a single path: tap a **real** reading item on the left to select it. `options` are
    /// deduplicated in candidate order; selecting a value that is not a real option is ignored and must never append syllables from a right-side cycle path.
    func testOnlyRealLeftSideReadingOptionsCanBeSelected() {
        var state = CandidateReadingFilter()
        state.reset(revision: 1)
        state.append(
            [
                .init(index: 0, text: "你", syllables: ["ni"]),
                .init(index: 1, text: "米", syllables: ["mi"]),
                .init(index: 2, text: "你好", syllables: ["ni", "hao"]),
                .init(index: 3, text: "你号", syllables: ["ni", "hao2"]),
            ], requested: 4, revision: 1)
        XCTAssertEqual(state.options, ["ni", "mi"], "the first-level real readings follow candidate order")

        // Select real left-side items layer by layer.
        state.select("ni")
        XCTAssertEqual(state.prefix, ["ni"])
        XCTAssertEqual(state.options, ["hao", "hao2"], "the second-level real readings")
        state.select("hao2")
        XCTAssertEqual(state.prefix, ["ni", "hao2"])
        XCTAssertEqual(state.matches.map(\.index), [0, 3])

        // Non-real options (right-side cycle / forged values) must never be accepted.
        state.select("chong")
        state.select("hao")
        XCTAssertEqual(state.prefix, ["ni", "hao2"], "a non-real option must be ignored")

        state.undoSelection()
        XCTAssertEqual(state.prefix, ["ni"])
        state.clearSelection()
        XCTAssertEqual(state.prefix, [])

        // No trustworthy reading: no selectable path, state unchanged.
        var empty = CandidateReadingFilter()
        empty.reset(revision: 1)
        empty.append([.init(index: 0, text: "外来", syllables: nil)], requested: 1, revision: 1)
        XCTAssertTrue(empty.options.isEmpty)
        empty.select("ni")
        XCTAssertTrue(empty.prefix.isEmpty)
    }

    private static let t9Keys: [Character: Character] = {
        var map: [Character: Character] = [:]
        for (digit, letters) in zip("23456789", ["abc", "def", "ghi", "jkl", "mno", "pqrs", "tuv", "wxyz"]) {
            for letter in letters { map[letter] = digit }
        }
        return map
    }()

    func testCompletionSyllablesBeyondTypedKeysAreNotOffered() {
        var state = CandidateReadingFilter()
        state.reset(revision: 1)
        state.setCoverage(ReadingInputCoverage(input: "64426", keyForLetter: Self.t9Keys))
        state.append(
            [
                .init(index: 0, text: "你好", readingPaths: [["ni", "hao"]]),
                .init(index: 1, text: "你好吗", readingPaths: [["ni", "hao", "ma"]]),
                .init(index: 2, text: "你", readingPaths: [["ni"]]),
            ], requested: 8, revision: 1)
        XCTAssertEqual(state.options, ["ni"])
        state.select("ni")
        XCTAssertEqual(state.options, ["hao"])
        state.select("hao")
        XCTAssertEqual(state.options, [], "ma was predicted, not typed")
        XCTAssertEqual(
            state.matches.map(\.text), ["你好", "你好吗", "你"],
            "completions stay selectable, and so does a word for the first syllables")
    }

    /// Real-device report: `64'4` with ni + hao chosen still offered huai/gao from
    /// 你好坏/你好高 by reading `ni` as the single key `6` and `hao` as the `4` before
    /// the separator. Chosen syllables consume as many keys as they can.
    func testChosenSyllablesThatSpellEveryKeyOfferNothingMore() {
        var state = CandidateReadingFilter()
        state.reset(revision: 1)
        state.setCoverage(ReadingInputCoverage(input: "64'4", keyForLetter: Self.t9Keys))
        state.append(
            [
                .init(index: 0, text: "你好", readingPaths: [["ni", "hao"]]),
                .init(index: 1, text: "你好坏", readingPaths: [["ni", "hao", "huai"]]),
                .init(index: 2, text: "你好高", readingPaths: [["ni", "hao", "gao"]]),
                .init(index: 3, text: "你会", readingPaths: [["ni", "hui"]]),
            ], requested: 8, revision: 1)
        state.select("ni")
        XCTAssertEqual(state.options, ["h"])
        state.select("h")
        XCTAssertEqual(state.options, [])
    }

    /// Real-device report: `ni` chosen over three keys offered hao/hui/hai for the one
    /// key still being typed. That key spells `g` or `h`; choosing a letter keeps every
    /// word whose syllable it begins. A syllable typed in full is still offered whole.
    func testSyllableStillBeingTypedOffersTheTypedLetters() {
        var state = CandidateReadingFilter()
        state.reset(revision: 1)
        state.setCoverage(ReadingInputCoverage(input: "644", keyForLetter: Self.t9Keys))
        state.append(
            [
                .init(index: 0, text: "你好", readingPaths: [["ni", "hao"]]),
                .init(index: 1, text: "你会", readingPaths: [["ni", "hui"]]),
                .init(index: 2, text: "你给", readingPaths: [["ni", "gei"]]),
                .init(index: 3, text: "你", readingPaths: [["ni"]]),
            ], requested: 8, revision: 1)
        state.select("ni")
        XCTAssertEqual(state.options, ["h", "g"])
        state.select("h")
        XCTAssertEqual(state.options, [])
        XCTAssertEqual(state.matches.map(\.text), ["你好", "你会", "你"])
        XCTAssertTrue(state.startsWithPrefix(["ni", "hao"]))
        XCTAssertFalse(state.startsWithPrefix(["ni", "gei"]))
        state.undoSelection()
        XCTAssertEqual(state.options, ["h", "g"])

        var whole = CandidateReadingFilter()
        whole.reset(revision: 1)
        whole.setCoverage(ReadingInputCoverage(input: "64426", keyForLetter: Self.t9Keys))
        whole.append([.init(index: 0, text: "你好", readingPaths: [["ni", "hao"]])], requested: 8, revision: 1)
        whole.select("ni")
        XCTAssertEqual(whole.options, ["hao"])
    }

    /// Choosing `ke cheng xing` keeps 课程 and 可 (1…n syllables), not only the
    /// three-syllable words.
    func testChosenReadingAlsoMatchesWordsForItsLeadingSyllables() {
        var state = CandidateReadingFilter()
        state.reset(revision: 1)
        state.append(
            [
                .init(index: 0, text: "可成形", readingPaths: [["ke", "cheng", "xing"]]),
                .init(index: 1, text: "课程", readingPaths: [["ke", "cheng"]]),
                .init(index: 2, text: "客船", readingPaths: [["ke", "chuan"]]),
                .init(index: 3, text: "可", readingPaths: [["ke"]]),
            ], requested: 8, revision: 1)
        state.select("ke")
        state.select("cheng")
        state.select("xing")
        XCTAssertEqual(state.matches.map(\.text), ["可成形", "课程", "可"])
        XCTAssertTrue(CandidateReadingFilter.continues(["ke"], ["ke", "cheng"]))
        XCTAssertFalse(CandidateReadingFilter.continues([], ["ke"]))
        XCTAssertFalse(CandidateReadingFilter.continues(["ke", "chuan"], ["ke", "cheng"]))
    }

    func testCoverageAcceptsAbbreviationsSeparatorsAndLockedLetters() {
        let coverage = ReadingInputCoverage(input: "64'4", keyForLetter: Self.t9Keys)!
        XCTAssertTrue(coverage.fits(["ni", "hao"], consumingAll: true))
        XCTAssertFalse(coverage.fits(["ni", "hao", "ma"], consumingAll: false))
        XCTAssertFalse(coverage.fits(["nih"], consumingAll: true), "a syllable cannot cross a typed separator")
        XCTAssertTrue(
            ReadingInputCoverage(input: "6442", keyForLetter: Self.t9Keys)!
                .fits(["ni", "hao"], consumingAll: true), "the last syllable may still be typed")
        XCTAssertFalse(
            ReadingInputCoverage(input: "64426", keyForLetter: Self.t9Keys)!
                .fits(["ni", "hao", "ma"], consumingAll: false), "only initials abbreviate mid-input")
        let locked = ReadingInputCoverage(input: "ni426", keyForLetter: Self.t9Keys)!
        XCTAssertTrue(locked.fits(["ni", "hao"], consumingAll: true))
        XCTAssertFalse(locked.fits(["mi", "hao"], consumingAll: false))
    }

    func testUnprovableKeyMapKeepsEveryEngineReading() {
        // Double pinyin codes are not reading letters: the first candidate does not
        // spell the typed keys, so nothing is hidden.
        var state = CandidateReadingFilter()
        state.reset(revision: 1)
        state.setCoverage(ReadingInputCoverage(input: "nihc", keyForLetter: ["n": "n"]))
        state.append(
            [
                .init(index: 0, text: "你好", readingPaths: [["ni", "hao"]]),
                .init(index: 1, text: "你好吗", readingPaths: [["ni", "hao", "ma"]]),
            ], requested: 8, revision: 1)
        state.select("ni")
        state.select("hao")
        XCTAssertEqual(state.options, ["ma"])
    }

    func testTypedSpellingShowsOnlyWhatWasTyped() {
        let three = ReadingInputCoverage(input: "284", keyForLetter: Self.t9Keys)!
        XCTAssertEqual(three.typedSpelling(["bu", "guo"]), ["bu", "g"])
        XCTAssertEqual(ReadingInputCoverage(input: "6", keyForLetter: Self.t9Keys)!.typedSpelling(["na"]), ["n"])
        XCTAssertEqual(
            ReadingInputCoverage(input: "28426", keyForLetter: Self.t9Keys)!
                .typedSpelling(["bu", "hao"]), ["bu", "hao"])
        XCTAssertNil(three.typedSpelling(["bu"]), "a candidate for part of the input keeps its full reading")
    }

    /// 14 keys: a tap on DF sends `d` for both letters; an exact pick of `d` sends the
    /// fold's exact token, which covers `d` only.
    func testExactTokenCoversItsLetterOnly() throws {
        let fold = CompactFold.merged14
        let token = try XCTUnwrap(fold.exactTokens["d"])
        XCTAssertNil(fold.exactTokens["f"], "the other letter of a key types itself")
        XCTAssertFalse(("a"..."z").contains(String(token)))
        let keys = fold.map
        let exact = Dictionary(uniqueKeysWithValues: fold.exactTokens.map { ($1, $0) })
        let picked = try XCTUnwrap(ReadingInputCoverage(input: "\(token)u", keyForLetter: keys, exactKeys: exact))
        XCTAssertTrue(picked.fits(["du"], consumingAll: true))
        XCTAssertFalse(picked.fits(["fu"], consumingAll: true))
        XCTAssertEqual(picked.typedSpelling(["du"]), ["du"])
        let tapped = try XCTUnwrap(ReadingInputCoverage(input: "du", keyForLetter: keys, exactKeys: exact))
        XCTAssertTrue(tapped.fits(["du"], consumingAll: true))
        XCTAssertTrue(tapped.fits(["fu"], consumingAll: true))
        XCTAssertEqual(Set(CompactFold.merged18.exactTokens.keys), Set("wrisfjxb"))
        XCTAssertTrue(CompactFold.phone9.exactTokens.isEmpty)
    }
}
