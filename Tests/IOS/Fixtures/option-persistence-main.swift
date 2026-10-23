import Foundation

public struct EngineOptionDescriptor: Sendable {
    let resourceID: String
    let schemaID: String
    let name: String
    var id: String { name }
}
enum Failure: Error { case denied }
final class Disk: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [OptionPreferenceKey: Bool] = [:]
    private var events: [Bool] = []
    var failFalse = false
    var readStarted: DispatchSemaphore?
    var readRelease: DispatchSemaphore?
    func seed(_ option: EngineOptionDescriptor, _ value: Bool) {
        lock.lock()
        values[OptionPreferenceKey(option)] = value
        lock.unlock()
    }
    func read(_ option: EngineOptionDescriptor) -> Bool? {
        precondition(!Thread.isMainThread)
        lock.lock()
        let value = values[OptionPreferenceKey(option)]
        lock.unlock()
        readStarted?.signal()
        readRelease?.wait()
        return value
    }
    func write(_ value: Bool, _ option: EngineOptionDescriptor) throws {
        precondition(!Thread.isMainThread)
        if failFalse && !value { throw Failure.denied }
        lock.lock()
        events.append(value)
        values[OptionPreferenceKey(option)] = value
        lock.unlock()
    }
    func writes() -> [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}
@main struct Probe {
    static func consumeSignal(_ signal: DispatchSemaphore) -> Bool {
        signal.wait(timeout: .now()) == .success
    }
    @MainActor static func signaled(_ signal: DispatchSemaphore) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !consumeSignal(signal) {
            precondition(Date() < deadline, "worker did not start")
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String = "failed") throws {
        let passed = try condition()
        precondition(passed, message)
    }
    @MainActor static func main() async throws {
        let a = EngineOptionDescriptor(resourceID: "r", schemaID: "a", name: "same")
        let b = EngineOptionDescriptor(resourceID: "r", schemaID: "b", name: "same")
        let c = EngineOptionDescriptor(resourceID: "s", schemaID: "a", name: "same")
        let disk = Disk()
        disk.seed(a, false)
        disk.seed(b, true)
        disk.seed(c, true)
        let cache = OptionPreferenceCache(read: { disk.read($0) }, write: { try disk.write($0, $1) })
        try await cache.beginRefresh([a, b, c, a]).value
        try check(try cache.value(for: a) == false)
        try check(try cache.value(for: b) == true)
        try check(try cache.value(for: c) == true)
        print("PASS full resource/schema/name identities do not collide")

        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let blocked = OptionPersistenceIO.enqueue {
            started.signal()
            release.wait()
        }
        try await signaled(started)
        let start = Date()
        let first = cache.beginSave(true, for: a)
        let second = cache.beginSave(false, for: b)
        let third = cache.beginSave(false, for: a)
        precondition(Date().timeIntervalSince(start) < 0.2, "enqueue blocked UI")
        try await Task.sleep(nanoseconds: 10_000_000)
        precondition(disk.writes().isEmpty, "blocked FIFO was bypassed")
        release.signal()
        try await blocked.value
        let firstResult = try await first.value
        let secondResult = try await second.value
        let thirdResult = try await third.value
        precondition(!firstResult.isCurrent && secondResult.isCurrent && thirdResult.isCurrent)
        precondition(disk.writes() == [true, false, false])
        try check(try cache.value(for: a) == false)
        try check(try cache.value(for: b) == false)
        try check(try cache.value(for: c) == true)
        print("PASS synchronous registration is nonblocking and writes keep touch order")

        disk.seed(a, true)
        await Task.detached { cache.preload([a, b, c]) }.value
        try check(try cache.value(for: a) == true && cache.value(for: b) == false)
        let unreadable = OptionPreferenceCache(read: { _ in throw Failure.denied }, write: { _, _ in })
        try await unreadable.beginRefresh([a]).value
        do {
            _ = try unreadable.value(for: a)
            preconditionFailure("read failure became no override")
        } catch Failure.denied {}
        print("PASS restart preload refreshes old revisions and read errors remain errors")

        let staleDisk = Disk()
        staleDisk.seed(a, false)
        staleDisk.readStarted = DispatchSemaphore(value: 0)
        staleDisk.readRelease = DispatchSemaphore(value: 0)
        let stale = OptionPreferenceCache(read: { staleDisk.read($0) }, write: { try staleDisk.write($0, $1) })
        let reading = stale.beginRefresh([a])
        try await signaled(staleDisk.readStarted!)
        let saving = stale.beginSave(true, for: a)
        staleDisk.readRelease!.signal()
        try await reading.value
        try check(try stale.value(for: a) == true, "old disk snapshot overwrote latest touch")
        _ = try await saving.value
        print("PASS stale read cannot undo a newer registered save")

        let failureDisk = Disk()
        failureDisk.failFalse = true
        let failures = OptionPreferenceCache(read: { failureDisk.read($0) }, write: { try failureDisk.write($0, $1) })
        let stop = DispatchSemaphore(value: 0), go = DispatchSemaphore(value: 0)
        let blocker = OptionPersistenceIO.enqueue {
            stop.signal()
            go.wait()
        }
        try await signaled(stop)
        let oldFailure = failures.beginSave(false, for: a)
        let newSuccess = failures.beginSave(true, for: a)
        go.signal()
        try await blocker.value
        let old = try await oldFailure.value
        let new = try await newSuccess.value
        precondition(!old.isCurrent && new.isCurrent)
        if case .success = old.result { preconditionFailure("write error was hidden") }
        try new.result.get()
        try check(try failures.value(for: a) == true)
        let latestFailure = try await failures.beginSave(false, for: a).value
        precondition(latestFailure.isCurrent)
        if case .success = latestFailure.result { preconditionFailure("false success") }
        do {
            _ = try failures.value(for: a)
            preconditionFailure("cache hid save failure")
        } catch Failure.denied {}
        print("PASS failures are truthful; stale failure cannot overwrite newer success")

        let readOnlyDisk = Disk()
        readOnlyDisk.seed(a, false)
        let readOnly = OptionPreferenceCache(
            read: { readOnlyDisk.read($0) }, write: { try readOnlyDisk.write($0, $1) }, persists: { false })
        let kept = try await readOnly.beginSave(true, for: a).value
        precondition(kept.isCurrent)
        try kept.result.get()
        precondition(readOnlyDisk.writes().isEmpty, "read-only save wrote")
        try await readOnly.beginRefresh([a]).value
        try check(try readOnly.value(for: a) == true, "refresh dropped the session choice")
        print("PASS without write access a choice stays for the session and is never written")

        let dir = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = OptionStore(directory: dir)
        let real = OptionPreferenceCache(store: store)
        try await real.beginSave(true, for: a).value.result.get()
        try await real.beginSave(false, for: b).value.result.get()
        try await real.beginRefresh([a, b]).value
        try check(try real.value(for: a) == true && real.value(for: b) == false)
        print("PASS actual atomic store roundtrip keeps same-name schema preferences separate")
    }
}
