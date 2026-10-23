import Foundation

// MARK: - Demo engine (clearly labeled: not the real Rime)
//
// Boundary (see the engine integration contract in EngineBackend):
//  - This engine only demonstrates the host-app onboarding / typing-trial field / keyboard
//    layout and candidate UI flows. Candidates come from an embedded demo vocabulary (an
//    original hand-written mirror of 43 multi-character words from the built-in
//    dictionary). It does not connect to librime and produces no learning data.
//  - The UI must show EngineBackendKind == .demoSimulator as "demo data" and must not
//    describe demo candidates as real Rime candidates.
//  - Production uses RimeBackend from Apps/SharedKeyboard; this file is for KeyboardCore
//    unit tests and explicit demos only (EngineProvider.makeDemoEngine).
//
// Demo semantics (simplified):
//  - Accumulates the current layout's input code per key (e.g. 26-key full pinyin nihao /
//    14-key bugc / 9-key 64426).
//  - Candidates = demo words whose full input code starts with the typed code; the first is highlighted.
//  - Space/return: with candidates, confirms the highlighted one (default index 0); with
//    none, space commits a space and return on an empty state is turned into a newline by
//    the upper layer. Backspace removes the last code.
//  - After a candidate is chosen, the remaining input code is cleared/continued (approximates express_editor).
//  - No paging (real-engine paging belongs to RimeBridge).

/// Demo vocabulary entry: word form + canonical pinyin syllables.
struct DemoWord: Sendable {
    let text: String
    let syllables: [String]
}

/// Mirror of 43 multi-character words from the built-in dictionary (songyan_basic.dict.yaml,
/// original data written in this repo), used by the demo engine to generate candidates offline.
/// Real candidates and learning always come from RimeBridge/librime.
/// Source columns: Tests/EngineFixtures/Builtin/encodings.tsv lines 2-44 (text/full_pinyin).
let demoVocabulary: [DemoWord] = [
    DemoWord(text: "你好", syllables: ["ni", "hao"]),
    DemoWord(text: "我们", syllables: ["wo", "men"]),
    DemoWord(text: "中国", syllables: ["zhong", "guo"]),
    DemoWord(text: "中国人", syllables: ["zhong", "guo", "ren"]),
    DemoWord(text: "大家", syllables: ["da", "jia"]),
    DemoWord(text: "同学", syllables: ["tong", "xue"]),
    DemoWord(text: "学习", syllables: ["xue", "xi"]),
    DemoWord(text: "工作", syllables: ["gong", "zuo"]),
    DemoWord(text: "手机", syllables: ["shou", "ji"]),
    DemoWord(text: "电脑", syllables: ["dian", "nao"]),
    DemoWord(text: "键盘", syllables: ["jian", "pan"]),
    DemoWord(text: "公交车", syllables: ["gong", "jiao", "che"]),
    DemoWord(text: "音乐", syllables: ["yin", "yue"]),
    DemoWord(text: "月亮", syllables: ["yue", "liang"]),
    DemoWord(text: "学习拼音", syllables: ["xue", "xi", "pin", "yin"]),
    DemoWord(text: "双拼实验", syllables: ["shuang", "pin", "shi", "yan"]),
    DemoWord(text: "白键盘", syllables: ["bai", "jian", "pan"]),
    DemoWord(text: "银行", syllables: ["yin", "hang"]),
    DemoWord(text: "长大", syllables: ["zhang", "da"]),
    DemoWord(text: "长度", syllables: ["chang", "du"]),
    DemoWord(text: "快乐", syllables: ["kuai", "le"]),
    DemoWord(text: "行走", syllables: ["xing", "zou"]),
    DemoWord(text: "行列", syllables: ["hang", "lie"]),
    DemoWord(text: "重要", syllables: ["zhong", "yao"]),
    DemoWord(text: "重复", syllables: ["chong", "fu"]),
    DemoWord(text: "还是", syllables: ["hai", "shi"]),
    DemoWord(text: "归还", syllables: ["gui", "huan"]),
    DemoWord(text: "绿色", syllables: ["lv", "se"]),
    DemoWord(text: "女孩", syllables: ["nv", "hai"]),
    DemoWord(text: "二月", syllables: ["er", "yue"]),
    DemoWord(text: "爱好", syllables: ["ai", "hao"]),
    DemoWord(text: "平安", syllables: ["ping", "an"]),
    DemoWord(text: "西安", syllables: ["xi", "an"]),
    DemoWord(text: "帮忙", syllables: ["bang", "mang"]),
    DemoWord(text: "声音", syllables: ["sheng", "yin"]),
    DemoWord(text: "明天", syllables: ["ming", "tian"]),
    DemoWord(text: "生活", syllables: ["sheng", "huo"]),
    DemoWord(text: "健康", syllables: ["jian", "kang"]),
    DemoWord(text: "长城", syllables: ["chang", "cheng"]),
    DemoWord(text: "长江", syllables: ["chang", "jiang"]),
    DemoWord(text: "成长", syllables: ["cheng", "zhang"]),
    DemoWord(text: "山水", syllables: ["shan", "shui"]),
    DemoWord(text: "上车", syllables: ["shang", "che"]),
]

public final class DemoEngine: EngineBackend {
    public var kind: EngineBackendKind { .demoSimulator("内嵌 43 词演示词表") }

    private var sharedDirectory: URL?
    private var userDirectory: URL?
    private var schemaID = BuiltinTemplateSchemas.quanpin
    private var encoding: LayoutCodeProjector.Encoding = .fullPinyin
    private var composedCode: String = ""

    public init() {}

    public func setup(sharedDirectory: URL, userDirectory: URL) throws {
        // The demo engine does not deploy; it only records the directories for UI display.
        self.sharedDirectory = sharedDirectory
        self.userDirectory = userDirectory
    }

    public func selectSchema(_ schemaID: String) throws {
        guard let encoding = LayoutCodeProjector.Encoding(schemaID: schemaID) else {
            throw EngineBackendError.unsupportedSchema(schemaID)
        }
        self.schemaID = schemaID
        self.encoding = encoding
        composedCode = ""
    }

    public var statusSummary: String {
        let dir = userDirectory?.lastPathComponent ?? "（未设置）"
        return "演示引擎 · 输入方案 \(schemaID) · 用户目录 \(dir)"
    }

    // MARK: Key handling

    public func processKey(_ keyValue: String) throws -> EngineSnapshot {
        switch keyValue {
        case "\u{08}":  // backspace
            if !composedCode.isEmpty {
                composedCode.removeLast()
            }
        case " ":  // space: confirm candidate (default index 0)
            if let snapshot = try confirmHighlightedOrCommitRaw(emptyCommitText: " ") {
                return snapshot
            }
        case "\n":  // enter: confirm candidate; the upper layer sends a newline for an empty composition
            if let snapshot = try confirmHighlightedOrCommitRaw(emptyCommitText: "\n") {
                return snapshot
            }
        case "Esc":  // cancel composition
            composedCode = ""
        default:
            // Accept only logical codes within the current layout's alphabet
            guard alphabetContains(keyValue) else { return currentSnapshot() }
            composedCode.append(keyValue)
        }
        return currentSnapshot()
    }

    /// While composing with candidates, confirms index 0 and returns a snapshot with committed;
    /// while composing without candidates, commits the raw code; an empty composition returns
    /// an empty snapshot carrying emptyCommitText.
    private func confirmHighlightedOrCommitRaw(emptyCommitText: String) throws -> EngineSnapshot? {
        if !composedCode.isEmpty {
            let matches = computeMatches()
            if !matches.isEmpty {
                return try commitMatch(matches[0])
            }
            let raw = composedCode
            composedCode = ""
            return snapshot(committed: raw)
        }
        return snapshot(committed: emptyCommitText)
    }

    public func selectCandidate(_ index: Int) throws -> EngineSnapshot {
        let matches = computeMatches()
        guard matches.indices.contains(index) else {
            throw EngineBackendError.notReady
        }
        return try commitMatch(matches[index])
    }

    private func commitMatch(_ match: Match) throws -> EngineSnapshot {
        composedCode = String(composedCode.dropFirst(match.code.count))
        return snapshot(committed: match.word.text)
    }

    public func nextPage() throws -> EngineSnapshot { currentSnapshot() }
    public func previousPage() throws -> EngineSnapshot { currentSnapshot() }

    public func currentSnapshot() -> EngineSnapshot { snapshot() }

    public func shutdown() {
        composedCode = ""
        sharedDirectory = nil
        userDirectory = nil
    }

    // MARK: Internals

    private func alphabetContains(_ value: String) -> Bool {
        // The 1 key and other non-code keys do not enter the composition.
        value.count == 1 && value.first.map(encoding.accepts) == true
    }

    private struct Match {
        let word: DemoWord
        let code: String
    }

    private func computeMatches() -> [Match] {
        guard !composedCode.isEmpty else { return [] }
        var result: [Match] = []
        for word in demoVocabulary {
            let code = LayoutCodeProjector.composeCode(syllables: word.syllables, for: encoding)
            guard !code.isEmpty else { continue }
            if code.hasPrefix(composedCode) {
                result.append(Match(word: word, code: code))
            }
        }
        // A full-code hit (the whole word typed) ranks first, matching intuition; still demo ordering.
        result.sort { lhs, rhs in
            let lhsFull = lhs.code.count == composedCode.count
            let rhsFull = rhs.code.count == composedCode.count
            if lhsFull != rhsFull { return lhsFull }
            return lhs.code.count < rhs.code.count
        }
        return Array(result.prefix(9))
    }

    private func snapshot(committed: String = "") -> EngineSnapshot {
        let matches = computeMatches()
        var candidates: [Candidate] = []
        for (offset, m) in matches.enumerated() {
            // The comment shows the word's full input code (space between syllables) to compare against the layout code in the demo.
            let spaced = m.code.map { String($0) }.joined(separator: " ")
            candidates.append(Candidate(index: offset, text: m.word.text, comment: spaced))
        }
        let isComposing = !composedCode.isEmpty
        return EngineSnapshot(
            committed: committed,
            candidates: candidates,
            preedit: composedCode,
            rawInput: composedCode,
            isComposing: isComposing,
            highlightedIndex: isComposing && !candidates.isEmpty ? 0 : -1
        )
    }
}
