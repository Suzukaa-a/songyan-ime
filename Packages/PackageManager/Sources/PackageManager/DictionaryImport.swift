import Foundation
import KeyboardCore

public struct DictionaryImportFile: Sendable {
    /// Relative dictionary path, e.g. `words.dict.yaml` or `dicts/words.dict.yaml`.
    public let path: String
    /// A security-scoped local file (scope owned by caller), or a user-entered HTTPS URL.
    public let location: URL
    public init(path: String, location: URL) {
        self.path = path
        self.location = location
    }
}

public enum DictionaryImportError: Error, LocalizedError {
    case unsupported(String)
    case invalid(String)
    case missingDependencies([String])
    public var errorDescription: String? {
        switch self {
        case .unsupported(let detail): return "暂不支持这个词库：\(detail)"
        case .invalid(let detail): return "词库检查未通过：\(detail)"
        case .missingDependencies(let paths):
            return "还需要添加这些词库文件：\(paths.map { ($0 as NSString).lastPathComponent }.joined(separator: "、"))"
        }
    }
}

public struct DictionarySourceInspection: Sendable {
    public let path: String
    public let name: String
    public let dependencies: [String]
    public let entryCount: Int
    public let sha256: String
    public let byteCount: Int
    public let normalizesToneMarks: Bool
}

/// Immutable checked bytes; source URLs are never fetched again during installation.
public struct PreparedDictionaryImport: Sendable {
    public let manifest: RecipeManifest
    public let sources: [DictionarySourceInspection]
    public let entryCount: Int
    public let resourceBytes: Int
    let resources: [String: Data]
}

extension RecipePackageManager {
    public func inspectDictionary(_ source: DictionaryImportFile) async throws -> DictionarySourceInspection {
        let data = try await readDictionarySource(source)
        return try PinyinDictionarySource(data: data, path: source.path).inspection
    }

    /// Adds explicitly annotated words to trusted built-in templates; never executes imported config/code.
    /// `builtinResources` must be the app's read-only BuiltinPackages/Basic folder, not an imported directory.
    public func prepareDictionaryImport(
        root: DictionaryImportFile, dependencies: [DictionaryImportFile] = [],
        builtinResources: URL
    ) async throws -> PreparedDictionaryImport {
        let inputs = [root] + dependencies
        guard inputs.count <= 128, Set(inputs.map { $0.path.lowercased() }).count == inputs.count else {
            throw DictionaryImportError.invalid("一次最多选择 128 个文件，且文件名不能重复")
        }
        var parsed: [String: PinyinDictionarySource] = [:]
        var raw: [String: Data] = [:]
        var total = 0
        for source in inputs {
            try Task.checkCancellation()
            let data = try await readDictionarySource(source, maximumBytes: 64 * 1024 * 1024 - total)
            total += data.count
            guard total <= 64 * 1024 * 1024 else { throw DictionaryImportError.invalid("词库文件合计超过 64 MiB") }
            parsed[source.path] = try PinyinDictionarySource(data: data, path: source.path)
            raw[source.path] = data
        }
        var visiting = Set<String>(), visited = Set<String>(), missing = Set<String>()
        var ordered: [String] = []
        func visit(_ path: String) throws {
            if visiting.contains(path) { throw DictionaryImportError.invalid("词库引用存在循环依赖（import_tables）：\(path)") }
            if visited.contains(path) { return }
            guard let source = parsed[path] else {
                missing.insert(path)
                return
            }
            visiting.insert(path)
            for dependency in source.inspection.dependencies { try visit(dependency) }
            visiting.remove(path)
            visited.insert(path)
            ordered.append(path)
        }
        try visit(root.path)
        guard missing.isEmpty else { throw DictionaryImportError.missingDependencies(missing.sorted()) }
        guard visited.count == inputs.count else {
            throw DictionaryImportError.invalid("有文件没有被主词库引用；请只选择主词库及它引用的文件")
        }
        let count = ordered.reduce(0) { $0 + parsed[$1]!.inspection.entryCount }
        guard count > 0, count <= 2_000_000 else { throw DictionaryImportError.invalid("词库为空或超过 200 万条") }
        var resources: [String: Data] = [:]
        let schemaIDs = BuiltinTemplateSchemas.sourceSchemaIDs
        // Only known app-owned files are copied. No imported Lua, scripts, schemas or userdb.
        // The compact layouts are generated against the imported dictionary at install time,
        // so the bundled companions and their schema_list entries are left out.
        for name in ["songyan_basic.dict.yaml"] + schemaIDs.map({ "\($0).schema.yaml" }) {
            let url = builtinResources.appendingPathComponent(name)
            var data = try BoundedLocalFile.read(url, maximumBytes: RecipeResourceBudget.sourceFile)
            if name.hasSuffix(".schema.yaml") {
                guard let text = String(data: data, encoding: .utf8),
                    text.components(separatedBy: "  dictionary: songyan_basic\n").count == 2,
                    text.contains("  user_dict: songyan_shared\n")
                else {
                    throw DictionaryImportError.invalid("内置输入方案的文件不兼容：\(name)")
                }
                data = Data(
                    text.replacingOccurrences(
                        of: "  dictionary: songyan_basic\n",
                        with: "  dictionary: songyan_imported\n"
                    ).utf8)
            }
            resources[name] = data
        }
        resources["default.yaml"] = Data(
            ("config_version: \"1\"\nmenu:\n  page_size: 5\nschema_list:\n"
                + schemaIDs.map { "  - schema: \($0)\n" }.joined()).utf8)
        let signature = ordered.map { "\($0)\t\(parsed[$0]!.inspection.sha256)" }.joined(separator: "\n")
        let digest = sha256Hex(Data(signature.utf8))
        var dictionary =
            "# User-imported pinyin; original sources and notices in import-sources/.\n---\nname: songyan_imported\nversion: \"\(digest)\"\nsort: by_weight\nuse_preset_vocabulary: false\nimport_tables:\n  - songyan_basic\n...\n"
        for path in ordered {
            dictionary += parsed[path]!.rows.joined(separator: "\n") + "\n"
            resources["import-sources/\(path)"] = raw[path]
        }
        resources["songyan_imported.dict.yaml"] = Data(dictionary.utf8)
        struct Origin: Encodable {
            let path: String
            let location: String
            let sha256: String
        }
        let origins = inputs.map {
            Origin(
                path: $0.path, location: $0.location.absoluteString,
                sha256: parsed[$0.path]!.inspection.sha256)
        }
        resources["import.json"] = try JSONEncoder().encode(origins)
        resources["LICENSE"] = Data(
            "User-provided dictionary data. Original source headers and notices are preserved in import-sources/. No license is inferred or granted by importing. Conversion: explicit full pinyin normalized to toneless canonical spelling; source weights retained.\n"
                .utf8)
        let files = resources.keys.sorted().map {
            RecipeManifest.File(path: $0, sha256: sha256Hex(resources[$0]!), size: resources[$0]!.count)
        }
        let manifest = RecipeManifest(
            id: "user-pinyin", repository: "user/import", revision: String(digest.prefix(40)),
            recipePath: "import.json", license: "User-provided; original notices retained",
            schemaID: BuiltinTemplateSchemas.quanpin, requiredComponents: ["script_translator"], files: files,
            origin: .userDictionary)
        return PreparedDictionaryImport(
            manifest: manifest, sources: ordered.map { parsed[$0]!.inspection },
            entryCount: count, resourceBytes: resources.values.reduce(0) { $0 + $1.count },
            resources: resources)
    }

    @discardableResult
    public func installDictionaryImport(
        _ prepared: PreparedDictionaryImport, initialUserDataURL: URL? = nil,
        deploy: @escaping Deploy
    ) async throws -> InstalledRecipe {
        try await installResources(prepared.manifest, initialUserDataURL: initialUserDataURL, deploy: deploy) { file in
            guard let data = prepared.resources[file.path] else { throw DictionaryImportError.invalid(file.path) }
            return data
        }
    }

    /// Redeploys the active user dictionary from its own installed bytes in a fresh generation,
    /// so deploy-time products (generated keyboard adapters) follow a newer generator. Learning
    /// data is snapshotted as for an import. Returns nil when no dictionary is installed.
    @discardableResult
    public func reinstallActiveDictionary(deploy: @escaping Deploy) async throws -> InstalledRecipe? {
        guard let active = try activeInstallation() else { return nil }
        let source = active.resourceURL.deletingLastPathComponent().appendingPathComponent("source.json")
        let manifest = try JSONDecoder().decode(RecipeManifest.self, from: Data(contentsOf: source))
        guard manifest.origin == .userDictionary else { throw DictionaryImportError.invalid("已安装的内容不是词库") }
        let resources = active.resourceURL
        return try await installResources(
            manifest, initialUserDataURL: nil, deploy: deploy,
            expectedActiveGeneration: .some(active.installation.generation)
        ) { file in
            try Data(contentsOf: resources.appendingPathComponent(file.path))
        }
    }

    private func readDictionarySource(_ source: DictionaryImportFile, maximumBytes: Int = 64 * 1024 * 1024) async throws
        -> Data
    {
        try PinyinDictionarySource.validatePath(source.path)
        let data: Data
        if source.location.isFileURL {
            data = try BoundedLocalFile.read(source.location, maximumBytes: maximumBytes)
        } else {
            try HTTPSResourceReader.validate(source.location)
            data = try await fetch(source.location)
        }
        guard data.count <= maximumBytes else { throw DictionaryImportError.invalid("词库文件超过大小限制") }
        return data
    }

}

/// Intentionally a strict subset reader, not a general YAML evaluator.
/// Unsupported YAML features are rejected rather than silently changing their meaning.
private struct PinyinDictionarySource {
    let inspection: DictionarySourceInspection
    let rows: [String]

    static func validatePath(_ path: String) throws {
        guard path.hasSuffix(".dict.yaml") else {
            throw DictionaryImportError.unsupported("这里只能导入 .dict.yaml 词库文件；输入方案请在「添加输入方案」中导入")
        }
        guard path.utf8.count <= 240, !path.hasPrefix("/"),
            path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
                !$0.isEmpty && $0 != "." && $0 != ".."
                    && $0.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil
            })
        else { throw DictionaryImportError.invalid("不安全的相对路径：\(path)") }
    }

    init(data: Data, path: String) throws {
        try Self.validatePath(path)
        guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
            throw DictionaryImportError.invalid("文件不是 UTF-8 文本：\(path)")
        }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\u{feff}", with: "")
            .components(separatedBy: "\n")
        guard let end = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "..." }), end < 512 else {
            throw DictionaryImportError.unsupported("缺少 Rime 词典头结束标记「...」：\(path)")
        }
        var fields: [String: String] = [:], lists: [String: [String]] = [:]
        var currentList: String?
        for line in lines[..<end] {
            let clean = line.components(separatedBy: " #")[0].trimmingCharacters(in: .whitespaces)
            if clean.isEmpty || clean.hasPrefix("#") || clean == "---" { continue }
            if clean.hasPrefix("- "), let key = currentList {
                lists[key, default: []].append(try Self.scalar(String(clean.dropFirst(2))))
                continue
            }
            guard !line.hasPrefix(" "), let colon = clean.firstIndex(of: ":") else {
                throw DictionaryImportError.unsupported("不支持的 YAML 语法：\(path)")
            }
            let key = String(clean[..<colon])
            guard ["name", "version", "sort", "use_preset_vocabulary", "import_tables", "columns"].contains(key),
                fields[key] == nil
            else { throw DictionaryImportError.unsupported("不支持的词典头字段 \(key)") }
            let value = clean[clean.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            fields[key] = value
            currentList = nil
            if key == "import_tables" || key == "columns" {
                lists[key] = []
                if value.isEmpty {
                    currentList = key
                } else if value.hasPrefix("["), value.hasSuffix("]") {
                    let inner = value.dropFirst().dropLast()
                    lists[key] = try inner.split(separator: ",").map {
                        try Self.scalar(String($0).trimmingCharacters(in: .whitespaces))
                    }
                } else {
                    throw DictionaryImportError.unsupported("\(key) 必须是字符串列表")
                }
            } else {
                fields[key] = try Self.scalar(value)
            }
        }
        guard let name = fields["name"], !name.isEmpty else {
            throw DictionaryImportError.invalid("词典缺少名称声明（name）：\(path)")
        }
        try Self.validatePath(name + ".dict.yaml")
        guard fields["use_preset_vocabulary"] == nil || fields["use_preset_vocabulary"] == "false" else {
            throw DictionaryImportError.unsupported("此词库依赖预设词表（use_preset_vocabulary），暂不支持；请使用包含完整拼音和词频的词库")
        }
        guard fields["sort"] == nil || fields["sort"] == "by_weight" else {
            throw DictionaryImportError.unsupported("暂不支持按原始顺序排序的词库（sort: original），请使用按词频排序的词库")
        }
        let dependencies = try (lists["import_tables"] ?? []).map { value -> String in
            let file = value + ".dict.yaml"
            try Self.validatePath(file)
            return file
        }
        let columns = lists["columns"] ?? ["text", "code", "weight"]
        guard Set(columns).count == columns.count, columns.contains("text"), columns.contains("code"),
            Set(columns).isSubset(of: ["text", "code", "weight"])
        else {
            throw DictionaryImportError.unsupported("词库只能包含「词语、拼音、词频」三列，暂不支持自动注音与辅助码")
        }
        var rows: [String] = [], changed = false
        for (offset, line) in lines.dropFirst(end + 1).enumerated() {
            if line.isEmpty || line.hasPrefix("#") { continue }
            if offset % 4096 == 0 { try Task.checkCancellation() }
            let cells = line.components(separatedBy: "\t")
            // Default Rime layout allows the weight to be omitted; explicit columns are exact.
            guard cells.count == columns.count || (fields["columns"] == nil && cells.count == 2) else {
                throw DictionaryImportError.invalid("\(path):\(end + offset + 2) 列数不符合规范或缺少显式拼音")
            }
            let word = cells[columns.firstIndex(of: "text")!]
            let code = cells[columns.firstIndex(of: "code")!]
            guard !word.isEmpty, word.unicodeScalars.allSatisfy(Self.isAcceptedHan) else {
                let invalid = word.unicodeScalars.filter { !Self.isAcceptedHan($0) }
                    .map { String(format: "U+%04X", $0.value) }.joined(separator: "、")
                throw DictionaryImportError.unsupported(
                    "\(path):\(end + offset + 2) 只支持汉字词条（不支持：\(invalid.isEmpty ? "空词条" : invalid)）")
            }
            let syllables = try code.split(separator: " ").map { try Self.normalize(String($0)) }
            guard syllables.count == word.count, !syllables.isEmpty else {
                throw DictionaryImportError.unsupported("\(path):\(end + offset + 2) 字数与注音不一致")
            }
            let normalized = syllables.joined(separator: " ")
            changed = changed || normalized != code
            let weightIndex = columns.firstIndex(of: "weight")
            let weight = weightIndex.flatMap { $0 < cells.count ? cells[$0] : nil } ?? "1"
            guard weight.range(of: "^[0-9]+(?:\\.[0-9]+)?%?$", options: .regularExpression) != nil,
                weight.count <= 16
            else { throw DictionaryImportError.invalid("\(path) 词频格式无效") }
            rows.append("\(word)\t\(normalized)\t\(weight)")
            guard rows.count <= 2_000_000 else { throw DictionaryImportError.invalid("单个词库超过 200 万条") }
        }
        self.rows = rows
        inspection = DictionarySourceInspection(
            path: path, name: name, dependencies: dependencies,
            entryCount: rows.count, sha256: sha256Hex(data),
            byteCount: data.count, normalizesToneMarks: changed)
    }

    // Unicode 17.0 PropList.txt, Unified_Ideograph. Pin the assigned property,
    // not entire blocks (which include holes/symbols), or the OS ICU version:
    // supported iOS releases may predate extensions I/J. Update with Unicode.
    private static let unifiedIdeographs: [ClosedRange<UInt32>] = [
        0x3400...0x4DBF, 0x4E00...0x9FFF,
        0xFA0E...0xFA0F, 0xFA11...0xFA11, 0xFA13...0xFA14,
        0xFA1F...0xFA1F, 0xFA21...0xFA21, 0xFA23...0xFA24, 0xFA27...0xFA29,
        0x20000...0x2A6DF, 0x2A700...0x2B81D, 0x2B820...0x2CEAD,
        0x2CEB0...0x2EBE0, 0x2EBF0...0x2EE5D,
        0x30000...0x3134A, 0x31350...0x33479,
    ]

    private static func isUnifiedIdeograph(_ scalar: Unicode.Scalar) -> Bool {
        unifiedIdeographs.contains { $0.contains(scalar.value) }
    }

    private static func isAcceptedHan(_ scalar: Unicode.Scalar) -> Bool {
        // Preserve the 542 assigned supplementary compatibility ideographs accepted
        // by the old importer. These are NOT members of Unified_Ideograph; do not
        // include the unassigned tail of the block (2FA1E...2FA1F).
        isUnifiedIdeograph(scalar) || (0x2F800...0x2FA1D).contains(scalar.value)
    }

    private static func scalar(_ value: String) throws -> String {
        var result = value
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
            result = String(value.dropFirst().dropLast())
        }
        guard !result.isEmpty, !result.contains("\\"),
            result.range(of: "^[A-Za-z0-9_./%-]+$", options: .regularExpression) != nil
        else {
            throw DictionaryImportError.unsupported("不支持复杂的 YAML 格式或别名：\(value)")
        }
        return result
    }

    private static func normalize(_ input: String) throws -> String {
        var s = input.lowercased().precomposedStringWithCanonicalMapping
        s = s.replacingOccurrences(of: "u:", with: "v", options: .literal)
        for c in ["ü", "ǖ", "ǘ", "ǚ", "ǜ"] { s = s.replacingOccurrences(of: c, with: "v", options: .literal) }
        s = s.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        if let last = s.last, "12345".contains(last) { s.removeLast() }
        if s == "r" { s = "er" }
        for initial in ["j", "q", "x", "y"] {
            if s.hasPrefix(initial + "v") { s = initial + "u" + s.dropFirst(2) }
        }
        guard syllables.contains(s) else {
            throw DictionaryImportError.unsupported("拼音「\(input)」无法识别（\(s)）；仅支持全拼词库，形码、双拼、辅码词库无法直接导入。")
        }
        return s
    }

    private static let syllables = Set(
        """
        a ai an ang ao ba bai ban bang bao bei ben beng bi bian biao bie bin bing bo bu
        ca cai can cang cao ce cen ceng cha chai chan chang chao che chen cheng chi chong chou chu chua chuai chuan chuang chui chun chuo ci cong cou cu cuan cui cun cuo
        da dai dan dang dao de dei den deng di dia dian diao die ding diu dong dou du duan dui dun duo
        e ei en eng er fa fan fang fei fen feng fiao fo fou fu
        ga gai gan gang gao ge gei gen geng gong gou gu gua guai guan guang gui gun guo
        ha hai han hang hao he hei hen heng hong hou hu hua huai huan huang hui hun huo
        ji jia jian jiang jiao jie jin jing jiong jiu ju juan jue jun
        ka kai kan kang kao ke kei ken keng kong kou ku kua kuai kuan kuang kui kun kuo
        la lai lan lang lao le lei leng li lia lian liang liao lie lin ling liu lo long lou lu luan lun luo lv lve
        ma mai man mang mao me mei men meng mi mian miao mie min ming miu mo mou mu
        na nai nan nang nao ne nei nen neng ni nia nian niang niao nie nin ning niu nong nou nu nuan nun nuo nv nve
        o ou pa pai pan pang pao pei pen peng pi pian piao pie pin ping po pou pu
        qi qia qian qiang qiao qie qin qing qiong qiu qu quan que qun
        ran rang rao re ren reng ri rong rou ru rua ruan rui run ruo
        sa sai san sang sao se sen seng sha shai shan shang shao she shei shen sheng shi shou shu shua shuai shuan shuang shui shun shuo si song sou su suan sui sun suo
        ta tai tan tang tao te tei teng ti tian tiao tie ting tong tou tu tuan tui tun tuo
        wa wai wan wang wei wen weng wo wu xi xia xian xiang xiao xie xin xing xiong xiu xu xuan xue xun
        ya yan yang yao ye yi yin ying yo yong you yu yuan yue yun za zai zan zang zao ze zei zen zeng zha zhai zhan zhang zhao zhe zhei zhen zheng zhi zhong zhou zhu zhua zhuai zhuan zhuang zhui zhun zhuo zi zong zou zu zuan zui zun zuo
        """.split(whereSeparator: { $0.isWhitespace }).map(String.init))
}
