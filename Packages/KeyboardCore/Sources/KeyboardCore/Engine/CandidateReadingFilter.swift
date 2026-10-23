import Foundation

/// A real absolute candidate and optional provenance-checked pronunciation.
public struct ReadingCandidate: Equatable, Sendable, Identifiable {
    public let index: Int
    public let text: String
    public let comment: String
    public let selectKey: String?
    public let selectLabel: String?
    public let readingPaths: [[String]]?
    public let readingsComplete: Bool
    public var syllables: [String]? { readingPaths?.first }
    public var id: Int { index }
    public init(
        index: Int, text: String, syllables: [String]? = nil,
        readingPaths: [[String]]? = nil, readingsComplete: Bool = true,
        comment: String = "", selectKey: String? = nil, selectLabel: String? = nil
    ) {
        self.index = index
        self.text = text
        self.comment = comment
        self.selectKey = selectKey
        self.selectLabel = selectLabel
        self.readingPaths = readingPaths ?? syllables.map { [$0] }
        self.readingsComplete = readingsComplete && self.readingPaths != nil
    }
}

/// Read-only, incremental filtering of actual candidates, NOT a complete prism
/// syllable enumerator and NOT an engine input rewrite. Frontier always advances
/// through the unfiltered absolute list, including pages with no matches.
public struct CandidateReadingFilter: Equatable, Sendable {
    public private(set) var revision: Int = -1
    public private(set) var entries: [ReadingCandidate] = []
    public private(set) var prefix: [String] = []
    /// The last chosen reading is only the letters typed so far of a longer syllable
    /// (`h` for 好/会), so it matches every syllable it starts.
    public private(set) var prefixEndsTyped = false
    public private(set) var hasMore = true
    public private(set) var readFailed = false
    /// What was actually typed. Engine completion may rank longer words (你好吗
    /// for ni'hao); their extra syllables are never offered as reading choices.
    public private(set) var coverage: ReadingInputCoverage?
    public var nextIndex: Int { entries.count }
    public var isFiltering: Bool { !prefix.isEmpty }
    public var unclassifiedCount: Int { entries.filter { !$0.readingsComplete }.count }
    public var matches: [ReadingCandidate] {
        guard isFiltering else { return entries }
        return entries.filter(matchesPrefix)
    }
    /// Syllables whose every letter is a typed key come first, longer ones before
    /// shorter (`4264` → `gang`, `hang`, then `ha`), then syllables the scheme reaches
    /// another way (an initial standing for the syllable, `mo` for `6`; a derived
    /// spelling, `chang` for `4264`), then the letters of a syllable still being
    /// typed (`g`/`h` for one last key, not the guessed 好/会/还 readings). Within a
    /// group the more common Mandarin syllable leads, like mainstream 9-key pinyin,
    /// when every reading is a Mandarin syllable; otherwise the engine's order is
    /// kept. Only readings of real candidates are offered, so every choice still
    /// filters to something. The chosen syllables consume as many typed keys as they
    /// can (`ni` takes both keys of `64'4`, `hao` the last one), so a choice that
    /// already spells every typed key offers no further syllable from a longer
    /// completion (你好坏).
    public var options: [String] {
        let common = SyllableOrder.commonRank(for: choices.map(\.syllable))
        var best: [String: (group: Int, length: Int, rank: Int, order: Int)] = [:]
        for (order, choice) in choices.enumerated() {
            let group = choice.value != choice.syllable ? 2 : (choice.spelledInFull ? 0 : 1)
            // Length only says something when the typed keys are known.
            let length = group == 0 && coverage != nil ? choice.syllable.count : 0
            let rank = common[choice.syllable] ?? Int.max
            if let known = best[choice.value] {
                guard group <= known.group else { continue }
                best[choice.value] = (
                    group, length,
                    group == known.group ? min(rank, known.rank) : rank, known.order
                )
            } else {
                best[choice.value] = (group, length, rank, order)
            }
        }
        return best.sorted { left, right in
            let a = left.value, b = right.value
            if a.group != b.group { return a.group < b.group }
            if a.length != b.length { return a.length > b.length }
            return a.rank != b.rank ? a.rank < b.rank : a.order < b.order
        }.map(\.key)
    }

    /// Each offered reading with the whole syllable it stands for. Without a trusted key
    /// map every reading stays offered, and the plain map still tells which ones the
    /// typed keys spell letter for letter.
    private var choices: [(value: String, syllable: String, spelledInFull: Bool)] {
        let bound = trustedCoverage
        let start = bound?.farthestEnd(of: prefix[...])
        if let bound, let start, start >= bound.keys.count { return [] }
        let literalStart = coverage?.farthestEnd(of: prefix[...])
        return matches.filter(\.readingsComplete).flatMap { $0.readingPaths ?? [] }.compactMap { syllables in
            guard syllables.indices.contains(prefix.count), startsWithPrefix(syllables) else { return nil }
            let syllable = syllables[prefix.count]
            guard let bound, let start else {
                guard let coverage else { return (syllable, syllable, true) }
                let literal = literalStart.map { coverage.spellsInFull(syllable, from: $0) } ?? false
                return (syllable, syllable, literal)
            }
            guard bound.fits(syllables[prefix.count...].prefix(1), from: start) else { return nil }
            return (bound.typedChoice(syllable, from: start), syllable, bound.spellsInFull(syllable, from: start))
        }
    }

    /// The key map is only trusted when the engine's first complete candidate spells
    /// exactly the typed keys; a scheme whose codes are not its readings (for example
    /// double pinyin) keeps every engine reading rather than losing real choices.
    private var trustedCoverage: ReadingInputCoverage? {
        guard let coverage, let first = entries.first(where: \.readingsComplete),
            (first.readingPaths ?? []).contains(where: { coverage.fits($0[...], consumingAll: true) })
        else { return nil }
        return coverage
    }
    /// How many of `page` would match the current reading prefix.
    public func matchCount(in page: [ReadingCandidate]) -> Int {
        guard isFiltering else { return page.count }
        return page.filter(matchesPrefix).count
    }
    /// A candidate matches when its reading continues the chosen syllables, or spells
    /// their first 1…n syllables (课程 and 可 for a chosen `ke cheng xing`): choosing
    /// a reading narrows the list, it does not force a word of exactly that length.
    private func matchesPrefix(_ entry: ReadingCandidate) -> Bool {
        entry.readingsComplete
            && (entry.readingPaths ?? []).contains { path in
                Self.continues(path, prefix, endsTyped: prefixEndsTyped)
            }
    }
    /// `path` reads as every chosen syllable (the last one possibly only begun).
    public func startsWithPrefix(_ path: [String]) -> Bool {
        path.count >= prefix.count && Self.continues(path, prefix, endsTyped: prefixEndsTyped)
    }
    /// `path` starts with `prefix`, or is a non-empty leading part of it. With
    /// `endsTyped`, the last prefix element only has to begin its syllable.
    public static func continues(_ path: [String], _ prefix: [String], endsTyped: Bool = false) -> Bool {
        guard !path.isEmpty else { return prefix.isEmpty }
        return zip(path, prefix).enumerated().allSatisfy { index, pair in
            pair.0 == pair.1 || (endsTyped && index == prefix.count - 1 && pair.0.hasPrefix(pair.1))
        }
    }
    public init() {}
    public mutating func reset(revision: Int) {
        guard self.revision != revision else { return }
        self = Self()
        self.revision = revision
    }
    public mutating func append(_ page: [ReadingCandidate], requested: Int, revision: Int) {
        guard self.revision == revision, requested > 0,
            page.enumerated().allSatisfy({ $0.element.index == entries.count + $0.offset })
        else { return }
        entries += page
        hasMore = page.count == requested
        readFailed = false
    }
    public mutating func failed() { readFailed = true }
    public mutating func setCoverage(_ value: ReadingInputCoverage?) {
        if coverage != value { coverage = value }
    }
    /// A reading has one selection path: the real reading item on the left calls `select`
    /// directly. There is no right-hand `cycleSelection`-style entry.
    public mutating func select(_ reading: String) {
        let offered = choices.filter { $0.value == reading }
        guard !offered.isEmpty else { return }
        prefix.append(reading)
        prefixEndsTyped = offered.contains { $0.syllable != reading }
    }
    /// Only the last chosen reading can be a begun syllable, so undoing leaves whole ones.
    public mutating func undoSelection() {
        if !prefix.isEmpty { prefix.removeLast() }
        prefixEndsTyped = false
    }
    public mutating func clearSelection() {
        prefix = []
        prefixEndsTyped = false
    }
}

/// Typed compact keys that a reading path must fit into. A syllable is typed in
/// full, abbreviated to its initial (`n`, `zh`/`z`), or still being typed when it
/// reaches the end of the input; a separator ends a syllable. Pure value.
public struct ReadingInputCoverage: Equatable, Sendable {
    public static let separator: Character = "'"
    public let keys: [Character]
    public let keyForLetter: [Character: Character]
    /// Keys that type one letter exactly (`CompactFold.exactTokens`, token → letter).
    public let exactKeys: [Character: Character]

    public init?(input: String, keyForLetter: [Character: Character], exactKeys: [Character: Character] = [:]) {
        let keys = Array(input.lowercased())
        guard !keys.isEmpty, !keyForLetter.isEmpty else { return nil }
        self.keys = keys
        self.keyForLetter = keyForLetter
        self.exactKeys = exactKeys
    }

    public func fits(_ syllables: ArraySlice<String>, consumingAll: Bool) -> Bool {
        guard let reachable = reachable(syllables, from: 0) else { return false }
        return !consumingAll || reachable.contains(keys.count)
    }

    /// `syllables` fit the keys that follow position `start`.
    public func fits(_ syllables: ArraySlice<String>, from start: Int) -> Bool {
        reachable(syllables, from: start) != nil
    }

    /// How `syllable` reads over the keys from `start`: whole when it fits, otherwise
    /// the letters typed so far when it runs to the end of the input (`hao` over one
    /// last key → `h`); an abbreviation inside the input keeps the whole syllable.
    public func typedChoice(_ syllable: String, from start: Int) -> String {
        let position = skipSeparators(start)
        let letters = Array(syllable.lowercased())
        let remaining = keys.count - position
        guard !matches(letters[...], at: position), remaining > 0, remaining < letters.count,
            matches(letters[..<remaining], at: position)
        else { return syllable }
        return String(letters[..<remaining])
    }

    /// Every letter of `syllable` was typed from `start`, not just its initial.
    public func spellsInFull(_ syllable: String, from start: Int) -> Bool {
        matches(Array(syllable.lowercased())[...], at: skipSeparators(start))
    }

    /// The farthest key position any parse of `syllables` reaches (after separators);
    /// nil when they do not fit.
    public func farthestEnd(of syllables: ArraySlice<String>) -> Int? {
        reachable(syllables, from: 0)?.max()
    }

    private func reachable(_ syllables: ArraySlice<String>, from origin: Int) -> Set<Int>? {
        var reachable: Set<Int> = [skipSeparators(origin)]
        for syllable in syllables {
            let letters = Array(syllable.lowercased())
            guard !letters.isEmpty else { return nil }
            var lengths: Set<Int> = [1, letters.count]
            if letters.count > 2, letters[1] == "h", "zcs".contains(letters[0]) { lengths.insert(2) }
            var next = Set<Int>()
            for start in reachable {
                for length in lengths.union([keys.count - start]) where length > 0 && length <= letters.count {
                    if matches(letters[..<length], at: start) { next.insert(skipSeparators(start + length)) }
                }
            }
            guard !next.isEmpty else { return nil }
            reachable = next
        }
        return reachable
    }

    /// The letters of each syllable that the typed keys actually cover (`bu guo`
    /// for three keys → `bu`, `g`), preferring whole syllables. nil when no parse
    /// consumes every typed key, e.g. a candidate covering only part of the input.
    public func typedSpelling(_ syllables: [String]) -> [String]? {
        var failed = Set<[Int]>()
        func search(_ index: Int, _ start: Int) -> [String]? {
            let position = skipSeparators(start)
            guard index < syllables.count else { return position == keys.count ? [] : nil }
            guard !failed.contains([index, position]) else { return nil }
            let letters = Array(syllables[index].lowercased())
            var lengths: Set<Int> = [1, letters.count, keys.count - position]
            if letters.count > 2, letters[1] == "h", "zcs".contains(letters[0]) { lengths.insert(2) }
            for length in lengths.sorted(by: >) where length > 0 && length <= letters.count {
                guard matches(letters[..<length], at: position),
                    let rest = search(index + 1, position + length)
                else { continue }
                return [String(letters[..<length])] + rest
            }
            failed.insert([index, position])
            return nil
        }
        return syllables.isEmpty ? nil : search(0, 0)
    }

    private func matches(_ letters: ArraySlice<Character>, at start: Int) -> Bool {
        guard start + letters.count <= keys.count else { return false }
        return zip(keys[start...], letters).allSatisfy { key, letter in
            key != Self.separator && (key == letter || keyForLetter[letter] == key || exactKeys[key] == letter)
        }
    }

    private func skipSeparators(_ position: Int) -> Int {
        var position = position
        while position < keys.count, keys[position] == Self.separator { position += 1 }
        return position
    }
}

/// Build one UI batch through bounded engine hops. The caller supplies its serial
/// engine queue and composition guard; no partial result escapes on failure.
public enum CandidateReadingBatch {
    public enum ReadError: Error { case invalidRequest, invalidPage }

    @MainActor
    /// `enough` ends the batch early (checked after each hop), e.g. once a filtered
    /// row has enough matches; the batch is still published as one update.
    public static func read(
        fromIndex: Int, count: Int, quantum: Int,
        isCurrent: () -> Bool,
        enough: ([ReadingCandidate]) -> Bool = { _ in false },
        fetch: (Int, Int) async throws -> [ReadingCandidate]?
    ) async throws -> [ReadingCandidate]? {
        guard fromIndex >= 0, count > 0, count <= 64, quantum > 0, quantum <= 8,
            fromIndex <= Int.max - count
        else { throw ReadError.invalidRequest }
        var batch: [ReadingCandidate] = []
        while batch.count < count {
            guard isCurrent() else { throw CancellationError() }
            let offset = fromIndex + batch.count
            let requested = min(quantum, count - batch.count)
            guard let page = try await fetch(offset, requested) else { return nil }
            guard page.count <= requested,
                page.enumerated().allSatisfy({ $0.element.index == offset + $0.offset })
            else {
                throw ReadError.invalidPage
            }
            batch.append(contentsOf: page)
            if page.count < requested || enough(batch) { break }
        }
        guard isCurrent() else { throw CancellationError() }
        return batch
    }
}

/// Ordering shared by every rail list. Pure value logic.
public enum SyllableOrder {
    /// Mandarin frequency ranks, or none when any syllable is not Mandarin (Cantonese,
    /// a scheme's own codes): those lists keep the engine's order.
    public static func commonRank(for syllables: [String]) -> [String: Int] {
        let table = SentenceSpelling.commonSyllableRank
        return syllables.allSatisfy { table[$0] != nil } ? table : [:]
    }

    /// The engine's lockable spellings of one typed segment arrive alphabetically. A
    /// spelling whose letters are exactly the typed keys (`gang`, `hang` for `4264`)
    /// comes before one the scheme derives by dropping or moving letters (`chang` →
    /// `hcng`), each group the more common Mandarin syllable first. Nothing is added
    /// or removed, so every option is still the engine's.
    public static func spellingOptions(
        _ options: [String], typedKeys: String,
        keyForLetter: [Character: Character]
    ) -> [String] {
        guard !keyForLetter.isEmpty, !typedKeys.isEmpty else { return options }
        let common = commonRank(for: options)
        func literal(_ option: String) -> Bool {
            let keys = option.lowercased().compactMap { keyForLetter[$0] }
            return keys.count == option.count && String(keys) == typedKeys
        }
        return options.enumerated().sorted { left, right in
            let a = literal(left.element), b = literal(right.element)
            if a != b { return a }
            let x = common[left.element] ?? Int.max, y = common[right.element] ?? Int.max
            return x != y ? x < y : left.offset < right.offset
        }.map(\.element)
    }

    /// The typed keys a report's segment covers, nil when it does not lie in `input`.
    public static func typedKeys(of report: AmbiguitySpellingsReport, in input: String) -> String? {
        let bytes = Array(input.utf8)
        guard report.segment.lowerBound >= 0, report.segment.upperBound <= bytes.count else { return nil }
        return String(decoding: bytes[report.segment], as: UTF8.self)
    }
}
