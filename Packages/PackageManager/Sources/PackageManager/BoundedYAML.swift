import Foundation
import Yams

/// Alias-bomb ("billion laughs") guard shared by every YAML read of imported or
/// installed scheme sources.
///
/// Yams' composer resolves an alias by reusing the anchored `Node` value, so the
/// composed tree is linear in the input size, but anything that *walks* or
/// *constructs* it (`Yams.load`, recursive visitors, key hashing) pays for the
/// fully expanded tree. Real Rime schemes (rime-ice etc.) use a handful of
/// `<<: *base` style aliases; we therefore cap the expanded node count instead of
/// banning aliases. Text without any alias token takes the unchanged fast path.
public enum BoundedYAML {
    /// Maximum number of nodes after alias expansion.
    public static let maximumExpandedNodes = 2_000_000
    /// Maximum number of alias tokens in one document.
    public static let maximumAliases = 100_000

    public struct LimitExceeded: Error, LocalizedError, Equatable {
        public let reason: String
        public var errorDescription: String? { "YAML 别名展开规模过大（\(reason)），已拒绝以保护设备" }
    }

    /// Drop-in replacement for `Yams.load(yaml:)`.
    public static func load(yaml text: String) throws -> Any? {
        guard try requiresExpansionCheck(text) else { return try Yams.load(yaml: text) }
        guard let node = try Yams.compose(yaml: text) else { return nil }
        try checkExpandedSize(node)
        return node.any
    }

    /// Maximum size of the alias-free preflight text, before allocating it.
    static let maximumShadowBytes = 32 * 1024 * 1024

    /// Drop-in replacement for `Yams.compose(yaml:)`; documents using aliases
    /// are guaranteed to expand to at most `maximumExpandedNodes` nodes.
    public static func compose(yaml text: String) throws -> Node? {
        guard try requiresExpansionCheck(text) else { return try Yams.compose(yaml: text) }
        guard let node = try Yams.compose(yaml: text) else { return nil }
        try checkExpandedSize(node)
        return node
    }

    /// Parse an alias-free shadow before the original can reach Yams' composer.
    /// Yams 5.x hashes mapping keys during composition and exposes no public
    /// event stream, so checking only the composed original would be too late.
    ///
    /// Every `*` is replaced, including those in comments and scalar content.
    /// The replacement is an ordinary plain-scalar prefix; a real alias therefore
    /// becomes a plain scalar beginning with it. Yams, rather than a second YAML
    /// lexer, handles block indentation, quotes, plain continuations and Unicode
    /// names. Quoted/block scalars and stars inside plain text are not aliases.
    /// The shadow is never constructed or returned to callers.
    static func requiresExpansionCheck(_ text: String, maximumShadowBytes: Int = maximumShadowBytes) throws -> Bool {
        guard text.utf8.contains(0x2A) else { return false }
        let byteCount = text.utf8.count
        let sizeError = LimitExceeded(reason: "别名安全预检超过 \(maximumShadowBytes) 字节")
        guard byteCount <= maximumShadowBytes else { throw sizeError }
        // Use a short ASCII prefix, also legal inside YAML tags. An absent
        // random prefix avoids merging ordinary keys such as 'a*b' and 'axb'.
        // Eight ASCII characters limit growth and keep typical regex keys well
        // within YAML's simple-key length limit. Large inputs fail closed below.
        var prefix: String
        repeat {
            prefix = "Y" + UUID().uuidString.prefix(7)
        } while text.contains(prefix)
        let stars = text.utf8.reduce(0) { $0 + ($1 == 0x2A ? 1 : 0) }
        // Divide before multiplying: both integer overflow and a large temporary
        // allocation must be impossible even with attacker-controlled input.
        guard stars <= (maximumShadowBytes - byteCount) / (prefix.utf8.count - 1) else { throw sizeError }
        let shadow = text.replacingOccurrences(of: "*", with: prefix)
        guard let root = try Yams.compose(yaml: shadow) else { return false }
        func isAlias(_ scalar: Node.Scalar) -> Bool {
            scalar.style == .plain && scalar.string.hasPrefix(prefix)
        }
        var aliases = 0
        var unsupportedKey = false
        var visited = 0
        var stack = [root]
        while let node = stack.popLast() {
            visited += 1
            if visited & 0xFFF == 0 { try Task.checkCancellation() }
            switch node {
            case .scalar(let scalar):
                if isAlias(scalar) {
                    aliases += 1
                    guard aliases <= maximumAliases else {
                        throw LimitExceeded(reason: "别名超过 \(maximumAliases) 个")
                    }
                }
            case .mapping(let mapping):
                for (key, value) in mapping {
                    if case .scalar(let scalar) = key {
                        unsupportedKey = unsupportedKey || isAlias(scalar)
                    } else {
                        unsupportedKey = true
                    }
                    stack.append(key)
                    stack.append(value)
                }
            case .sequence(let sequence):
                stack.append(contentsOf: sequence)
            default:
                break
            }
        }
        guard aliases > 0 else { return false }
        // Collection keys may contain aliases anywhere in their descendants;
        // reject them before composing the original, regardless of key syntax.
        if unsupportedKey { throw LimitExceeded(reason: "不支持以别名或复杂结构作为键") }
        return true
    }

    /// Iterative walk with an early abort; never visits more than the budget.
    static func checkExpandedSize(_ root: Node, maximumExpandedNodes: Int = maximumExpandedNodes) throws {
        var stack: [Node] = [root]
        var count = 0
        while let node = stack.popLast() {
            count += 1
            if count > maximumExpandedNodes { throw LimitExceeded(reason: "展开后超过 \(maximumExpandedNodes) 个节点") }
            if count & 0xFFF == 0 { try Task.checkCancellation() }
            switch node {
            case .mapping(let mapping):
                for (key, value) in mapping {
                    stack.append(key)
                    stack.append(value)
                }
            case .sequence(let sequence):
                stack.append(contentsOf: sequence)
            default:
                break
            }
        }
    }
}
