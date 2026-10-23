import Foundation
import KeyboardCore
import Yams

// MARK: - Adapter eligibility (explicit "unsupported" vs. real errors)
//
// `CompactSchemaAdapter.generate` reports both "schema is not an auto-adaptable primary
// producer configuration" and real errors (compiled source over budget, YAML parse failure,
// schema identity mismatch) as `RecipeInstallError`. A display-capability generator that
// used `try?` would collapse all of them into native, disguising budget/read/parse/identity
// failures as "this source has no capability" and writing a false completion marker.
//
// This classifier separates the two:
//   * `.unsupported`: the schema is not a sole DEFAULT script/table primary producer
//     (legitimately native; named-only also fails closed here, never "classify adaptable,
//     then throw");
//   * `.adaptable`: may enter generation;
//   * throws: budget/read/parse/missing identity are real errors; abort the transaction
//     and write no marker.
//
// Primary-producer selection (`primaryProducer`) matches native `single_producer`: prefer
// the sole default entry without `@`; two defaults are rejected as mixed provenance; with
// no default, a single named entry is used as a read-only fallback. Auxiliary entries
// (`@custom_phrase`, `lua_translator@…`, etc.) never count as primary nor make it mixed.
public extension CompactSchemaAdapter {
    enum Adaptability: Equatable, Sendable {
        case adaptable
        case unsupported(String)
    }

    /// The class of the single provable primary producer.
    enum ProducerClass: String, Equatable, Sendable {
        case script = "script_translator"
        case table = "table_translator"
    }

    /// The single primary producer of a schema's `engine/translators`, mirroring
    /// the native `single_producer`/`ProducerRef` algorithm EXACTLY so eligibility,
    /// dispatch and the native binding can never disagree:
    ///   * a producer is a `script_translator` or `table_translator` entry;
    ///   * the DEFAULT namespace is an entry written WITHOUT `@<name>` (its config
    ///     section is `translator`);
    ///   * a NAMED entry (`...@custom_phrase`, `...@lua`) is an auxiliary front-end
    ///     translator, NOT the primary syllabary source;
    ///   * if there is exactly one default producer, that is the primary;
    ///   * two or more default producers is genuinely mixed provenance -> none;
    ///   * with no default producer, exactly one named producer is used as a
    ///     read-only fallback namespace (the native display/rewrite path may still
    ///     bind to it).
    struct PrimaryProducer: Equatable, Sendable {
        public let klass: ProducerClass
        /// The producer's namespace: `translator` for a default entry, else the
        /// `@name` suffix.
        public let namespace: String
        /// True when the entry was declared WITHOUT `@<name>`.
        public let isDefaultNamespace: Bool
        public init(klass: ProducerClass, namespace: String, isDefaultNamespace: Bool) {
            self.klass = klass
            self.namespace = namespace
            self.isDefaultNamespace = isDefaultNamespace
        }
    }

    /// Resolves the primary producer from an `engine/translators` list. `nil` means
    /// no provable primary producer (none, or mixed default provenance).
    static func primaryProducer(translators: [String]) -> PrimaryProducer? {
        var defaultSlot: PrimaryProducer?
        var defaultCount = 0
        var anySlot: PrimaryProducer?
        var anyCount = 0
        for prescription in translators {
            let at = prescription.firstIndex(of: "@")
            let klass = String(at.map { prescription[..<$0] } ?? prescription[...])
            let kind: ProducerClass
            switch klass {
            case "script_translator": kind = .script
            case "table_translator": kind = .table
            default: continue
            }
            let isDefault = at == nil
            let namespace = isDefault ? "translator" : String(prescription[prescription.index(after: at!)...])
            let producer = PrimaryProducer(
                klass: kind, namespace: namespace,
                isDefaultNamespace: isDefault)
            anySlot = producer
            anyCount += 1
            if isDefault {
                defaultSlot = producer
                defaultCount += 1
            }
        }
        if defaultCount == 1 { return defaultSlot }
        if defaultCount > 1 { return nil }  // mixed provenance -> refuse
        if anyCount == 1 { return anySlot }
        return nil
    }

    /// The primary producer AUTO-GENERATION can safely adapt. The compact companion
    /// renames the schema id and the DEFAULT `translator` section (dictionary /
    /// prism / user_dict) while leaving every auxiliary entry alone, so only a unique
    /// DEFAULT primary producer is auto-adaptable. A named-only producer stays
    /// explicitly `unsupported` for generation (it may still be usable by the
    /// read-only native path) rather than being judged adaptable and then failing.
    static func autoAdaptableProducer(inCompiled compiled: Data) -> PrimaryProducer? {
        guard let text = String(data: compiled, encoding: .utf8),
            let root = try? BoundedYAML.load(yaml: text) as? [String: Any],
            let engine = root["engine"] as? [String: Any],
            let translators = engine["translators"] as? [String],
            let producer = primaryProducer(translators: translators),
            producer.isDefaultNamespace
        else { return nil }
        return producer
    }

    /// Read-only classification: generates no files and swallows no errors.
    static func adaptability(compiled: Data, sourceID: String) throws -> Adaptability {
        // Budget is a hard precondition, checked before any parse/hash work is trusted.
        guard compiled.count <= RecipeResourceBudget.sourceFile else {
            throw RecipeInstallError.invalidResource("方案编译文件超过大小限制：\(sourceID)（\(compiled.count) 字节）")
        }
        guard let text = String(data: compiled, encoding: .utf8) else {
            throw RecipeInstallError.invalidResource("方案编译文件不是 UTF-8 编码：\(sourceID)")
        }
        let root: [String: Any]
        do {
            guard let parsed = try BoundedYAML.load(yaml: text) as? [String: Any] else {
                throw RecipeInstallError.invalidResource("方案编译文件格式不正确：\(sourceID)")
            }
            root = parsed
        } catch let error as RecipeInstallError {
            throw error
        } catch {
            throw RecipeInstallError.invalidResource("方案编译文件解析失败：\(sourceID)：\(error)")
        }
        guard let schema = root["schema"] as? [String: Any],
            schema["schema_id"] as? String == sourceID
        else {
            throw RecipeInstallError.invalidResource("方案编译文件的方案标识不符：\(sourceID)")
        }
        // From here down, absence is an explicit "this scheme is not auto-adaptable".
        guard let engine = root["engine"] as? [String: Any],
            let translators = engine["translators"] as? [String]
        else {
            return .unsupported("no engine translators")
        }
        // The PRIMARY producer is the unique DEFAULT (no `@`) script/table entry.
        // Auxiliary entries such as `table_translator@custom_phrase` or
        // `lua_translator@*date_translator` are NOT the primary source and must not
        // make a real schema look mixed. Two default producers fail closed; a
        // named-only producer is explicitly unsupported for AUTO-generation (it may
        // still be usable by the read-only native path). This is the same algorithm
        // the native bridge uses, so eligibility, dispatch and native binding agree.
        guard let producer = CompactSchemaAdapter.primaryProducer(translators: translators) else {
            return .unsupported("no single primary script_translator/table_translator")
        }
        guard producer.isDefaultNamespace else {
            return .unsupported("only a default-namespace primary producer is auto-adaptable")
        }
        // The primary producer's own config section (namespace), never a hardcoded
        // `translator`.
        guard let speller = root["speller"] as? [String: Any],
            let translator = root[producer.namespace] as? [String: Any],
            let dictionary = translator["dictionary"] as? String, !dictionary.isEmpty
        else {
            throw RecipeInstallError.invalidResource("方案编译文件缺少主转换器配置或词典：\(sourceID)")
        }
        // Adaptability is about whether the letter→merged/numeric FOLD is
        // CONSTRUCTIBLE for this schema's declared physical input alphabet: the
        // compact companions fold the source's raw keys. This is the SAME shared
        // `physicalFold` contract that `generate` consumes, so a source can never
        // be judged adaptable here and then rejected there. It is unrelated to the
        // dictionary TOKENS, which may be Unicode (Bopomofo, dialect, ...): a
        // schema whose tokens are non-Latin but whose input keys are Latin is still
        // adaptable, while a schema whose physical input alphabet is itself
        // non-Latin (or empty) cannot be truthfully auto-folded and fails closed.
        //
        // A source is adaptable when AT LEAST ONE compact layout can fold its own
        // physical alphabet. A scheme whose keys are already numeric (a native
        // 9-key code space, e.g. `23456789`) folds for the 9-key companion only:
        // the 14-key layout cannot even type its keys, so only the 9-key companion
        // is generated (`prepare` skips the other layout) rather than the whole
        // source being written off as unsupported.
        let alphabet = speller["alphabet"] as? String ?? "abcdefghijklmnopqrstuvwxyz"
        let folds = KeyboardLayoutKind.allCases.compactMap(\.compactFold).contains {
            CompactSchemaAdapter.physicalFold(sourceAlphabet: alphabet, fold: $0) != nil
        }
        guard folds else {
            return .unsupported("speller alphabet is not a foldable latin/numeric input alphabet")
        }
        return .adaptable
    }
}
