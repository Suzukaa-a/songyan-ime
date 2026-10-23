import Combine
import Foundation
import UniformTypeIdentifiers
import os

enum QuickPasteFailure: Error, Equatable {
    case unsupportedContent, tooManyItems, tooLarge, emptyText
    case providerUnavailable, timedOut
    case noActiveInput, contextChanged, hostRejected

    var message: String {
        switch self {
        case .unsupportedContent: return "图片或富文本请长按输入框，使用系统「粘贴」"
        case .tooManyItems: return "一次最多粘贴 8 项文字"
        case .tooLarge: return "粘贴文字超出 64 KB 限制"
        case .emptyText: return "剪贴板中没有可粘贴的文字"
        case .providerUnavailable: return "系统未能提供粘贴文字，请检查权限后重试"
        case .timedOut: return "读取粘贴文字超时，请重试"
        case .noActiveInput: return "当前没有可用的输入框"
        case .contextChanged: return "输入位置已改变，请重新粘贴"
        case .hostRejected: return "未能将文字粘贴到当前输入框"
        }
    }
}

struct QuickPasteIdleInput: Equatable {
    var isComposing = false
    var hasPrediction = false
    var hasCandidates = false
    var hasEnglishSuggestions = false
    var hasActiveEnglishInput = false
    var hasStatus = false
    var hasCompositionFallback = false
    var hasReadingContent = false
    var hasPendingQueries = false
    var isExpanded = false
    var isCovered = false

    var allowsPaste: Bool {
        !isComposing && !hasPrediction && !hasCandidates && !hasEnglishSuggestions
            && !hasActiveEnglishInput && !hasStatus && !hasCompositionFallback
            && !hasReadingContent && !hasPendingQueries && !isExpanded && !isCovered
    }
}

@MainActor
final class QuickPasteSlotLease {
    private struct Context: Hashable {
        let host: AnyHashable
        let revision: UInt64
    }
    private var observedIdentity: ObjectIdentifier?
    private var observation: AnyCancellable?
    private var revision: UInt64 = 0
    private var eligible = false

    func observe(identity: ObjectIdentifier, changes: AnyPublisher<Void, Never>) {
        guard observedIdentity != identity else { return }
        observedIdentity = identity
        revision &+= 1
        observation = changes.sink { [weak self] in self?.revision &+= 1 }
    }

    func updateEligibility(_ value: Bool) {
        guard eligible != value else { return }
        eligible = value
        revision &+= 1
    }

    func isCurrent(identity: ObjectIdentifier) -> Bool {
        eligible && observedIdentity == identity
    }

    func context(host: AnyHashable?) -> AnyHashable? {
        guard eligible, let host else { return nil }
        return AnyHashable(Context(host: host, revision: revision))
    }
}

/// Only provider metadata is inspected at construction. Contents load after the system paste callback.
struct QuickPasteItem: Sendable {
    fileprivate static let nativeTypes = [
        UTType.image.identifier, UTType.audiovisualContent.identifier,
        UTType.rtf.identifier, UTType.html.identifier,
        UTType.pdf.identifier, UTType.fileURL.identifier,
    ]
    let isPlainText: Bool
    let load: @Sendable () async throws -> String

    init(_ provider: NSItemProvider) {
        let needsNativePaste = Self.nativeTypes.contains { provider.hasItemConformingToTypeIdentifier($0) }
        isPlainText = !needsNativePaste && provider.canLoadObject(ofClass: NSString.self)
        // NSItemProvider loads from any thread; it is just not annotated Sendable.
        nonisolated(unsafe) let provider = provider
        load = {
            try Task.checkCancellation()
            let progress = OSAllocatedUnfairLock<Progress?>(initialState: nil)
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let started = provider.loadObject(ofClass: NSString.self) { object, error in
                        if let text = object as? String {
                            continuation.resume(returning: text)
                        } else {
                            continuation.resume(throwing: error ?? QuickPasteFailure.providerUnavailable)
                        }
                    }
                    progress.withLock { $0 = started }
                }
            } onCancel: {
                progress.withLock { $0 }?.cancel()
            }
        }
    }

    init(isPlainText: Bool = true, load: @escaping @Sendable () async throws -> String) {
        self.isPlainText = isPlainText
        self.load = load
    }
}

enum QuickPasteReader {
    static let maximumBytes = 64 * 1024
    static let maximumItems = 8

    /// Loads every item in order, newline-joined, within one shared deadline.
    static func read(_ items: [QuickPasteItem], timeout: TimeInterval = 10) async throws -> String {
        guard !items.isEmpty else { throw QuickPasteFailure.emptyText }
        guard items.count <= maximumItems else { throw QuickPasteFailure.tooManyItems }
        guard items.allSatisfy(\.isPlainText) else { throw QuickPasteFailure.unsupportedContent }
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                var text = ""
                for (index, item) in items.enumerated() {
                    let value = try await item.load()
                    guard !value.isEmpty else { throw QuickPasteFailure.emptyText }
                    if index > 0 { text += "\n" }
                    text += value
                    guard text.utf8.count <= maximumBytes else { throw QuickPasteFailure.tooLarge }
                }
                return text
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw QuickPasteFailure.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next() ?? ""
        }
    }
}

@MainActor
final class QuickPasteModel: ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var canPaste = false
    @Published private(set) var error: String?
    private let inputContext: @MainActor () -> AnyHashable?
    private let insertLiteral: @MainActor (String) -> Bool
    private let didDispatchUserPaste: @MainActor (String) -> Void
    private let providerTimeout: TimeInterval
    private let pasteAvailability: @MainActor () -> Bool
    private var availabilityObservation: AnyCancellable?
    private var isActive = false
    /// Bumped by every `activate()`, so a deferred deactivation can tell it is stale.
    private(set) var activationGeneration = 0
    private var requestID: UUID?
    private var operation: Task<Void, Never>?

    init(
        inputContext: @escaping @MainActor () -> AnyHashable?,
        insertLiteral: @escaping @MainActor (String) -> Bool, providerTimeout: TimeInterval = 10,
        pasteAvailability: (@MainActor () -> Bool)? = nil,
        didDispatchUserPaste: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.inputContext = inputContext
        self.insertLiteral = insertLiteral
        self.didDispatchUserPaste = didDispatchUserPaste
        self.providerTimeout = providerTimeout
        self.pasteAvailability = pasteAvailability ?? Self.pasteboardHasSupportedContent
    }

    /// The button appears again after every commit; each check is four synchronous
    /// pasteboard-server round trips on the main thread. The answer only changes with
    /// the pasteboard's contents, so it is kept per `changeCount`.
    private static var checkedPasteboard: (changeCount: Int, supported: Bool)?

    private static func pasteboardHasSupportedContent() -> Bool {
        #if canImport(UIKit)
            let board = UIPasteboard.general
            let changeCount = board.changeCount
            if let checked = checkedPasteboard, checked.changeCount == changeCount { return checked.supported }
            let supported =
                board.hasStrings && !board.hasImages
                && (1...QuickPasteReader.maximumItems).contains(board.numberOfItems)
                && !board.contains(pasteboardTypes: QuickPasteItem.nativeTypes)
            checkedPasteboard = (changeCount, supported)
            return supported
        #else
            return false
        #endif
    }

    func refreshPasteAvailability() {
        let available = isActive && pasteAvailability()
        if canPaste != available { canPaste = available }
    }

    func activate() {
        isActive = true
        activationGeneration &+= 1
        #if canImport(UIKit)
            availabilityObservation = NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)
                .merge(with: NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification))
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refreshPasteAvailability() }
        #endif
        refreshPasteAvailability()
    }

    func deactivate() {
        isActive = false
        availabilityObservation = nil
        canPaste = false
        cancel()
    }

    func receiveSystemPaste(_ providers: [NSItemProvider]) {
        guard isActive else { return }
        guard providers.count <= QuickPasteReader.maximumItems else {
            cancel()
            error = QuickPasteFailure.tooManyItems.message
            return
        }
        receiveUserPaste(providers.map(QuickPasteItem.init))
    }

    /// Called only by an explicit user paste action or the system provider callback.
    func receiveUserPaste(_ items: [QuickPasteItem]) {
        guard isActive else { return }
        cancel()
        guard let baseline = inputContext() else {
            error = QuickPasteFailure.noActiveInput.message
            return
        }
        let id = UUID()
        requestID = id
        isLoading = true
        let timeout = providerTimeout
        operation = Task { [weak self] in
            do {
                let text = try await QuickPasteReader.read(items, timeout: timeout)
                guard let self, self.requestID == id, !Task.isCancelled else { return }
                guard self.inputContext() == baseline else {
                    self.finish(id, failure: .contextChanged)
                    return
                }
                // The outlet confirms composition first and reports whether dispatch was accepted.
                // Public proxy APIs do not prove that the host document incorporated the text.
                let dispatched = self.insertLiteral(text)
                if dispatched { self.didDispatchUserPaste(text) }
                self.finish(id, failure: dispatched ? nil : .hostRejected)
            } catch {
                guard let self, self.requestID == id, !Task.isCancelled else { return }
                self.finish(id, failure: (error as? QuickPasteFailure) ?? .providerUnavailable)
            }
        }
    }

    func cancel() {
        let previous = operation
        operation = nil
        requestID = nil
        isLoading = false
        error = nil
        previous?.cancel()
    }

    private func finish(_ id: UUID, failure: QuickPasteFailure?) {
        guard requestID == id else { return }
        operation = nil
        requestID = nil
        isLoading = false
        error = failure?.message
    }
}

#if canImport(UIKit)
    import UIKit
    import SwiftUI

    struct QuickPasteView: View {
        @StateObject private var model: QuickPasteModel
        private let foreground: UIColor
        private let onError: @MainActor (String?) -> Void

        init(
            inputContext: @escaping @MainActor () -> AnyHashable?,
            insertLiteral: @escaping @MainActor (String) -> Bool,
            foreground: UIColor = .label,
            onError: @escaping @MainActor (String?) -> Void,
            didDispatchUserPaste: @escaping @MainActor (String) -> Void = { _ in }
        ) {
            self.foreground = foreground
            self.onError = onError
            _model = StateObject(
                wrappedValue: QuickPasteModel(
                    inputContext: inputContext, insertLiteral: insertLiteral,
                    didDispatchUserPaste: didDispatchUserPaste))
        }

        var body: some View {
            ZStack {
                QuickPasteIconButton(model: model, foreground: foreground)
                    .disabled(!model.canPaste || model.isLoading)
                if model.isLoading {
                    Button {
                        model.cancel()
                    } label: {
                        Image(systemName: "xmark").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("取消粘贴")
                    .tint(Color(uiColor: foreground))
                }
            }
            .frame(width: 44, height: 44)
            .onChange(of: model.error) { _, error in onError(error) }
            .onAppear { model.activate() }
            .onDisappear { model.deactivate() }
        }
    }

    private struct QuickPasteIconButton: UIViewRepresentable {
        @ObservedObject var model: QuickPasteModel
        let foreground: UIColor

        final class Coordinator: UIResponder {
            let model: QuickPasteModel
            init(model: QuickPasteModel) {
                self.model = model
                super.init()
                pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [UTType.item.identifier])
            }
            override func canPaste(_ itemProviders: [NSItemProvider]) -> Bool {
                !itemProviders.isEmpty
            }
            override func paste(itemProviders: [NSItemProvider]) {
                model.receiveSystemPaste(itemProviders)
            }
            /// Standard paste action, invoked only by the visible button's user tap.
            /// iOS retains control of paste permission for contents from other apps.
            override func paste(_ sender: Any?) {
                model.refreshPasteAvailability()
                guard model.canPaste, !model.isLoading else { return }
                model.receiveSystemPaste(UIPasteboard.general.itemProviders)
            }
        }

        func makeCoordinator() -> Coordinator { Coordinator(model: model) }
        func makeUIView(context: Context) -> UIButton {
            var configuration = UIButton.Configuration.plain()
            configuration.contentInsets = .zero
            configuration.background = .clear()
            let control = UIButton(configuration: configuration)
            let icon = UIImageView(image: UIImage(systemName: "clipboard")?.withAlignmentRectInsets(.zero))
            icon.contentMode = .scaleAspectFit
            icon.isUserInteractionEnabled = false
            icon.translatesAutoresizingMaskIntoConstraints = false
            control.addSubview(icon)
            NSLayoutConstraint.activate([
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),
                icon.centerXAnchor.constraint(equalTo: control.centerXAnchor),
                icon.centerYAnchor.constraint(equalTo: control.centerYAnchor),
            ])
            control.tintColor = foreground
            control.isEnabled = model.canPaste && !model.isLoading
            control.alpha = control.isEnabled ? 1 : 0.3
            control.isHidden = model.isLoading
            control.addTarget(
                context.coordinator, action: #selector(UIResponderStandardEditActions.paste(_:)), for: .touchUpInside)
            control.configurationUpdateHandler = { button in
                var value = button.configuration
                value?.background = .clear()
                value?.baseForegroundColor = button.tintColor
                button.configuration = value
                button.alpha = button.isEnabled ? (button.isHighlighted ? 0.55 : 1) : 0.3
            }
            control.accessibilityIdentifier = "quickPaste.iconButton"
            control.accessibilityLabel = "粘贴"
            return control
        }
        func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIButton, context: Context) -> CGSize? {
            CGSize(width: 44, height: 44)
        }
        func updateUIView(_ control: UIButton, context: Context) {
            control.tintColor = foreground
            control.isEnabled = model.canPaste && !model.isLoading
            control.isHidden = model.isLoading
            control.setNeedsUpdateConfiguration()
        }
        static func dismantleUIView(_ control: UIButton, coordinator: Coordinator) {
            control.removeTarget(
                coordinator, action: #selector(UIResponderStandardEditActions.paste(_:)), for: .touchUpInside)
            // Dismantling runs inside SwiftUI's graph teardown: publishing `canPaste` from
            // here re-entered the dying graph and aborted the extension ("Fatal access
            // conflict" in GraphHost.asyncTransaction) once replaced keyboards were freed.
            // Deactivate on the next turn, unless a new mount activated the model again.
            let generation = coordinator.model.activationGeneration
            Task { @MainActor in
                guard coordinator.model.activationGeneration == generation else { return }
                coordinator.model.deactivate()
            }
        }
    }
#endif
