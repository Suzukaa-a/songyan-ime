import Foundation

extension InputSession {
    /// One batch of code keys on the engine queue. The engine runs each key and the
    /// closing state read inside `lock` (`admit` / `settle`), so once `stop()` returns
    /// no further key reaches the engine; a batch the queue has not started yet never
    /// touches it at all.
    // @unchecked: every mutable field is guarded by `lock`, and `engine` (not Sendable) only
    // touches the engine under that lock while the session, which stops and waits first, is not.
    final class CodeBatch: EngineKeyGate, @unchecked Sendable {
        let keys: [String]
        private let engine: EngineBackend
        private let lock = NSLock()
        private let finished = DispatchSemaphore(value: 0)
        private var started = false
        private var stopped = false
        private var discarded = false
        private var done = false
        private(set) var processed = 0
        private(set) var snapshot: EngineSnapshot?
        private(set) var error: Error?
        private(set) var lookahead: [Candidate]?
        let lookaheadPages: Int

        init(keys: [String], engine: EngineBackend, lookaheadPages: Int) {
            self.keys = keys
            self.engine = engine
            self.lookaheadPages = lookaheadPages
        }

        func run() {
            lock.lock()
            guard !stopped else {
                lock.unlock()
                return
            }
            started = true
            lock.unlock()
            let result = engine.processKeys(keys, gate: self)
            lock.lock()
            processed = result.processed
            snapshot = result.snapshot
            error = result.error
            // A failed read leaves `lookahead` nil and the front end reads the pages itself.
            if !stopped, error == nil, lookaheadPages > 0, let s = snapshot, s.isComposing,
                s.pageSize > 0, s.pageIndex == 0, !s.isLastPage, s.candidates.count == s.pageSize
            {
                lookahead = try? engine.readCandidates(fromIndex: s.pageSize, count: s.pageSize * lookaheadPages)
            }
            done = true
            lock.unlock()
            finished.signal()
        }

        func admit(_ key: () throws -> Void) rethrows -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !stopped else { return false }
            try key()
            return true
        }

        /// Even once stopped, a drain lands the keys already processed; a discarded
        /// batch leaves the engine alone.
        func settle(_ read: () -> Void) {
            lock.lock()
            defer { lock.unlock() }
            guard !discarded else { return }
            read()
        }

        /// No key reaches the engine after this returns, nor anything else when
        /// `discarding`. True when the worker started (its result then covers
        /// `processed` keys once `waitUntilDone` returns).
        func stop(discarding: Bool = false) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            stopped = true
            discarded = discarded || discarding
            return started
        }

        /// Only after `stop()` returned true: at most the key decoding now.
        func waitUntilDone() { finished.wait() }

        var isDone: Bool {
            lock.lock()
            defer { lock.unlock() }
            return done
        }
    }

    var defersCodeKeys: Bool {
        codeKeyQueue != nil && mode == .chinese && snapshot.isComposing && !snapshot.isAsciiMode
    }

    func deferCode(_ value: String) {
        pendingCodes.append(value)
        pendingCodesRevision &+= 1
        onPendingCodesChanged?()
        startCodeBatch()
    }

    private func startCodeBatch() {
        guard !retired, let queue = codeKeyQueue, batch == nil, !pendingCodes.isEmpty else { return }
        let next = CodeBatch(keys: pendingCodes, engine: engine, lookaheadPages: codeBatchLookaheadPages)
        batch = next
        queue.async { [weak self] in
            next.run()
            DispatchQueue.main.async { self?.finishCodeBatch(next) }
        }
    }

    /// Applies a finished batch once; a batch drained or cancelled meanwhile is ignored.
    private func finishCodeBatch(_ finished: CodeBatch) {
        guard batch === finished, finished.isDone else { return }
        batch = nil
        guard !retired else { return }
        landBatch(finished)
        onPendingCodesChanged?()
        startCodeBatch()
    }

    private func landBatch(_ landed: CodeBatch) {
        pendingCodes.removeFirst(min(landed.processed, pendingCodes.count))
        pendingCodesRevision &+= 1
        if let snapshot = landed.snapshot {
            candidateLookahead = landed.lookahead.map { (snapshot.rawInput, snapshot.pageSize, $0) }
            apply(snapshot)
            candidateLookahead = nil
        }
        if let error = landed.error {
            pendingCodes.removeAll()
            onError?(error)
        }
    }

    /// Every other engine action first lands the deferred keys, in order, so it sees
    /// exactly the composition a synchronous engine would have had. It waits at most
    /// for the key decoding now, never for other work queued on the engine queue: a
    /// batch the queue has not started is taken back and its keys run here.
    func drainPendingCodes() {
        guard batch != nil || !pendingCodes.isEmpty else { return }
        if let current = batch {
            batch = nil
            if current.stop() {
                current.waitUntilDone()
                landBatch(current)
            }
        }
        let rest = pendingCodes
        if !rest.isEmpty, !retired {
            pendingCodes = []
            pendingCodesRevision &+= 1
            processSynchronously(rest)
        }
        onPendingCodesChanged?()
    }

    /// The remaining keys in one pass: commits keep their order, the front end
    /// refreshes once.
    private func processSynchronously(_ keys: [String]) {
        let result = engine.processKeys(keys, gate: OpenKeyGate())
        if let final = result.snapshot { apply(final) }
        if let failure = result.error { onError?(failure) }
    }

    /// Drops the deferred keys without delivering them (a clear, a discard, the host
    /// going away). No dropped key reaches the engine after this returns.
    public func cancelPendingCodes() {
        guard batch != nil || !pendingCodes.isEmpty else { return }
        if let current = batch {
            batch = nil
            _ = current.stop(discarding: true)
        }
        pendingCodes = []
        pendingCodesRevision &+= 1
        onPendingCodesChanged?()
    }

    /// A candidate tapped while code keys were still decoding was picked from the list
    /// on screen, which those keys replace. After they land it is found again by its
    /// text on the current page; nil (select nothing) when it is gone, never whatever
    /// now sits at the same position. A candidate beyond the current page is known
    /// only by the caller's `seenText`.
    func settleBeforeSelecting(_ index: Int, absolute: Bool, seenText: String? = nil) -> Int? {
        guard batch != nil || !pendingCodes.isEmpty else { return index }
        let pageStart = absolute && snapshot.pageSize > 0 ? snapshot.pageIndex * snapshot.pageSize : 0
        let seen = seenText ?? snapshot.candidates.first { $0.index == index - pageStart }?.text
        drainPendingCodes()
        guard let seen, let match = snapshot.candidates.first(where: { $0.text == seen }) else { return nil }
        return absolute && snapshot.pageSize > 0 ? snapshot.pageIndex * snapshot.pageSize + match.index : match.index
    }

    /// Backspace on a key the engine has not seen yet just takes it back.
    public func removeLastPendingCode() -> Bool {
        guard pendingCodes.count > (batch?.keys.count ?? 0) else { return false }
        pendingCodes.removeLast()
        pendingCodesRevision &+= 1
        onPendingCodesChanged?()
        return true
    }
}
