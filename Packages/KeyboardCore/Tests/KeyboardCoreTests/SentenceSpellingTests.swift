import XCTest

@testable import KeyboardCore

final class SentenceSpellingTests: XCTestCase {
    private static let t9: [Character: Character] = {
        var map: [Character: Character] = [:]
        for (digit, letters) in zip("23456789", ["abc", "def", "ghi", "jkl", "mno", "pqrs", "tuv", "wxyz"]) {
            for letter in letters { map[letter] = digit }
        }
        return map
    }()

    private func spell(
        _ segments: [String], _ text: String, _ entries: [ReadingCandidate] = [],
        known: [Character: [String]] = [:]
    ) -> String? {
        SentenceSpelling.spell(
            segments: segments, text: text, entries: entries,
            keyForLetter: Self.t9, knownReadings: known)
    }

    func testSentenceTakesCharacterReadingsThenRankedSyllables() {
        let entries: [ReadingCandidate] = [
            .init(index: 0, text: "一金贵呀", readingPaths: nil),
            .init(index: 1, text: "犀金龟", readingPaths: [["xi", "jin", "gui"]]),
            .init(index: 2, text: "一经", readingPaths: [["yi", "jing"]]),
        ]
        XCTAssertEqual(
            spell(["94", "546", "484", "92"], "一金贵呀", entries), "yi'jin'gui'ya",
            "a syllable no candidate proves falls back to the common one")
    }

    /// Recording: 他应当 for `82 9464 3264` left the field blank.
    func testUnprovenSegmentsNeverBlankOrTruncateTheField() {
        let entries: [ReadingCandidate] = [
            .init(index: 0, text: "塔影", readingPaths: [["ta", "ying"]]),
            .init(index: 1, text: "他以后", readingPaths: [["ta", "yi", "hou"]]),
        ]
        XCTAssertEqual(
            spell(["82", "9464", "3264"], "他应当", entries, known: ["当": ["dang"]]),
            "ta'ying'dang", "当 was proven earlier in the session")
        XCTAssertEqual(spell(["82", "9464"], "他应当", entries), "ta'ying")
        XCTAssertEqual(spell(["82", "94"], "他应", entries), "ta'yi", "the last segment is trimmed to its typed keys")
        XCTAssertEqual(spell(["11"], "嗯", entries), "11", "only keys no syllable spells show as keys")
        XCTAssertNil(SentenceSpelling.spell(segments: ["82"], text: "他", entries: entries, keyForLetter: [:]))
    }

    /// Recordings: tapping 6 after 你好 kept the field on `ni hao` and 哦还 showed `o`;
    /// every press must stay visible, like mainstream 9-key pinyin (`hao'y'y'y`).
    func testSentenceTailKeepsEveryPressVisible() {
        let entries: [ReadingCandidate] = [
            .init(index: 0, text: "你好", readingPaths: [["ni", "hao"]]),
            .init(index: 1, text: "米虫", readingPaths: [["mi", "chong"]]),
        ]
        XCTAssertEqual(spell(["64", "426", "66"], "你好魔", entries), "ni'hao'mo")
        XCTAssertEqual(
            spell(["6", "442"], "哦还"), "o'hai",
            "nothing loaded yet; the engine's swapped-key correction still spells hai")
        XCTAssertEqual(
            spell(["64", "424"], "米该", known: ["米": ["mi"], "该": ["gai"]]), "mi'gai",
            "a reading proven earlier beats syllable frequency")
        XCTAssertEqual(
            spell(
                ["64", "426", "9", "9", "9", "9"], "你好中央音乐", entries,
                known: ["中": ["zhong"], "央": ["yang"], "音": ["yin"], "乐": ["yue"]]),
            "ni'hao'z'y'y'y", "abbreviated segments show the initials of their readings")
        XCTAssertEqual(
            spell(["64", "426", "9", "9", "9"], "你好呷呀呀", entries), "ni'hao'y'y'y",
            "an unproven abbreviation still shows one letter per press")
        XCTAssertEqual(
            spell(["64", "426", "666", "66"], "你好浓哦", entries, known: ["浓": ["nong"]]),
            "ni'hao'non'mo", "an abbreviated inner segment shows its typed part")
        XCTAssertEqual(
            spell(["64", "4"], "你好", entries), "ni'h",
            "the syllable being typed is trimmed to its keys")
    }
}
