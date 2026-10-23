import Foundation
import KeyboardCore
import OSLog
import UIKit
import os

// MARK: - Keyboard lifecycle diagnostics (privacy-safe, off by default, bounded)
//
// Distinguishes three situations:
//   A) the process/session is alive and only a view re-appearance reset the phase
//      (false cold start: brief spinner flash);
//   B) a real cold boot after the system reclaimed the extension process;
//   C) a shared-resource / appearance notification causing an unnecessary restart.
//
// Only phases, durations and opaque identities are recorded:
//   * monotonic timestamps (`systemUptime` / `CACurrentMediaTime`), comparable across events;
//   * process identity (pid + random process token) and `ObjectIdentifier`s of session/controller/view;
//   * published route identity (resource id + publication prefix + layout) from `KeyboardRouteKey`.
//
// Never input text, candidates, schema text, host document content or any user data.
// Gate: off by default; enabled when `keyboard.lifecycleDiagnosticsEnabled` or the
// existing `keyboard.geometryDiagnosticsEnabled` is true. A hard line cap keeps the
// extension from writing unbounded logs.
public enum KeyboardLifecycleDiagnostics {
    public static let lifecycleKey = "keyboard.lifecycleDiagnosticsEnabled"
    private static let geometryKey = "keyboard.geometryDiagnosticsEnabled"
    #if DEBUG
        // Debug builds are for local debugging and automation: always on, higher (still bounded) line cap.
        private static let maxLines = 20_000
    #else
        private static let maxLines = 400
    #endif

    /// Line counter with a hard cap. `emit` can be called from the main thread and from
    /// background measurements, so the count must be atomic (see
    /// `KeyboardCore.BoundedDiagnosticLineCounter`). Hot input paths never call `emit`;
    /// the lock is only taken when diagnostics are enabled.
    private static let limiter = BoundedDiagnosticLineCounter(limit: maxLines)
    private static let unavailableStoreWarning = BoundedDiagnosticLineCounter(limit: 1)

    /// Process identity token: stable for one process lifetime, changes on restart. Carries no user data.
    public static let processToken: String = String(UInt32.random(in: 0...UInt32.max), radix: 16)
    public static let processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier

    /// Monotonic baseline: seconds since process start (native monotonic clock).
    public static let monotonicOrigin: CFTimeInterval = ProcessInfo.processInfo.systemUptime

    /// The extension reads the same App Group preference as the Host's developer
    /// switch. Lifecycle events are infrequent (not key events); re-read here so
    /// enabling diagnostics also works when the extension process survives.
    public static var isEnabled: Bool {
        #if DEBUG
            return true
        #else
            return sharedSwitchEnabled
        #endif
    }

    private static var sharedSwitchEnabled: Bool {
        let shared = KeyboardRecipeStore.sharedDefaults()
        if shared == nil || KeyboardRecipeStore.sharedContainerURL() == nil {
            if unavailableStoreWarning.reserve() {
                Logger.keyboardLifecycle.error(
                    "lifecycle diagnostics shared preferences unavailable; no route evidence can be inferred")
            }
        }
        return (shared ?? .standard).bool(forKey: lifecycleKey)
            || (shared?.bool(forKey: geometryKey) ?? false)
            || UserDefaults.standard.bool(forKey: geometryKey)
    }

    /// Monotonic relative time in seconds.
    public static var monotonic: CFTimeInterval { ProcessInfo.processInfo.systemUptime - monotonicOrigin }

    /// Process physical memory footprint (`phys_footprint`, bytes). Keyboard extensions
    /// must stay far lighter than a foreground app, so cold-start checks need this number.
    ///
    /// A plain number with no input/candidate/document data. Returns 0 on failure;
    /// callers treat 0 as "unknown", never as a real zero-byte reading.
    public static var footprintBytes: UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.phys_footprint)
    }

    /// Opaque object identity (view/controller/session): address only, never a description.
    public static func identity(_ object: AnyObject?) -> String {
        guard let object else { return "nil" }
        return String(UInt(bitPattern: ObjectIdentifier(object).hashValue), radix: 16)
    }

    /// Bounded single-line event, logged `.public` as a whole. `fields` keys are fixed
    /// literals and values are enums, numbers, opaque identities or route identities
    /// (resource id, generation prefix, layout). Never pass input, candidates or any
    /// name the user typed (keyboard or scheme names): those must be logged `.private`.
    public static func emit(_ event: String, _ fields: [String: String] = [:]) {
        guard isEnabled else { return }
        let reservation = limiter.reserveWithCapMarker()
        guard reservation != .exhausted else { return }
        let time = String(format: "%.3f", monotonic)
        var line = "lifecycle t=\(time) pid=\(processIdentifier) token=\(processToken)"
        if reservation == .capMarker {
            line += " event=lifecycleCapReached maxLines=\(maxLines)"
        } else {
            line += " event=\(event)"
            for key in fields.keys.sorted() where !key.isEmpty {
                line += " \(key)=\(fields[key] ?? "")"
            }
        }
        Logger.keyboardLifecycle.notice("\(line, privacy: .public)")
    }

    /// Measures the duration of an async span (background resolve / engine op) and reports it.
    public static func measureAsync<T>(
        _ event: String, _ fields: [String: String] = [:],
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async -> T
    ) async -> T {
        guard isEnabled else { return await body() }
        let started = ProcessInfo.processInfo.systemUptime
        let value = await body()
        var all = fields
        all["ms"] = String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - started) * 1000)
        emit(event, all)
        return value
    }
}

// MARK: - Main-thread stall report (behind the diagnostics switch, bounded, technical fields only)

/// One notice line when a key or candidate action holds the main thread for
/// `threshold` or longer, one per memory warning and one per appearance. Notice level
/// because device log archives keep only notice and above. Fields are the action kind,
/// durations, footprint and seconds since the last memory warning — never input,
/// candidates or document text. Gated like lifecycle diagnostics
/// (`KeyboardLifecycleDiagnostics.isEnabled`); every line leaves through `deliver`.
@MainActor
public enum KeyboardStallReport {
    private static let lines = BoundedDiagnosticLineCounter(limit: 200)
    private static let threshold: CFTimeInterval = 0.1
    private static var lastMemoryWarningAt: CFTimeInterval?
    private static var memoryWarningObserver: NSObjectProtocol?

    public static func installMemoryWarningObserver() {
        guard memoryWarningObserver == nil else { return }
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                lastMemoryWarningAt = CACurrentMediaTime()
                deliver(lines, "memoryWarning footprintMB=\(KeyboardLifecycleDiagnostics.footprintBytes / 1_048_576)")
            }
        }
    }

    /// Times one main-thread action; call the result when the action returns.
    /// `syncMs` is the action itself; `turnMs` runs to the next main-queue turn, so it
    /// also covers work the action queued there (approximate: render passes may land
    /// on either side of it).
    public static func begin(_ kind: String) -> () -> Void {
        let started = CACurrentMediaTime()
        return {
            let syncMs = (CACurrentMediaTime() - started) * 1000
            DispatchQueue.main.async {
                let turnMs = (CACurrentMediaTime() - started) * 1000
                guard turnMs >= threshold * 1000 else { return }
                MainActor.assumeIsolated { report(kind, syncMs: syncMs, turnMs: turnMs) }
            }
        }
    }

    private static func report(_ kind: String, syncMs: Double, turnMs: Double) {
        let sinceWarning = lastMemoryWarningAt.map { String(format: "%.1f", CACurrentMediaTime() - $0) } ?? "-"
        deliver(
            lines,
            """
            slowAction kind=\(kind) syncMs=\(String(format: "%.0f", syncMs)) \
            turnMs=\(String(format: "%.0f", turnMs)) \
            footprintMB=\(KeyboardLifecycleDiagnostics.footprintBytes / 1_048_576) \
            sinceMemoryWarningS=\(sinceWarning)
            """)
    }

    /// The one exit for every report, so another opt-in sink can consume the same lines.
    /// The switch is read only here: stalls and appearances are rare, key presses never reach it.
    private static func deliver(_ counter: BoundedDiagnosticLineCounter, _ line: @autoclosure () -> String) {
        guard KeyboardLifecycleDiagnostics.isEnabled, counter.reserve() else { return }
        let text = line()
        Logger.keyboardStall.notice("\(text, privacy: .public)")
    }

    private static let appearanceLines = BoundedDiagnosticLineCounter(limit: 300)
    private static var appearances = 0

    /// One line per keyboard appearance. UIKit keeps replaced input views alive, and on
    /// device their layer backing stores count toward the footprint (on the simulator they
    /// do not), so footprint growth is read against these live counts.
    public static func appeared() {
        appearances += 1
        deliver(
            appearanceLines,
            """
            appeared n=\(appearances) \
            controllers=\(KeyboardLiveObjects.controllers.value) \
            inputViews=\(KeyboardLiveObjects.inputViews.value) \
            footprintMB=\(KeyboardLifecycleDiagnostics.footprintBytes / 1_048_576)
            """)
    }
}

/// Live instance counts reported by `KeyboardStallReport.appeared()`.
public enum KeyboardLiveObjects {
    public static let controllers = LiveObjectCounter()
    public static let inputViews = LiveObjectCounter()
}

public final class LiveObjectCounter: Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)

    public var value: Int { count.withLock { $0 } }

    public func increment() { count.withLock { $0 += 1 } }
    public func decrement() { count.withLock { $0 -= 1 } }
}

#if DEBUG
    // MARK: - Debug probe (Debug builds only; logs and signposts never contain user input)
    //
    // Lets simulator automation tell whether the environment is trustworthy without manual toggling:
    //   * `DebugProbe.reportEnvironment` logs one `debugProbe env ...` line at launch.
    //     `appGroup=unavailable` means the bundle has no embedded entitlements (typically
    //     built with CODE_SIGNING_ALLOWED=NO and installed on the simulator). That is a
    //     build/install problem, not a product bug; repackage with `make sim-stage`.
    //   * `DebugProbe.keyInterval` provides signpost intervals for key handling (Instruments / `log stream`).
    // Capture: `make sim-log`, or `log stream --predicate 'subsystem == "app.songyan.ime"'`.
    public enum DebugProbe {
        private static let logger = Logger.debugProbe
        private static let signposter = OSSignposter(logger: .debugProbe)

        public static func reportEnvironment(role: String) {
            let groupID = KeyboardRecipeStore.groupID
            let container = KeyboardRecipeStore.sharedContainerURL()
            let sharedDefaults = KeyboardRecipeStore.sharedDefaults() != nil
            let bundle = Bundle.main.bundleIdentifier ?? "nil"
            let status = container == nil ? "unavailable" : "ok"
            logger.notice(
                """
                debugProbe env role=\(role, privacy: .public) bundle=\(bundle, privacy: .public) \
                pid=\(KeyboardLifecycleDiagnostics.processIdentifier, privacy: .public) \
                appGroup=\(status, privacy: .public) group=\(groupID, privacy: .public) \
                sharedDefaults=\(sharedDefaults, privacy: .public) touchProbe=\(touchRoutingEnabled, privacy: .public) \
                footprintMB=\(KeyboardLifecycleDiagnostics.footprintBytes / 1_048_576, privacy: .public)
                """)
            if container == nil {
                logger.error(
                    "debugProbe appGroup unavailable: this build has no embedded entitlements (unsigned?). Rebuild with `make sim-stage`; do not treat this as a product bug."
                )
            }
        }

        /// Key-handling interval; records the action kind only, never the character. Also
        /// accumulates synchronous handling time for the p50/p95 in the state snapshot (the
        /// interval covers only the synchronous part of `handle`, not the async engine return).
        public static func keyInterval(_ kind: String) -> (() -> Void) {
            let state = signposter.beginInterval("key", id: signposter.makeSignpostID(), "\(kind, privacy: .public)")
            let started = ProcessInfo.processInfo.systemUptime
            return {
                signposter.endInterval("key", state)
                keyStats.record((ProcessInfo.processInfo.systemUptime - started) * 1000)
            }
        }

        /// Engine serial-queue operation: the interval covers queueing plus execution; over 50 ms also logs a slow-op line.
        public static func engineOp(_ kind: String) -> @Sendable (_ started: Bool) -> Void {
            let queued = ProcessInfo.processInfo.systemUptime
            let state = signposter.beginInterval(
                "engineOp", id: signposter.makeSignpostID(), "\(kind, privacy: .public)")
            // Start runs on the engine queue, end on the caller; the lock orders the two.
            let runStart = OSAllocatedUnfairLock(initialState: queued)
            return { isStart in
                if isStart {
                    runStart.withLock { $0 = ProcessInfo.processInfo.systemUptime }
                    return
                }
                signposter.endInterval("engineOp", state)
                let now = ProcessInfo.processInfo.systemUptime
                let started = runStart.withLock { $0 }
                let waitMs = (started - queued) * 1000, runMs = (now - started) * 1000
                engineStats.record(runMs)
                if waitMs + runMs > 50 {
                    logger.notice(
                        "debugProbe slowEngineOp kind=\(kind, privacy: .public) waitMs=\(String(format: "%.1f", waitMs), privacy: .public) runMs=\(String(format: "%.1f", runMs), privacy: .public)"
                    )
                }
            }
        }

        /// Controller refresh (candidate/state publish) interval.
        public static func refreshInterval() -> (() -> Void) {
            let state = signposter.beginInterval("refresh", id: signposter.makeSignpostID())
            return {
                signposter.endInterval("refresh", state)
                refreshCount.increment()
            }
        }

        /// App Group preference key: forces the extension's launch layout in Debug (qwerty26 / merged14 / phone9 ...).
        public static let layoutOverrideKey = "debug.layoutOverride"

        /// App Group preference key: logs each touch's hit routing in Debug (`make sim-probe PROBE=touch`).
        public static let touchProbeKey = "debug.touchProbe"

        /// Read once at process start; the key hot path only reads this Bool, so it costs nothing when off.
        public static let touchRoutingEnabled: Bool =
            KeyboardRecipeStore.sharedDefaults()?.bool(forKey: touchProbeKey) == true

        /// Hit routing of one touch: point, system hit-view type, nearby key frames, and the key frame finally chosen.
        /// Geometry only; no key text or user input.
        public static func touchRouting(point: CGPoint, hit: UIView?, nearKeys: [CGRect], routed: CGRect?) {
            let near = nearKeys.map { NSCoder.string(for: $0) }.joined(separator: ",")
            let target = routed.map { NSCoder.string(for: $0) } ?? "none"
            let hitType = hit.map { String(describing: type(of: $0)) } ?? "nil"
            logger.notice(
                "debugProbe touch p=\(NSCoder.string(for: point), privacy: .public) hit=\(hitType, privacy: .public) near=\(near, privacy: .public) routed=\(target, privacy: .public)"
            )
        }

        public static var currentRole: String {
            (Bundle.main.bundleIdentifier ?? "").hasSuffix("KeyboardExtension") ? "keyboardExtension" : "hostApp"
        }

        public static let keyStats = LatencyStats()
        public static let engineStats = LatencyStats()
        public static let refreshCount = Counter()

        public final class Counter: Sendable {
            private let value = OSAllocatedUnfairLock(initialState: 0)
            public func increment() { value.withLock { $0 += 1 } }
            public var current: Int { value.withLock { $0 } }
        }

        /// Latency statistics over the most recent 512 samples.
        public final class LatencyStats: Sendable {
            private let state = OSAllocatedUnfairLock(initialState: (samples: [Double](), total: 0))
            public func record(_ ms: Double) {
                state.withLock { state in
                    state.total += 1
                    state.samples.append(ms)
                    if state.samples.count > 512 { state.samples.removeFirst(state.samples.count - 512) }
                }
            }
            public var summary: [String: Any] {
                let (samples, total) = state.withLock { ($0.samples, $0.total) }
                guard !samples.isEmpty else { return ["count": total] }
                let sorted = samples.sorted()
                func q(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
                return ["count": total, "p50Ms": q(0.5), "p95Ms": q(0.95), "maxMs": sorted.last ?? 0]
            }
        }

        // MARK: State snapshot (read by automation)
        //
        // Written to the App Group container at `Library/Caches/debug-state-<role>.json`
        // (throttled to 0.5 s, background queue). Technical values only (phase, layout id,
        // counts, durations, memory); no input, candidate text or document content.
        // Read with `make sim-state`.
        private static let snapshotQueue = DispatchQueue(label: "app.songyan.debugProbe.snapshot", qos: .utility)
        private static let snapshotLock = NSLock()
        // Guarded by `snapshotLock`.
        nonisolated(unsafe) private static var lastSnapshot: CFTimeInterval = 0
        nonisolated(unsafe) private static var accumulated: [String: Any] = [:]
        nonisolated(unsafe) private static var flushScheduled = false

        /// Fields are merged by key into one snapshot (phase and layout come from different
        /// call sites). Writes are throttled to 0.5 s; a throttled update is covered by one
        /// deferred write so the final state always lands on disk.
        public static func writeSnapshot(role: String, _ fields: [String: Any], force: Bool = false) {
            snapshotLock.lock()
            accumulated.merge(fields) { _, new in new }
            accumulated["role"] = role
            let now = ProcessInfo.processInfo.systemUptime
            if !force, now - lastSnapshot < 0.5 {
                if !flushScheduled {
                    flushScheduled = true
                    snapshotQueue.asyncAfter(deadline: .now() + 0.5) {
                        snapshotLock.lock()
                        flushScheduled = false
                        snapshotLock.unlock()
                        flushSnapshot()
                    }
                }
                snapshotLock.unlock()
                return
            }
            snapshotLock.unlock()
            snapshotQueue.async { flushSnapshot() }
        }

        private static func flushSnapshot() {
            snapshotLock.lock()
            lastSnapshot = ProcessInfo.processInfo.systemUptime
            var doc = accumulated
            snapshotLock.unlock()
            let role = (doc["role"] as? String) ?? currentRole
            doc["pid"] = KeyboardLifecycleDiagnostics.processIdentifier
            doc["processToken"] = KeyboardLifecycleDiagnostics.processToken
            doc["footprintMB"] = Double(KeyboardLifecycleDiagnostics.footprintBytes) / 1_048_576
            doc["keyLatency"] = keyStats.summary
            doc["engineOp"] = engineStats.summary
            doc["refreshCount"] = refreshCount.current
            doc["wallClock"] = ISO8601DateFormatter().string(from: Date())
            guard KeyboardRecipeStore.canWriteSharedContainer,
                let container = FileManager.default.containerURL(
                    forSecurityApplicationGroupIdentifier: KeyboardRecipeStore.groupID),
                let data = try? JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys, .prettyPrinted])
            else { return }
            let dir = container.appendingPathComponent("Library/Caches", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: dir.appendingPathComponent("debug-state-\(role).json"), options: .atomic)
        }
    }
#endif
