import Foundation

/// Next-word guesses for the ABC page after a finished word (`I've` → been, got,
/// never). The engine's own post-commit prediction (librime-predict, or a scheme's)
/// works on engine commits only, never on letters typed directly on the ABC page, so
/// the keyboard carries a small built-in table of common English continuations. It also remembers word pairs the user
/// actually typed during this process lifetime; those rank first. Nothing is
/// written to disk. Pure value.
public struct EnglishNextWordModel: Equatable, Sendable {
    /// Learned pairs kept, oldest dropped first.
    public static let learnedCapacity = 512
    private var learned: [String: [String: Int]] = [:]
    private var learnedOrder: [String] = []

    public init() {}

    /// Up to `limit` continuations of `previous` (case-insensitive), learned ones first.
    public func predictions(after previous: String, limit: Int = 3) -> [String] {
        let key = Self.normalized(previous)
        guard !key.isEmpty, limit > 0 else { return [] }
        var result: [String] = []
        let typed = (learned[key] ?? [:]).sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        for (word, _) in typed where !result.contains(word) {
            result.append(word)
        }
        for word in Self.seed[key] ?? [] where !result.contains(word) {
            result.append(word)
        }
        return Array(result.prefix(limit))
    }

    /// Remember that the user typed `next` right after `previous`.
    public mutating func learn(_ previous: String, _ next: String) {
        let key = Self.normalized(previous), value = Self.normalized(next)
        guard !key.isEmpty, !value.isEmpty, value.count <= 24 else { return }
        if learned[key] == nil {
            learnedOrder.append(key)
            if learnedOrder.count > Self.learnedCapacity {
                learned[learnedOrder.removeFirst()] = nil
            }
        }
        learned[key, default: [:]][value, default: 0] += 1
    }

    /// Lowercased with typographic apostrophes folded, so `I’ve` and `i've` match.
    static func normalized(_ word: String) -> String {
        word.replacingOccurrences(of: "’", with: "'").lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "'-"))
    }

    /// Common continuations of frequent English words and contractions.
    static let seed: [String: [String]] = [
        "i": ["am", "have", "think", "will", "don't"],
        "i've": ["been", "got", "never", "seen", "had"],
        "i'm": ["not", "going", "so", "sure", "sorry"],
        "i'll": ["be", "have", "see", "never", "try"],
        "i'd": ["like", "love", "be", "rather", "have"],
        "you": ["can", "are", "have", "know", "will"],
        "you're": ["not", "welcome", "right", "going", "so"],
        "you've": ["been", "got", "never", "done", "seen"],
        "you'll": ["be", "see", "have", "need", "find"],
        "we": ["are", "have", "can", "will", "need"],
        "we're": ["going", "not", "all", "here", "still"],
        "we've": ["been", "got", "had", "never", "done"],
        "we'll": ["be", "see", "have", "need", "get"],
        "they": ["are", "have", "were", "will", "can"],
        "they're": ["not", "going", "all", "still", "just"],
        "they've": ["been", "got", "never", "had", "done"],
        "he": ["is", "was", "has", "said", "will"],
        "she": ["is", "was", "has", "said", "will"],
        "he's": ["not", "a", "been", "going", "just"],
        "she's": ["not", "a", "been", "going", "just"],
        "it": ["is", "was", "will", "has", "would"],
        "it's": ["a", "not", "been", "the", "just"],
        "that": ["is", "was", "the", "you", "it"],
        "that's": ["a", "not", "the", "what", "why"],
        "there": ["is", "are", "was", "were", "will"],
        "there's": ["a", "no", "nothing", "something", "the"],
        "this": ["is", "was", "one", "time", "week"],
        "what": ["is", "are", "do", "about", "happened"],
        "what's": ["the", "up", "going", "your", "new"],
        "how": ["are", "to", "about", "do", "much"],
        "how's": ["it", "your", "the", "everything", "work"],
        "where": ["are", "is", "do", "did", "can"],
        "when": ["you", "I", "is", "we", "are"],
        "why": ["not", "is", "do", "did", "are"],
        "who": ["is", "are", "was", "knows", "did"],
        "can": ["you", "I", "we", "be", "not"],
        "can't": ["wait", "be", "believe", "find", "help"],
        "could": ["you", "be", "not", "have", "I"],
        "would": ["you", "be", "like", "have", "love"],
        "should": ["be", "have", "I", "we", "not"],
        "will": ["be", "you", "not", "have", "do"],
        "won't": ["be", "have", "let", "work", "happen"],
        "don't": ["know", "have", "want", "think", "worry"],
        "doesn't": ["matter", "work", "have", "mean", "make"],
        "didn't": ["know", "have", "want", "see", "get"],
        "isn't": ["it", "a", "the", "that", "working"],
        "wasn't": ["a", "sure", "able", "the", "it"],
        "haven't": ["been", "seen", "had", "got", "heard"],
        "do": ["you", "not", "it", "we", "they"],
        "does": ["it", "not", "that", "this", "anyone"],
        "did": ["you", "not", "it", "I", "they"],
        "is": ["it", "a", "the", "not", "there"],
        "are": ["you", "we", "they", "not", "there"],
        "was": ["a", "the", "not", "it", "so"],
        "were": ["you", "not", "the", "in", "they"],
        "have": ["a", "you", "been", "to", "the"],
        "has": ["been", "a", "the", "to", "anyone"],
        "had": ["a", "to", "been", "the", "no"],
        "been": ["a", "the", "working", "there", "so"],
        "be": ["a", "the", "able", "there", "careful"],
        "get": ["the", "a", "it", "to", "back"],
        "got": ["it", "a", "to", "the", "home"],
        "go": ["to", "back", "home", "out", "for"],
        "going": ["to", "on", "out", "home", "back"],
        "want": ["to", "a", "it", "you", "the"],
        "need": ["to", "a", "help", "the", "you"],
        "like": ["a", "the", "to", "it", "this"],
        "love": ["you", "it", "the", "to", "this"],
        "thank": ["you", "god", "goodness"],
        "thanks": ["for", "a", "so", "again", "man"],
        "let": ["me", "us", "it", "you", "them"],
        "let's": ["go", "do", "see", "get", "talk"],
        "see": ["you", "the", "it", "what", "if"],
        "know": ["what", "that", "how", "the", "you"],
        "think": ["it", "so", "about", "that", "you"],
        "make": ["sure", "it", "a", "the", "me"],
        "take": ["a", "care", "the", "it", "your"],
        "come": ["on", "back", "to", "here", "over"],
        "tell": ["me", "you", "him", "her", "them"],
        "look": ["at", "for", "like", "forward", "good"],
        "looking": ["for", "forward", "at", "good", "into"],
        "talk": ["to", "about", "later", "soon", "with"],
        "call": ["me", "you", "it", "back", "him"],
        "please": ["let", "send", "call", "check", "help"],
        "good": ["morning", "night", "luck", "job", "idea"],
        "very": ["much", "good", "well", "nice", "important"],
        "so": ["much", "I", "the", "it", "that"],
        "not": ["sure", "a", "the", "really", "yet"],
        "just": ["a", "wanted", "the", "want", "got"],
        "all": ["the", "of", "right", "day", "good"],
        "one": ["of", "more", "day", "thing", "time"],
        "some": ["of", "time", "people", "more", "other"],
        "any": ["other", "more", "time", "of", "questions"],
        "no": ["problem", "one", "worries", "longer", "idea"],
        "a": ["lot", "few", "little", "good", "great"],
        "an": ["hour", "idea", "email", "issue", "example"],
        "the": ["same", "best", "first", "other", "end"],
        "my": ["own", "friend", "name", "life", "phone"],
        "your": ["own", "name", "help", "time", "phone"],
        "our": ["own", "team", "new", "first", "best"],
        "their": ["own", "new", "first", "best", "way"],
        "to": ["be", "the", "do", "get", "see"],
        "of": ["the", "a", "my", "course", "it"],
        "in": ["the", "a", "my", "your", "order"],
        "on": ["the", "a", "my", "your", "time"],
        "at": ["the", "a", "least", "home", "work"],
        "for": ["the", "a", "you", "me", "your"],
        "with": ["the", "a", "you", "me", "my"],
        "from": ["the", "a", "my", "your", "home"],
        "about": ["the", "it", "a", "this", "that"],
        "and": ["the", "I", "a", "then", "it"],
        "but": ["I", "it", "the", "not", "we"],
        "or": ["not", "the", "a", "something", "two"],
        "if": ["you", "I", "it", "we", "the"],
        "because": ["I", "it", "of", "the", "you"],
        "as": ["well", "a", "soon", "the", "much"],
        "more": ["than", "and", "time", "of", "information"],
        "right": ["now", "away", "here", "there", "back"],
        "happy": ["birthday", "new", "to", "holidays", "hour"],
        "nice": ["to", "one", "work", "day", "job"],
        "sorry": ["for", "I", "about", "to", "but"],
        "hope": ["you", "it", "to", "that", "we"],
        "miss": ["you", "it", "the", "my"],
        "wait": ["for", "a", "until", "and", "there"],
        "every": ["day", "time", "one", "week", "night"],
        "next": ["week", "time", "year", "day", "month"],
        "last": ["night", "week", "time", "year", "one"],
        "today": ["is", "I", "and", "was", "we"],
        "tomorrow": ["morning", "I", "is", "we", "night"],
        "yes": ["I", "it", "we", "please", "sir"],
        "ok": ["I", "thanks", "so", "let's", "sure"],
        "okay": ["I", "thanks", "so", "let's", "sure"],
    ]
}

/// What the ABC page's three suggestion slots show (see `KeyboardController`).
///
/// Engine predictions exist only right after an engine commit (a Chinese word, or a
/// prediction just tapped) and close on the next typed letter, so when present they are
/// the most recent context and take the row. Otherwise, after a finished English word,
/// the built-in next-word guesses; while a word is being typed, its completions.
public enum ABCSuggestionSlots {
    /// Distinct, non-empty prediction texts with their page-local candidate indices.
    public static func enginePredictions(_ snapshot: EngineSnapshot, limit: Int) -> [(index: Int, text: String)] {
        guard snapshot.isPrediction, limit > 0 else { return [] }
        var seen = Set<String>()
        var slots: [(index: Int, text: String)] = []
        for candidate in snapshot.candidates where !candidate.text.isEmpty && seen.insert(candidate.text).inserted {
            slots.append((candidate.index, candidate.text))
            if slots.count == limit { break }
        }
        return slots
    }
}
