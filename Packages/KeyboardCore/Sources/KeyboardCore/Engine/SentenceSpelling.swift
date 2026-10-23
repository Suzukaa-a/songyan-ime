import Foundation
import os

/// Spells a candidate that has no provable reading of its own (a sentence the engine
/// joined from several words, 一金贵呀) for a numeric keypad field. Pure value logic.
public enum SentenceSpelling {
    /// Syllables in a keypad field are joined like mainstream 9-key pinyin (`ni'hao`).
    public static let separator = "'"

    /// `segments` are the engine's syllable segments of the highlighted code
    /// (`["94", "546", "484", "92"]`). Every segment shows letters, so each press stays
    /// visible: the reading proven for the text's character at that position (this
    /// code's candidates, then readings proven earlier in the session,
    /// `knownReadings`; only when the text has one character per segment), else the
    /// best-ranked proven syllable spelling those keys, else the most common Mandarin
    /// syllable that does. A segment that only begins a syllable (the one being typed,
    /// or an abbreviation such as `9` for 中) shows the letters of its keys (`ni'h`,
    /// `hao'y'y`); the engine's swapped-key correction (`442` → 还) shows the syllable
    /// it chose. Only keys no syllable can spell show as the keys themselves.
    /// Display only: commits never read this. nil only when the inputs cannot describe
    /// a keypad code at all.
    public static func spell(
        segments: [String], text: String, entries: [ReadingCandidate],
        keyForLetter: [Character: Character],
        knownReadings: [Character: [String]] = [:]
    ) -> String? {
        guard !segments.isEmpty, !keyForLetter.isEmpty,
            segments.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) })
        else { return nil }
        let characters = Array(text)
        let aligned = characters.count == segments.count
        var byCharacter: [Character: [String]] = [:]
        var vocabulary: [String] = []
        var known = Set<String>()
        for entry in entries where entry.readingsComplete {
            for path in entry.readingPaths ?? [] {
                for syllable in path where known.insert(syllable).inserted { vocabulary.append(syllable) }
                guard entry.text.count == path.count else { continue }
                for (character, syllable) in zip(entry.text, path) {
                    byCharacter[character, default: []].append(syllable)
                }
            }
        }
        let common = Self.keyIndex(for: keyForLetter)
        var spelled: [String] = []
        for (offset, segment) in segments.enumerated() {
            let last = offset == segments.count - 1
            let character = aligned ? characters[offset] : nil
            let proven = character.flatMap { byCharacter[$0] } ?? []
            let remembered = character.flatMap { knownReadings[$0] } ?? []
            func keys(_ syllable: String) -> String? {
                let keys = String(syllable.lowercased().compactMap { keyForLetter[$0] })
                return keys.count == syllable.count ? keys : nil
            }
            func exact(_ syllable: String) -> Bool { keys(syllable) == segment }
            func begun(_ syllable: String) -> Bool { keys(syllable)?.hasPrefix(segment) == true }
            func transposed(_ syllable: String) -> Bool {
                keys(syllable).map { $0.count == segment.count && $0.sorted() == segment.sorted() } ?? false
            }
            // The last segment may still be being typed. A finished-looking last
            // segment (`6` for 哦) is still the whole syllable more often than the
            // start of an unrelated common one (`men`).
            let fits: (String) -> Bool = last ? begun : exact
            let evidence = proven + remembered
            let chosen =
                proven.first(where: fits) ?? remembered.first(where: fits) ?? vocabulary.first(where: fits)
                ?? common.exact[segment] ?? (last ? common.begun[segment] : nil)
                ?? evidence.first(where: begun) ?? common.begun[segment]
                ?? evidence.first(where: transposed) ?? common.transposed[String(segment.sorted())]
            if let chosen {
                spelled.append(begun(chosen) && !exact(chosen) ? String(chosen.prefix(segment.count)) : chosen)
            } else {
                spelled.append(segment)
            }
        }
        return spelled.joined(separator: separator)
    }

    /// `commonSyllables` by the keys that spell them under one key map, the most common
    /// syllable first: whole keys, every leading part of them, and the keys in sorted
    /// order (swapped-key corrections). Built once per map; every lookup is a hash hit.
    private struct KeyIndex: Sendable {
        var exact: [String: String] = [:]
        var begun: [String: String] = [:]
        var transposed: [String: String] = [:]
    }
    private static let keyIndexes = OSAllocatedUnfairLock<[[Character: Character]: KeyIndex]>(initialState: [:])

    private static func keyIndex(for keyForLetter: [Character: Character]) -> KeyIndex {
        if let cached = keyIndexes.withLock({ $0[keyForLetter] }) { return cached }
        var index = KeyIndex()
        for syllable in commonSyllables {
            let keys = String(syllable.compactMap { keyForLetter[$0] })
            guard keys.count == syllable.count else { continue }
            if index.exact[keys] == nil { index.exact[keys] = syllable }
            if index.transposed[String(keys.sorted())] == nil { index.transposed[String(keys.sorted())] = syllable }
            for length in 1...keys.count {
                let prefix = String(keys.prefix(length))
                if index.begun[prefix] == nil { index.begun[prefix] = syllable }
            }
        }
        keyIndexes.withLock { [index] cache in
            if cache.count > 8 { cache.removeAll() }
            cache[keyForLetter] = index
        }
        return index
    }

    /// Position of each syllable in `commonSyllables`, lower is more common.
    static let commonSyllableRank: [String: Int] = commonSyllables.enumerated()
        .reduce(into: [:]) { if $0[$1.element] == nil { $0[$1.element] = $1.offset } }

    /// Every Mandarin pinyin syllable (ü as `v`; also interjections such as `n`, `m`),
    /// most used first, so keys several syllables share (`64` ni/mi, `424` hai/gai)
    /// fall back to the likelier.
    static let commonSyllables: [String] = """
        de shi yi bu le zai ren you wo ta zhe ge men lai dao shang da wei he guo zhong sheng zi hui yao ye jiu ke
        dui chu xia ni neng jia nian duo fa hao zuo xue fen zhi xing qi li mei ba fang ji guan dong yu xian kan qu
        xin hou wu na mian ming tong gong xiang dian zhu qian jian jin gao ying cheng ru wen cong gei yong ben ran
        shen bian dang huo ding shuo bie zheng hai xiao bei san tian quan mo ma ai an o lu liang si ti chang mu biao
        jiao zhao zhan ce dan hua shou xi tou jie ju xu wang yuan yue zou zhun qing ri lao kai gai hen jing kou lun
        ling bao pin tiao ci che la ruo qie zao suo shu ban tai mao lei nan hu pao jun shan yin bai jue mi feng wan
        nei kuai po bi die su min chi zhuang du fu rang zu tu cai shui chuan deng dou song guang huan zhou qiu ya
        xie ze wa za pi gu e ou ei er n m ng a ang ao en eng bang beng bin bing bo pa pai pan pang pei pen peng pian
        piao pie ping pou pu mai man mang me meng miao mie miu mou fan fei fo fou dai dei den di dia diao diu duan
        dun tan tang tao te tei teng tie ting tuan tui tun tuo nai nang nao ne nen niang niao nie nin ning niu nong
        nou nu nuan nun nuo nv nve nue lan lang leng lia lian liao lie lin liu lo long lou luan luo lv lve lue ga
        gan gang gen geng gou gua guai gui gun ka kang kao kei ken keng kong ku kua kuan kuang kui kun kuo ha han
        hang hei heng hong huai huang hun jiang jiong juan qia qiang qiao qin qiong que qun xiong xiu xuan xun zha
        zhai zhang zhei zhen zhua zhuai zhuan zhui zhuo cha chai chan chao chen chong chou chua chuai chuang chui
        chun chuo sha shai shao she shei shua shuai shuan shuang shun rao re reng rong rou rua ruan rui run zan zang
        zei zen zeng zong zuan zui zun ca can cang cao cen ceng cou cu cuan cui cun cuo sa sai sang sao se sen seng
        sou suan sui sun yan yang yo yun wai weng hm hng
        """.split(whereSeparator: \.isWhitespace).map(String.init)
}
