import Foundation

/// A fixed window at each side of the insertion point. Proxy context length can
/// change without a document edit; compare the same adjacent units on both reads.
/// Document identity and write generation are checked separately by the host.
public struct ProxyDocumentContext: Equatable, Sendable {
    public static let windowUTF16 = 32
    public let before: String?
    public let after: String?
    public let selected: String?

    public init(before: String?, after: String?, selected: String?) {
        self.before = before.map { Self.adjacent($0, fromEnd: true) }
        self.after = after.map { Self.adjacent($0, fromEnd: false) }
        self.selected = selected?.isEmpty == false ? selected : nil
    }

    /// Keep whole characters, including emoji and combining marks. Never accept
    /// unequal short windows just because they share a suffix or prefix.
    private static func adjacent(_ text: String, fromEnd: Bool) -> String {
        var units = 0
        if fromEnd {
            var start = text.endIndex
            while start > text.startIndex {
                let previous = text.index(before: start)
                let count = text[previous..<start].utf16.count
                guard units == 0 || units + count <= windowUTF16 else { break }
                units += count
                start = previous
            }
            return String(text[start...])
        }
        var end = text.startIndex
        while end < text.endIndex {
            let next = text.index(after: end)
            let count = text[end..<next].utf16.count
            guard units == 0 || units + count <= windowUTF16 else { break }
            units += count
            end = next
        }
        return String(text[..<end])
    }
}
