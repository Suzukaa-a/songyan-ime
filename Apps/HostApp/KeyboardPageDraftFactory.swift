import Foundation
import KeyboardCore
import LayoutKit
import QuickContentKit

/// Copies the same categories the keyboard displays, before the editor opens.
enum KeyboardPageDraftFactory {
    static func recentKeys() async throws -> [LayoutKey] {
        try await HostConfigIOQueue.async {
            let directory = SymbolLibraryStorage.defaultStoreDirectory()
            var readError: Error?
            let texts = RecentSymbolStore(directory: directory).read { readError = $0 }
            if let readError { throw readError }
            return texts.map { .init(label: $0, action: .init(.literal, value: $0)) }
        }
    }

    /// Opens an existing page for editing with the same id and name. Function keys become authored
    /// chrome and a categorized page gets the categories the keyboard currently shows, because the
    /// editor mutates data and can never read that library on the main thread.
    static func editableDraft(
        _ page: KeyboardPageDefinition, numericForm: KeyboardNumericForm = .rows,
        numericMarks: KeyboardNumericMarks = .chinese
    ) async throws -> KeyboardPageDefinition {
        var resolved = page
        if resolved.symbolPresentation == .categorized && resolved.categories == nil {
            // Legacy browser rows stay in the draft: resolving the category snapshot must not
            // delete content the stored page still carries.
            resolved.categories = try await authoredCategories()
        }
        let marks = resolved.defaultSymbolMarks ?? numericMarks
        var draft = resolved.materialized(numericForm: numericForm, numericMarks: marks)
        // Only a page that truly followed the keyboard stays nil. An automatic page whose wire data
        // pins an initial branch keeps that author choice when opened for editing.
        if resolved.defaultSymbolMarks == nil && resolved.resolvesAtRuntime {
            draft.defaultSymbolMarks = nil
        }
        return draft
    }

    /// A copy always carries the current function keys as real data. An automatic 123 page is
    /// materialized in the shape the caller selects (the running main layout's digit pad or the
    /// ten-column row page), and an automatic symbol page in the presentation requested.
    static func copy(
        _ page: KeyboardPageDefinition, presentation: KeyboardSymbolPresentation? = nil,
        numericMarks: KeyboardNumericMarks? = nil, numericForm: KeyboardNumericForm? = nil
    ) async throws -> KeyboardPageDefinition {
        var base = page
        if base.numericPresentation == .automatic {
            let marks = numericMarks ?? .chinese
            let form = numericForm ?? .rows
            var copy = base.copy(numericMarks: marks, numericForm: form)
            copy.name = numericCopyName(marks: marks, form: form)
            try copy.validate()
            return copy
        }
        if base.symbolPresentation == .automatic, let presentation, presentation != .automatic {
            switch presentation {
            case .rows:
                // Keep the automatic presentation until the model materializes it: only that branch
                // knows whether the stored rows are still the canonical preset (then it may take the
                // initial-language snapshot) or author-modified (then it keeps them, along with the
                // author's split). Hand-picking a preset here would discard both.
                var copy = base.copy(
                    name: page.name + " 副本", numericMarks: numericMarks ?? .chinese,
                    numericForm: numericForm ?? .rows)
                if numericMarks == nil { copy.defaultSymbolMarks = nil }
                try copy.validate()
                return copy
            case .categorized:
                // Categorized copies take the live library snapshot below; their initial branch
                // follows the keyboard unless the caller pinned one.
                base.chrome = nil
                base.symbolPresentation = .categorized
                base.rows = []
                base.categories = try await authoredCategories()
            case .automatic:
                break
            }
        }
        if base.symbolPresentation == .categorized && base.categories == nil {
            base.categories = try await authoredCategories()
        }
        var copy = base.copy(numericMarks: numericMarks ?? .chinese, numericForm: numericForm ?? .rows)
        // Runtime-resolved pages never pick a branch on their own; only a caller's explicit choice
        // pins the copy. Authored pages keep the initial branch they were saved with.
        if page.resolvesAtRuntime { copy.defaultSymbolMarks = numericMarks }
        try copy.validate()
        return copy
    }

    private static func numericCopyName(marks: KeyboardNumericMarks, form: KeyboardNumericForm) -> String {
        switch form {
        // The digit pad's keys are the same digits in both languages.
        case .phoneDigitPad: return UserTerminology.phoneDigitPad + " 副本"
        case .rows: return (marks == .ascii ? "英文 123 副本" : "中文 123 副本")
        }
    }

    /// The category snapshot the keyboard draws: the user's symbol library, recent symbols and
    /// quick symbols, in display order. Reads on the serial configuration queue, never the main thread.
    private static func authoredCategories() async throws -> [KeyboardPageCategory] {
        try await HostConfigIOQueue.async {
            let directory = SymbolLibraryStorage.defaultStoreDirectory()
            var readError: Error?
            let catalog = SymbolCatalogStore(directory: directory).loadActive { readError = $0 }
            if let readError { throw readError }
            let recents = RecentSymbolStore(directory: directory).read { readError = $0 }
            if let readError { throw readError }
            let quick: String
            if let shared = KeyboardRecipeStore.sharedContainerURL() {
                quick = try T9QuickSymbolStore(
                    directory: shared.appendingPathComponent("KeyboardQuickSymbols", isDirectory: true)
                ).load().symbols
            } else {
                quick = T9QuickSymbolStore.defaultSymbols
            }
            let displayed = SymbolPageTable.phoneSymbolCategories(
                ascii: false, recents: recents,
                library: catalog.orderedCategories.map {
                    .init(id: $0.id, title: $0.name, symbols: catalog.items(in: $0.id).map(\.text))
                })
            var result = displayed.map { category in
                KeyboardPageCategory(
                    id: category.id, name: category.title, columns: category.columns,
                    keys: category.caps.map { .init(label: $0.title, action: .init(.literal, value: $0.title)) },
                    source: category.id == SymbolPageTable.recentCategoryID ? .recent : .fixed)
            }
            if !result.contains(where: { $0.source == .recent }) {
                result.insert(.init(id: SymbolPageTable.recentCategoryID, name: "最近", keys: [], source: .recent), at: 1)
            }
            // Preserve the user's quick symbols even when the current common tab does not contain them.
            if let common = result.firstIndex(where: { $0.id == SymbolPageTable.commonCategoryID }) {
                let existing = Set(result[common].keys.compactMap { $0.action.value })
                result[common].keys += BuiltinLayouts.t9QuickSymbolValues(saved: quick, ascii: false)
                    .filter { !existing.contains($0) }
                    .map { .init(label: $0, action: .init(.literal, value: $0)) }
            }
            return result
        }
    }
}
