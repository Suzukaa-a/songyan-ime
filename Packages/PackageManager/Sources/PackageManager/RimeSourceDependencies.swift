import Darwin
import Foundation

/// Resolve external dependencies against the *actual file inventories* of plum's official
/// preset repositories. No filename-to-brand guess, no unbounded GitHub code search.
public enum RimeSourceDependencies {
    public static func acquire(
        for explicit: [AcquiredRimeSource], existingFiles: [String: Data] = [:],
        sharedOpenCCDirectory: URL? = nil,
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> [AcquiredRimeSource] {
        // One ephemeral transport for the whole dependency resolution: every index
        // query and every dependency download shares it instead of one session per file.
        let transport = HTTPSResourceTransport()
        defer { transport.invalidate() }
        var dependencies: [AcquiredRimeSource] = []
        var inventories: [String: Set<String>]? = nil
        for _ in 0..<16 {
            try Task.checkCancellation()
            let sources = dependencies + explicit
            var files = existingFiles
            for source in sources {
                for (path, data) in source.files
                where source.recipe.installPatterns.contains(where: { fnmatch($0, path, FNM_PATHNAME) == 0 }) {
                    files[path] = data
                }
                // Declared external bytes are supplied in the following explicit UI step;
                // do not replace them with an unrelated repository's similarly named file.
                for resource in source.recipe.downloads where files[resource.path] == nil {
                    files[resource.path] = Data()
                }
            }
            let missing = try SchemeSourceCheck.missingDependencies(files).filter { path in
                guard path.hasPrefix("opencc/"), let sharedOpenCCDirectory else { return true }
                return !FileManager.default.fileExists(
                    atPath: sharedOpenCCDirectory.appendingPathComponent(String(path.dropFirst(7))).path)
            }
            if missing.isEmpty { return sources }
            if inventories == nil {
                progress("正在查询官方依赖列表…")
                var found: [String: Set<String>] = [:]
                for order in try await RimeSourceOrder.expand(":preset", transport: transport) {
                    struct Tree: Decodable {
                        struct Entry: Decodable {
                            let path: String
                            let type: String
                        }
                        let truncated: Bool
                        let tree: [Entry]
                    }
                    let url = URL(
                        string: "https://api.github.com/repos/\(order.repository)/git/trees/HEAD?recursive=1")!
                    let tree = try JSONDecoder().decode(
                        Tree.self, from: await transport.read(url, maximumBytes: 8 * 1024 * 1024))
                    guard !tree.truncated else {
                        throw RecipeInstallError.invalidResource("官方源文件索引被截断：\(order.repository)")
                    }
                    found[order.repository] = Set(tree.tree.filter { $0.type == "blob" }.map(\.path))
                }
                inventories = found
            }
            var providers = Set<String>()
            let acquired = Set(sources.map { $0.order.repository })
            for path in missing {
                let matches = inventories!.filter { $0.value.contains(path) }.map(\.key)
                guard matches.count == 1, let provider = matches.first, !acquired.contains(provider) else {
                    throw RecipeInstallError.invalidResource("依赖项 \(path) 没有唯一可用的官方来源；请在来源列表中明确添加提供该文件的仓库。")
                }
                providers.insert(provider)
            }
            for repository in providers.sorted() {
                let sourceBytes = (dependencies + explicit).reduce(0) {
                    $0 + $1.files.values.reduce(0) { $0 + $1.count }
                }
                let modelBytes = (dependencies + explicit).reduce(0) {
                    $0 + $1.models.values.reduce(0) { $0 + $1.size }
                }
                progress("正在下载官方依赖：\(repository)")
                var dependency = try await AcquiredRimeSource.fetch(
                    RimeSourceOrder(repository),
                    sourceBudget: RecipeResourceBudget.sourceTotal - sourceBytes,
                    modelBudget: RecipeResourceBudget.modelTotal - modelBytes, progress: progress,
                    transport: transport)
                dependency.isDependency = true
                dependencies.append(dependency)
            }
        }
        throw RecipeInstallError.invalidResource("输入方案依赖层级过多（超过 16 层）；请检查是否存在循环依赖")
    }
}
