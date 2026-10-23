import Darwin
import Foundation

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var maxActive = 0
    private var offMain: [Bool] = []
    private var resumed = 0
    func enter() -> Int {
        lock.lock()
        defer { lock.unlock() }
        active += 1
        maxActive = max(maxActive, active)
        return active
    }
    func leave(_ wasMain: Bool) {
        lock.lock()
        defer { lock.unlock() }
        active -= 1
        offMain.append(wasMain)
    }
    func noteResume() {
        lock.lock()
        resumed += 1
        lock.unlock()
    }
    var peak: Int {
        lock.lock()
        defer { lock.unlock() }
        return maxActive
    }
    var anyOnMain: Bool {
        lock.lock()
        defer { lock.unlock() }
        return offMain.contains(true)
    }
    var resumeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return resumed
    }
}

let counter = Counter()

// 1) off-main: the body must NOT run on the main thread (Task.detached, not Task {}).
_ = try await EngineOpQueue.asyncExclusive {
    counter.enter()
    let onMain = Thread.isMainThread
    usleep(5_000)
    counter.leave(onMain)
    return 0
}

// 2) serial: two concurrent calls never overlap; peak concurrency == 1.
async let a: Int = EngineOpQueue.asyncExclusive {
    counter.enter()
    usleep(30_000)
    let onMain = Thread.isMainThread
    counter.leave(onMain)
    return 1
}
async let b: Int = EngineOpQueue.asyncExclusive {
    counter.enter()
    usleep(30_000)
    let onMain = Thread.isMainThread
    counter.leave(onMain)
    return 2
}
let pair = try await (a, b)
precondition(pair == (1, 2), "asyncExclusive results")

// 3) throw propagation: the body error reaches the caller, continuation resumes exactly once.
struct Boom: Error {}
do {
    _ = try await EngineOpQueue.asyncExclusive { () -> Int in
        counter.noteResume()
        throw Boom()
    }
    fatalError("expected throw")
} catch is Boom {}

// 4) no deadlock / still usable: a plain sync-queue op completes after the async ones.
let syncValue = try await EngineOpQueue.async { 42 }
precondition(syncValue == 42, "queue usable after asyncExclusive")

precondition(!counter.anyOnMain, "EngineOpQueue.asyncExclusive body must run off the MainActor")
precondition(counter.peak == 1, "asyncExclusive must stay serial (peak=\(counter.peak))")
precondition(counter.resumeCount == 1, "throwing body must run exactly once")
print("PASS: asyncExclusive off-main, serial, throw propagates, no deadlock/double-resume")
