import CandidateKit
import KeyboardCore
import OSLog
import QuickContentKit
import SwiftUI

/// All local quick-content work uses a shared writable directory; there is no
/// private-container fallback that could imply settings reached the extension.
private struct LocalQuickContentAccessError: LocalizedError {
    var errorDescription: String? {
        "常用语与剪贴板暂不可用，请在系统设置中打开「允许完全访问」后重试"
    }
}

enum SharedQuickContentStorage {
    private static func directory() throws -> URL {
        guard let container = KeyboardRecipeStore.sharedContainerURL() else {
            throw LocalQuickContentAccessError()
        }
        return container.appendingPathComponent(LocalQuickContentStore.directoryName, isDirectory: true)
    }

    /// Read access creates nothing: browsing must not leave a directory behind for a user who
    /// never saved anything, and a read-only container can still show what is stored.
    static func read<T>(_ body: (LocalQuickContentStore) throws -> T) throws -> T {
        let store = LocalQuickContentStore(directory: try directory())
        do {
            return try body(store)
        } catch let failure where isPermissionDenied(failure) {
            throw LocalQuickContentAccessError()
        }
    }

    /// Write access: prove the directory is writable before a mutation, so a missing Full Access
    /// grant is reported as such and other write failures keep their own message.
    static func store() throws -> LocalQuickContentStore {
        let directory = try directory()
        guard KeyboardRecipeStore.canWriteSharedContainer else { throw LocalQuickContentAccessError() }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let probe = directory.appendingPathComponent(".access-\(UUID().uuidString)")
            try Data().write(to: probe, options: .atomic)
            try FileManager.default.removeItem(at: probe)
        } catch {
            if isPermissionDenied(error) { throw LocalQuickContentAccessError() }
            throw SymbolCatalogError("暂时无法保存，请稍后重试")
        }
        return LocalQuickContentStore(directory: directory)
    }

    private static func isPermissionDenied(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain,
            [NSFileWriteNoPermissionError, NSFileReadNoPermissionError, NSFileWriteVolumeReadOnlyError].contains(
                error.code)
        {
            return true
        }
        if error.domain == NSPOSIXErrorDomain, [EPERM, EACCES, EROFS].contains(Int32(error.code)) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? Error { return isPermissionDenied(underlying) }
        return false
    }

    static func recordExplicitPaste(_ text: String) async -> String? {
        // Text history cannot hold (blank or over 4 KB) is simply not recorded: the paste
        // itself succeeded, so there is nothing for the user to fix.
        // Without Full Access the shared history is read-only; the paste stands unrecorded.
        guard LocalQuickContentStore.canRecord(text), KeyboardRecipeStore.canWriteSharedContainer else { return nil }
        return await SymbolLibraryWriteQueue.async {
            do {
                guard let container = KeyboardRecipeStore.sharedContainerURL() else { return nil }
                let directory = container.appendingPathComponent(
                    LocalQuickContentStore.directoryName, isDirectory: true)
                // Missing or inaccessible settings never imply opt-in and never create a private fallback.
                guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("content.json").path)
                else { return nil }
                let store = LocalQuickContentStore(directory: directory)
                // An unreadable setting cannot prove consent. Show storage problems in management,
                // rather than warning about an optional history feature the user may never have enabled.
                guard let state = try? store.read(), state.clipboardEnabled else { return nil }
                _ = try store.recordExplicitPaste(text)
                return nil
            } catch {
                return "已粘贴，但没能保存到剪贴板历史"
            }
        }
    }
}

@MainActor
final class LocalQuickContentModel: ObservableObject {
    @Published private(set) var content = LocalQuickContent()
    @Published private(set) var isBusy = false
    @Published private(set) var isAvailable = false
    @Published var error: String?
    @Published var exportedPhrases: Data?
    private var operation: Task<Void, Never>?

    func reload() { perform(clearOnFailure: true, readOnly: true) { try $0.read() } }
    func setClipboardEnabled(_ value: Bool) { perform { try $0.setClipboardEnabled(value) } }
    func clearClipboard() { perform { try $0.clearClipboard() } }
    func deleteClipboard(_ text: String) { perform { try $0.deleteClipboard(text) } }
    /// Saves one phrase and reports the real outcome, so the editor can keep the draft unless the
    /// phrase actually reached disk. Returns a user-facing message when nothing was written, `nil` on
    /// success. Deliberately not routed through `perform`: its busy guard drops a save silently.
    func savePhrase(_ phrase: CommonPhrase) async -> String? {
        // A new phrase over the limit is known before any disk work, and the store's own rejection
        // reuses import wording that reads oddly here.
        if !content.phrases.contains(where: { $0.id == phrase.id }),
            content.phrases.count >= LocalQuickContentStore.maximumPhrases
        {
            let message = "常用语最多保存 100 条，请先删除一条再保存"
            error = message
            return message
        }
        let result = await SymbolLibraryWriteQueue.async {
            Result { try SharedQuickContentStorage.store().savePhrase(phrase) }
        }
        switch result {
        case .success(let content):
            self.content = content
            isAvailable = true
            error = nil
            return nil
        case .failure(let failure):
            // Lost access clears the in-memory copy; an ordinary failure (a full list, a disk
            // problem) leaves what was already saved on screen untouched.
            if failure is LocalQuickContentAccessError || !(failure is SymbolCatalogError) {
                content = LocalQuickContent()
                isAvailable = false
            }
            let message = Self.message(for: failure)
            error = message
            return message
        }
    }
    func deletePhrase(_ id: UUID) { perform { try $0.deletePhrase(id) } }
    func importPhrases(from url: URL) {
        perform { store in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return try store.importPhrases(from: url)
        }
    }
    nonisolated static func message(for error: Error) -> String {
        if error is LocalQuickContentAccessError { return LocalQuickContentAccessError().localizedDescription }
        if let error = error as? SymbolCatalogError { return error.message }
        return "无法读取或保存内容，请稍后重试"
    }

    func exportPhrases() {
        guard !isBusy else { return }
        isBusy = true
        operation = Task {
            let result = await SymbolLibraryWriteQueue.async {
                Result { try SharedQuickContentStorage.read { try $0.exportPhrases() } }
            }
            isBusy = false
            switch result {
            case .success(let data):
                exportedPhrases = data
                error = nil
            case .failure(let failure): error = Self.message(for: failure)
            }
        }
    }
    private func perform(
        clearOnFailure: Bool = false, readOnly: Bool = false,
        _ action: @escaping @Sendable (LocalQuickContentStore) throws -> LocalQuickContent
    ) {
        guard !isBusy else { return }
        isBusy = true
        operation = Task {
            let result = await SymbolLibraryWriteQueue.async {
                Result {
                    try readOnly ? SharedQuickContentStorage.read(action) : action(SharedQuickContentStorage.store())
                }
            }
            isBusy = false
            switch result {
            case .success(let content):
                self.content = content
                isAvailable = true
                error = nil
            case .failure(let failure):
                // Clear sensitive in-memory data when access is lost; report no successful mutation.
                if clearOnFailure || failure is LocalQuickContentAccessError || !(failure is SymbolCatalogError) {
                    content = LocalQuickContent()
                    isAvailable = false
                }
                error = Self.message(for: failure)
            }
        }
    }
}
