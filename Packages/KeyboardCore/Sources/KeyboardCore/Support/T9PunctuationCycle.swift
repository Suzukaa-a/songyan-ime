import Foundation

/// Short multi-taps replace only the punctuation inserted by the previous tap.
public struct T9PunctuationCycle {
    public static let interval: TimeInterval = 0.8
    public static let contextLimit = 128
    public struct Edit: Equatable {
        public let index: Int
        public let text: String
        public let replacing: String?
        public let expectedContext: String?
    }
    private struct Pending {
        let symbols: [String]
        let index: Int
        let context: String
        let timestamp: TimeInterval
        let revision: Int
    }
    private var pending: Pending?
    public init() {}

    public func next(symbols: [String], context: String?, now: TimeInterval, revision: Int) -> Edit? {
        guard !symbols.isEmpty, symbols.allSatisfy({ !$0.isEmpty }) else { return nil }
        if let pending, let context,
            pending.symbols == symbols, pending.revision == revision,
            now >= pending.timestamp, now - pending.timestamp < Self.interval,
            String(context.suffix(Self.contextLimit)) == pending.context,
            context.hasSuffix(symbols[pending.index])
        {
            let index = (pending.index + 1) % symbols.count
            return Edit(
                index: index, text: symbols[index], replacing: symbols[pending.index],
                expectedContext: pending.context)
        }
        return Edit(
            index: 0, text: symbols[0], replacing: nil,
            expectedContext: context.map { String($0.suffix(Self.contextLimit)) })
    }

    public mutating func record(_ edit: Edit, symbols: [String], context: String?, now: TimeInterval, revision: Int) {
        reset()
        guard symbols.indices.contains(edit.index), symbols[edit.index] == edit.text,
            let expected = edit.expectedContext, let context
        else { return }
        let prefix = edit.replacing.map { String(expected.dropLast($0.count)) } ?? expected
        let predicted = String((prefix + edit.text).suffix(Self.contextLimit))
        let observed = String(context.suffix(Self.contextLimit))
        // A keyboard extension's document context often still shows the text from
        // before the write. Arm on the predicted text; the next tap's fresh context
        // must equal it, so a write that never landed is not replaced. A context
        // that changed into something else, or a bounded context that cannot tell
        // the write apart, never arms.
        guard predicted != expected, observed == predicted || observed == expected else { return }
        pending = Pending(
            symbols: symbols, index: edit.index, context: predicted,
            timestamp: now, revision: revision)
    }

    public mutating func reset() { pending = nil }
}
