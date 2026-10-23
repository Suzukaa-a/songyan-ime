import Foundation
import KeyboardCore
import RimeKit
import os

/// One atomic file per resource/schema/switch: independent Host/extension edits do
/// not overwrite other switches. Inject the same directory to share preferences.
public struct OptionStore: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    private func file(_ option: EngineOptionDescriptor) -> URL {
        [option.resourceID, option.schemaID, option.name].reduce(directory) { url, key in
            url.appendingPathComponent(key.utf8.map { String(format: "%02x", $0) }.joined())
        }.appendingPathExtension("json")
    }

    public func value(for option: EngineOptionDescriptor) throws -> Bool? {
        let url = file(option)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(Bool.self, from: Data(contentsOf: url))
    }

    public func save(_ value: Bool, for option: EngineOptionDescriptor) throws {
        try FileManager.default.createDirectory(
            at: file(option).deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: file(option), options: .atomic)
    }
}

/// Process-wide FIFO for preference reads/writes and diagnostic receipts. Enqueue
/// happens synchronously, before the returned Task can run on another actor.
/// This is separate from the read-only KeyboardResourceReadQueue.
enum OptionPersistenceIO {
    private static let queue = DispatchQueue(label: "rime.option-persistence", qos: .utility)

    static func enqueue<T: Sendable>(_ body: @escaping @Sendable () throws -> T) -> Task<T, Error> {
        let result = Pending<T>()
        queue.async { result.finish(Result(catching: body)) }
        return Task { try await result.value() }
    }

    /// Startup only: callers already run off-main on EngineOpQueue.
    static func preload<T>(_ body: () throws -> T) rethrows -> T {
        precondition(!Thread.isMainThread, "Preference preload must run off-main")
        return try queue.sync(execute: body)
    }

    private final class Pending<T: Sendable>: Sendable {
        private let state = OSAllocatedUnfairLock<(result: Result<T, Error>?, waiter: CheckedContinuation<T, Error>?)>(
            initialState: (nil, nil))
        func finish(_ result: Result<T, Error>) {
            let waiter = state.withLock { state in
                state.result = result
                defer { state.waiter = nil }
                return state.waiter
            }
            waiter?.resume(with: result)
        }
        func value() async throws -> T {
            try await withCheckedThrowingContinuation { continuation in
                let ready = state.withLock { state -> Result<T, Error>? in
                    if let result = state.result { return result }
                    state.waiter = continuation
                    return nil
                }
                if let ready { continuation.resume(with: ready) }
            }
        }
    }
}

struct OptionPreferenceKey: Hashable, Sendable {
    let resourceID: String
    let schemaID: String
    let name: String
    init(_ descriptor: EngineOptionDescriptor) {
        resourceID = descriptor.resourceID
        schemaID = descriptor.schemaID
        name = descriptor.name
    }
}

/// Engine preference snapshot: late reads and older writes cannot replace a newer
/// local choice. Errors remain errors; nil means no saved override.
// Mutable state is guarded by `lock`.
final class OptionPreferenceCache: @unchecked Sendable {
    struct SaveOutcome: Sendable {
        let isCurrent: Bool
        let result: Result<Void, Error>
    }
    private let lock = NSLock()
    private var values: [OptionPreferenceKey: Result<Bool?, Error>] = [:]
    private var revisions: [OptionPreferenceKey: UInt64] = [:]
    private let read: @Sendable (EngineOptionDescriptor) throws -> Bool?
    private let write: @Sendable (Bool, EngineOptionDescriptor) throws -> Void
    /// False while the store is read-only: a choice then lives in this cache for the
    /// session, and later refreshes keep it.
    private let persists: @Sendable () -> Bool
    private var sessionOnly: Set<OptionPreferenceKey> = []

    init(store: OptionStore, persists: @escaping @Sendable () -> Bool = { true }) {
        read = { try store.value(for: $0) }
        write = { try store.save($0, for: $1) }
        self.persists = persists
    }
    /// Inject disk boundaries for the production-source concurrency probe.
    init(
        read: @escaping @Sendable (EngineOptionDescriptor) throws -> Bool?,
        write: @escaping @Sendable (Bool, EngineOptionDescriptor) throws -> Void,
        persists: @escaping @Sendable () -> Bool = { true }
    ) {
        self.read = read
        self.write = write
        self.persists = persists
    }

    func value(for descriptor: EngineOptionDescriptor) throws -> Bool? {
        lock.lock()
        let result = values[OptionPreferenceKey(descriptor)] ?? .success(nil)
        lock.unlock()
        return try result.get()
    }

    func preload(_ descriptors: [EngineOptionDescriptor]) {
        lock.lock()
        let versions = revisions
        lock.unlock()
        OptionPersistenceIO.preload { refresh(descriptors, versions: versions) }
    }

    func beginRefresh(_ descriptors: [EngineOptionDescriptor]) -> Task<Void, Error> {
        lock.lock()
        defer { lock.unlock() }
        let versions = revisions
        return OptionPersistenceIO.enqueue { [self] in refresh(descriptors, versions: versions) }
    }

    private func refresh(_ descriptors: [EngineOptionDescriptor], versions: [OptionPreferenceKey: UInt64]) {
        var seen: Set<OptionPreferenceKey> = []
        for descriptor in descriptors where seen.insert(OptionPreferenceKey(descriptor)).inserted {
            let result = Result { try read(descriptor) }
            lock.lock()
            if !sessionOnly.contains(OptionPreferenceKey(descriptor)),
                revisions[OptionPreferenceKey(descriptor), default: 0]
                    == versions[OptionPreferenceKey(descriptor), default: 0]
            {
                values[OptionPreferenceKey(descriptor)] = result
            }
            lock.unlock()
        }
    }

    func beginSave(_ value: Bool, for descriptor: EngineOptionDescriptor) -> Task<SaveOutcome, Error> {
        lock.lock()
        defer { lock.unlock() }
        let revision = revisions[OptionPreferenceKey(descriptor), default: 0] &+ 1
        revisions[OptionPreferenceKey(descriptor)] = revision
        values[OptionPreferenceKey(descriptor)] = .success(value)
        guard persists() else {
            sessionOnly.insert(OptionPreferenceKey(descriptor))
            return Task { SaveOutcome(isCurrent: true, result: .success(())) }
        }
        sessionOnly.remove(OptionPreferenceKey(descriptor))
        return OptionPersistenceIO.enqueue { [self] in
            let result = Result { try write(value, descriptor) }
            lock.lock()
            defer { lock.unlock() }
            let current = revisions[OptionPreferenceKey(descriptor)] == revision
            if current, case .failure(let error) = result { values[OptionPreferenceKey(descriptor)] = .failure(error) }
            return SaveOutcome(isCurrent: current, result: result)
        }
    }
}

/// Conservative reader for librime's emitted (expanded) build/*.schema.yaml.
/// It deliberately does not interpret source YAML includes/patches, Lua filters,
/// arbitrary OpenCC transforms, or unknown serializations as supported features.
enum SchemaOptionCapabilities {
    /// Read the selected schema's own switch reset value; no engine session is created.
    static func defaultValue(for option: EngineOptionDescriptor, compiledDirectory: URL) -> Bool {
        guard
            let yaml = try? String(
                contentsOf: compiledDirectory.appendingPathComponent(option.schemaID + ".schema.yaml"), encoding: .utf8),
            let api = rime_get_api()
        else { return false }
        var config = RimeConfig()
        defer { _ = api.pointee.config_close(&config) }
        guard yaml.withCString({ api.pointee.config_load_string(&config, $0) }) != 0 else { return false }
        let count = Int(api.pointee.config_list_size(&config, "switches"))
        for index in 0..<count {
            let path = "switches/@\(index)"
            let name = (path + "/name").withCString { key in
                api.pointee.config_get_cstring(&config, key).map { String(cString: $0) }
            }
            if name == option.name {
                var value: Int32 = 0
                _ = (path + "/reset").withCString { api.pointee.config_get_int(&config, $0, &value) }
                return value != 0
            }
        }
        return false
    }

    static func read(
        resourceID: String, schemaID: String, compiledDirectory: URL,
        sharedDirectory: URL
    ) -> [EngineOptionDescriptor] {
        guard !resourceID.isEmpty,
            let yaml = try? String(
                contentsOf: compiledDirectory.appendingPathComponent(schemaID + ".schema.yaml"),
                encoding: .utf8)
        else { return [] }
        var sections: [String: [String]] = [:]
        var section = ""
        for line in yaml.components(separatedBy: .newlines) {
            if !line.hasPrefix(" "), line.hasSuffix(":"), !line.hasPrefix("#") {
                section = String(line.dropLast())
            } else {
                sections[section, default: []].append(line)
            }
        }
        func scalar(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        let switches = (sections["switches"] ?? []).compactMap { line -> String? in
            guard line.hasPrefix("  - name: ") else { return nil }
            return scalar(String(line.dropFirst("  - name: ".count)))
        }
        var filters: [String] = []
        var inFilters = false
        for line in sections["engine"] ?? [] {
            if line == "  filters:" {
                inFilters = true
                continue
            }
            if inFilters && line.hasPrefix("  ") && !line.hasPrefix("    ") { inFilters = false }
            if inFilters && line.hasPrefix("    - ") { filters.append(scalar(String(line.dropFirst(6)))) }
        }
        var result: [EngineOptionDescriptor] = []
        for filter in filters where filter.hasPrefix("simplifier@") || filter == "simplifier" {
            let namespace = filter == "simplifier" ? "simplifier" : String(filter.dropFirst("simplifier@".count))
            func field(_ name: String) -> String? {
                let prefix = "  \(name): "
                return sections[namespace]?.first(where: { $0.hasPrefix(prefix) }).map {
                    scalar(String($0.dropFirst(prefix.count)))
                }
            }
            let name = field("option_name") ?? "simplification"
            guard switches.contains(name), let config = field("opencc_config"),
                FileManager.default.fileExists(atPath: sharedDirectory.appendingPathComponent("opencc/" + config).path)
            else { continue }
            let labels: (String, String, String)
            switch config {
            case "s2t.json", "s2tw.json", "s2hk.json": labels = ("繁体输出", "关闭", "开启")
            case "t2s.json": labels = ("简体输出", "关闭", "开启")
            case "emoji.json": labels = ("Emoji 候选", "关闭", "开启")
            default: continue
            }
            guard !result.contains(where: { $0.name == name }) else { continue }
            result.append(
                .init(
                    resourceID: resourceID, schemaID: schemaID, name: name,
                    title: labels.0, disabledLabel: labels.1, enabledLabel: labels.2))
        }
        return result
    }
}
