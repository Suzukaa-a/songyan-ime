import Foundation

/// plum's source expression, interpreted as data. No shell evaluation is performed.
public struct RimeSourceOrder: Codable, Equatable, Sendable {
    public let expression: String
    public let repository: String
    public let ref: String?
    public let recipe: String
    public let arguments: [RecipeArgument]

    public init(_ expression: String) throws {
        let expression = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = expression.components(separatedBy: ":")
        let source = parts[0].components(separatedBy: "@")
        guard source.count <= 2, !source[0].isEmpty else { throw Self.invalid(expression) }
        let package = source[0]
        let repository =
            package.contains("/") ? package : "rime/" + (package.hasPrefix("rime-") ? package : "rime-" + package)
        guard repository.range(of: "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", options: .regularExpression) != nil,
            repository.split(separator: "/").allSatisfy({ $0 != "." && $0 != ".." })
        else { throw Self.invalid(expression) }
        let ref = source.count == 2 ? source[1] : nil
        if let ref {
            guard !ref.isEmpty, !ref.hasPrefix("/"), !ref.contains(".."),
                ref.range(of: "^[A-Za-z0-9_./-]+$", options: .regularExpression) != nil
            else { throw Self.invalid(expression) }
        }
        let recipe = parts.count > 1 ? parts[1] : ""
        guard
            recipe.isEmpty
                || (SchemeSourceCheck.safe(recipe)
                    && recipe.range(of: "^[A-Za-z0-9_./-]+$", options: .regularExpression) != nil)
        else { throw Self.invalid(expression) }
        var arguments: [RecipeArgument] = []
        for value in parts.dropFirst(2).joined(separator: ",").components(separatedBy: ",") where !value.isEmpty {
            let pair = value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, pair[0].range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil,
                pair[1].range(of: "^[A-Za-z0-9_./-]*$", options: .regularExpression) != nil
            else { throw Self.invalid(value) }
            arguments.append(.init(String(pair[0]), String(pair[1])))
        }
        self.expression = expression
        self.repository = repository
        self.ref = ref
        self.recipe = recipe
        self.arguments = arguments
    }

    private static func invalid(_ value: String) -> RecipeInstallError {
        .invalidManifest("不支持的来源格式：\(value)。正确格式为 owner/repo@ref:recipe:key=value。")
    }

    /// Strict literal subset of the actual shell package_list declaration. Reject every
    /// non-comment statement outside the array instead of ignoring executable configuration.
    public static func parseConfiguration(_ text: String) throws -> [RimeSourceOrder] {
        guard text.utf8.count <= 256 * 1024 else { throw invalid("配置文件超过 256 KiB") }
        var inside = false, found = false
        var result: [RimeSourceOrder] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if !inside {
                guard line == "package_list=(" || line == "package_list+=(" else { throw invalid("不支持的配置语句：\(line)") }
                if line == "package_list=(" { result = [] }
                inside = true
                found = true
                continue
            }
            if line == ")" {
                inside = false
                continue
            }
            for token in line.split(whereSeparator: \.isWhitespace) {
                if token.hasPrefix("#") { break }
                var value = String(token)
                if value.hasPrefix("\"") && value.hasSuffix("\"") || value.hasPrefix("'") && value.hasSuffix("'") {
                    value = String(value.dropFirst().dropLast())
                }
                result.append(try Self(value))
                guard result.count <= 64 else { throw invalid("来源列表超过 64 项") }
            }
        }
        guard found, !inside, !result.isEmpty else { throw invalid("配置列表为空或未正确闭合") }
        return result
    }

    public static let plumRevision = "b1be1969f914cc005add4090631b855db00c2591"

    public static func expand(_ target: String) async throws -> [RimeSourceOrder] {
        let transport = HTTPSResourceTransport()
        defer { transport.invalidate() }
        return try await expand(target, transport: transport)
    }

    /// Batch variant: `transport` is reused by an outer source/dependency resolution
    /// instead of creating a session for this one configuration file.
    static func expand(_ target: String, transport: HTTPSResourceTransport) async throws -> [RimeSourceOrder] {
        let target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let configuration: URL?
        if target.hasPrefix(":") {
            let name = String(target.dropFirst())
            guard name.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { throw invalid(target) }
            configuration = URL(
                string: "https://raw.githubusercontent.com/rime/plum/\(plumRevision)/\(name)-packages.conf")!
        } else if target.hasPrefix("https://") && target.hasSuffix(".conf") {
            configuration = URL(string: target)
        } else if target.hasSuffix("-packages.conf") {
            let parts = target.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count >= 3 else { throw invalid("本地 .conf 配置文件请直接从文件导入") }
            let repoRef = String(parts[0]) + "/" + String(parts[1])
            let order = try Self(repoRef)
            let path = parts.dropFirst(2).joined(separator: "/")
            guard SchemeSourceCheck.safe(path) else { throw invalid(path) }
            configuration = URL(
                string: "https://raw.githubusercontent.com/\(order.repository)/\(order.ref ?? "master")/\(path)")
        } else {
            return try target.split(whereSeparator: \.isWhitespace).map { try Self(String($0)) }
        }
        guard let configuration else { throw invalid(target) }
        let data = try await transport.read(configuration, maximumBytes: 256 * 1024)
        guard let text = String(data: data, encoding: .utf8) else { throw invalid("配置文件不是 UTF-8 编码") }
        return try parseConfiguration(text)
    }
}
