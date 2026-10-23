import CandidateKit
import Foundation
import KeyboardCore
import LayoutKit
import UniformTypeIdentifiers

private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

private final class PasteFeed: @unchecked Sendable {
    let progress = CancelFlag()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    private var didStart = false
    var started: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didStart
    }

    func item() -> QuickPasteItem {
        QuickPasteItem {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    self.lock.lock()
                    self.didStart = true
                    self.continuation = continuation
                    self.lock.unlock()
                }
            } onCancel: {
                self.progress.set()
                self.lock.lock()
                let pending = self.continuation
                self.continuation = nil
                self.lock.unlock()
                pending?.resume(throwing: CancellationError())
            }
        }
    }

    /// Late emissions after cancellation are ignored, like a provider whose request was cancelled.
    func emit(_ url: URL?, error: Error? = nil) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        if let url {
            pending?.resume(returning: try! String(contentsOf: url, encoding: .utf8))
        } else {
            pending?.resume(throwing: error ?? NSError(domain: "fixture", code: 1))
        }
    }
}

@main struct QuickPasteChecks {
    @MainActor static func eventually(_ reason: String, _ predicate: () -> Bool) async {
        for _ in 0..<3000 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        preconditionFailure(reason)
    }

    static func immediate(_ url: URL) -> QuickPasteItem {
        immediate(try! String(contentsOf: url, encoding: .utf8))
    }

    static func immediate(_ text: String) -> QuickPasteItem {
        QuickPasteItem { text }
    }

    static func rejects(_ failure: QuickPasteFailure, _ items: [QuickPasteItem]) async {
        do {
            _ = try await QuickPasteReader.read(items, timeout: 0.5)
            preconditionFailure("invalid provider unexpectedly accepted")
        } catch { precondition(error as? QuickPasteFailure == failure) }
    }

    @MainActor static func readerChecks(_ root: URL) async throws {
        let text = "固定粘贴\n第二行 👩🏽‍💻 e\u{301}\t尾行"
        let copied = try await QuickPasteReader.read([immediate(text)])
        precondition(copied == text, "Unicode, combining characters, tabs and line breaks must survive")
        let combined = try await QuickPasteReader.read([immediate(text), immediate("second item")])
        precondition(combined == text + "\nsecond item")
        let boundary = String(repeating: "A", count: QuickPasteReader.maximumBytes)
        let exact = try await QuickPasteReader.read([immediate(boundary)])
        precondition(exact.utf8.count == QuickPasteReader.maximumBytes)
        await rejects(.tooLarge, [immediate(boundary), immediate("B")])
        await rejects(.tooLarge, [immediate(boundary + "A")])
        await rejects(.emptyText, [immediate("")])
        await rejects(.emptyText, [])
        let unsupported = QuickPasteItem(isPlainText: false) {
            preconditionFailure("unsupported type must never request contents")
        }
        let media = NSItemProvider()
        for type in [UTType.png.identifier, UTType.utf8PlainText.identifier] {
            media.registerFileRepresentation(forTypeIdentifier: type, fileOptions: [], visibility: .all) { _ in
                preconditionFailure("rich media must not silently load its plain-text alternative")
            }
        }
        let mediaItem = QuickPasteItem(media)
        precondition(!mediaItem.isPlainText)
        await rejects(.unsupportedContent, [mediaItem])
        await rejects(.unsupportedContent, [immediate("x"), mediaItem])
        await rejects(.unsupportedContent, [immediate("x"), unsupported])
        let neverLoad = QuickPasteItem {
            preconditionFailure("provider count must be bounded before requesting contents")
        }
        await rejects(.tooManyItems, Array(repeating: neverLoad, count: 9))
        let eight = try await QuickPasteReader.read(Array(repeating: immediate("second item"), count: 8))
        precondition(eight == Array(repeating: "second item", count: 8).joined(separator: "\n"))
        let slow = QuickPasteItem {
            try await Task.sleep(nanoseconds: 60_000_000)
            return "slow"
        }
        do {
            _ = try await QuickPasteReader.read([slow, slow], timeout: 0.1)
            preconditionFailure("a batch must not receive a fresh timeout for every provider")
        } catch { precondition(error as? QuickPasteFailure == .timedOut) }
        print("PASS: Unicode, size limit, provider limits and shared timeout")
    }

    @MainActor static func requestChecks(_ root: URL) async throws {
        var available = false
        var availabilityChecks = 0
        let availabilityModel = QuickPasteModel(
            inputContext: { preconditionFailure("availability must not capture host input") },
            insertLiteral: { _ in preconditionFailure("availability must not insert") },
            pasteAvailability: {
                availabilityChecks += 1
                return available
            })
        precondition(!availabilityModel.canPaste && availabilityChecks == 0)
        availabilityModel.activate()
        precondition(!availabilityModel.canPaste && availabilityChecks == 1 && availabilityModel.error == nil)
        available = true
        availabilityModel.refreshPasteAvailability()
        precondition(availabilityModel.canPaste && availabilityModel.error == nil && !availabilityModel.isLoading)
        available = false
        availabilityModel.refreshPasteAvailability()
        precondition(!availabilityModel.canPaste && availabilityModel.error == nil)
        availabilityModel.deactivate()
        let checksBeforeDetachedRefresh = availabilityChecks
        available = true
        availabilityModel.refreshPasteAvailability()
        precondition(!availabilityModel.canPaste && availabilityChecks == checksBeforeDetachedRefresh)
        availabilityModel.activate()
        precondition(availabilityModel.canPaste && availabilityModel.error == nil)
        availabilityModel.deactivate()
        print("PASS: metadata availability disables empty paste without content reads or error UI")
        let file = root.appendingPathComponent("request.txt")
        try Data("fixed request".utf8).write(to: file)
        var context: AnyHashable? = "document-A:epoch-1"
        var delivered: [String] = []
        var historyCaptures: [String] = []
        let model = QuickPasteModel(
            inputContext: { context },
            insertLiteral: {
                delivered.append($0)
                return true
            },
            didDispatchUserPaste: { historyCaptures.append($0) })
        let feed = PasteFeed()
        precondition(
            !feed.started && !model.isLoading && model.error == nil,
            "initialization must not request clipboard contents")
        model.receiveUserPaste([feed.item()])
        precondition(
            !feed.started && !model.isLoading && model.error == nil, "inactive callbacks must not load providers")
        model.activate()
        let imageProvider = NSItemProvider()
        imageProvider.registerFileRepresentation(
            forTypeIdentifier: UTType.png.identifier,
            fileOptions: [], visibility: .all
        ) { _ in
            preconditionFailure("image contents should remain available for the host's system paste")
        }
        model.receiveSystemPaste([imageProvider])
        await eventually("media callback did not finish") { !model.isLoading }
        precondition(delivered.isEmpty && model.error == QuickPasteFailure.unsupportedContent.message)
        context = nil
        model.receiveUserPaste([feed.item()])
        precondition(!feed.started && model.error == QuickPasteFailure.noActiveInput.message)
        context = "document-A:epoch-1"
        model.receiveUserPaste([feed.item()])
        await eventually("provider did not start") { feed.started }
        context = "document-A:epoch-2"
        feed.emit(file)
        await eventually("context check did not finish") { !model.isLoading }
        precondition(delivered.isEmpty && model.error == QuickPasteFailure.contextChanged.message)

        let cancelled = PasteFeed()
        model.receiveUserPaste([cancelled.item()])
        await eventually("cancel provider did not start") { cancelled.started }
        model.cancel()
        await eventually("cancel did not reach provider Progress") { cancelled.progress.isCancelled }
        cancelled.emit(file)
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(delivered.isEmpty && !model.isLoading)
        model.deactivate()
        let lateTarget = PasteFeed()
        model.receiveUserPaste([lateTarget.item()])
        model.receiveSystemPaste([NSItemProvider()])
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(
            !lateTarget.started && !model.isLoading && delivered.isEmpty,
            "a dismantled target must never capture a later host and start another request")
        precondition(historyCaptures.isEmpty, "inactive, rejected context and cancelled pastes must not reach history")
        model.activate()

        let superseded = PasteFeed()
        model.receiveUserPaste([superseded.item()])
        await eventually("superseded provider did not start") { superseded.started }
        model.receiveUserPaste([immediate(file)])
        await eventually("latest request did not finish") { !model.isLoading }
        await eventually("superseded Progress was not cancelled") { superseded.progress.isCancelled }
        superseded.emit(file)
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(delivered == ["fixed request"] && model.error == nil, "only the latest request can dispatch once")

        precondition(historyCaptures == delivered, "successful explicit paste must notify history exactly once")

        let timedFeed = PasteFeed()
        let timed = QuickPasteModel(
            inputContext: { context }, insertLiteral: { _ in preconditionFailure("timeout must not insert") },
            providerTimeout: 0.03)
        timed.activate()
        timed.receiveUserPaste([timedFeed.item()])
        await eventually("timeout provider did not start") { timedFeed.started }
        await eventually("provider timeout did not finish") { !timed.isLoading }
        precondition(timed.error == QuickPasteFailure.timedOut.message && timedFeed.progress.isCancelled)
        timedFeed.emit(file)
        let failing = PasteFeed()
        model.receiveUserPaste([failing.item()])
        await eventually("failing provider did not start") { failing.started }
        failing.emit(nil, error: NSError(domain: "fixture-provider-denied", code: 1))
        await eventually("provider error did not finish") { !model.isLoading }
        precondition(model.error == QuickPasteFailure.providerUnavailable.message && delivered.count == 1)

        model.receiveUserPaste([immediate(file), immediate("")])
        await eventually("partial validation did not finish") { !model.isLoading }
        precondition(
            model.error == QuickPasteFailure.emptyText.message && delivered.count == 1,
            "never insert a partial provider list")
        model.receiveSystemPaste([NSItemProvider(object: "fixed request" as NSString)])
        await eventually("actual Foundation provider did not finish") { !model.isLoading }
        precondition(
            model.error == nil && delivered == ["fixed request", "fixed request"],
            "the real NSItemProvider adapter must load plain text")
        precondition(historyCaptures == delivered, "provider errors and partial validation must not capture history")
        print("PASS: explicit intent, missing focus, selection epoch, cancel, supersede, timeout and no partial paste")
    }

    @MainActor static func literalChecks(_ root: URL) async throws {
        let file = root.appendingPathComponent("literal.txt")
        let pasted = "固定 literal\n第二行"
        try Data(pasted.utf8).write(to: file)
        for refusal in [0, 1, 2] {
            let engine = ProbeEngine()
            engine.state.isComposing = true
            engine.state.rawInput = "ni"
            engine.state.candidates = [Candidate(index: 0, text: "c0")]
            let controller = KeyboardController(engine: engine)
            var attempts: [String] = []
            var accepted: [String] = []
            controller.onDispatchCommit = { text in
                attempts.append(text)
                let accepts = refusal == 0 || (refusal == 2 && text == "c0")
                if accepts { accepted.append(text) }
                return accepts
            }
            var historyCaptures: [String] = []
            let model = QuickPasteModel(
                inputContext: { "fixed-live-input" },
                insertLiteral: { controller.insertLiteral($0) },
                didDispatchUserPaste: { historyCaptures.append($0) })
            model.activate()
            model.receiveUserPaste([immediate(file)])
            await eventually("literal outlet did not finish") { !model.isLoading }
            if refusal == 0 {
                precondition(attempts == ["c0", pasted] && accepted == attempts && model.error == nil)
            } else if refusal == 1 {
                precondition(
                    attempts == ["c0"] && accepted.isEmpty && model.error == QuickPasteFailure.hostRejected.message,
                    "refused composition must prevent the dependent literal")
            } else {
                precondition(
                    attempts == ["c0", pasted] && accepted == ["c0"]
                        && model.error == QuickPasteFailure.hostRejected.message,
                    "a partial composition commit must not masquerade as a successful paste")
            }
            precondition(
                historyCaptures == (refusal == 0 ? [pasted] : []),
                "only the fully dispatched literal can be captured; composition alone is not a paste")
            controller.retire()
        }
        print(
            "PASS: actual controller/session confirms composition before one literal and reports host refusal truthfully"
        )
    }

    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        try await readerChecks(root)
        try await requestChecks(root)
        try await literalChecks(root)
    }
}
