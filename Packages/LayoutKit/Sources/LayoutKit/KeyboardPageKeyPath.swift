import Foundation

/// Stable structural address of one page key. The page editor, preview and budget all use the
/// same address instead of exposing separate row/footer/rail index spaces.
public enum KeyboardPageKeyPath: Hashable, Sendable {
    case row(Int, key: Int)
    case chrome(KeyboardPageChrome.Region, key: Int)
}

public extension KeyboardPageDefinition {
    /// Every key the page really carries: rows, category content and authored chrome. Budgets and
    /// render invalidation must not miss a category's top-level Enter or an authored footer key.
    var allKeys: [LayoutKey] {
        rows.flatMap(\.keys) + (categories ?? []).flatMap(\.keys) + chromeKeys
    }

    /// `allKeys.contains(where:)` without building the combined array; render paths call it.
    func containsKey(where predicate: (LayoutKey) throws -> Bool) rethrows -> Bool {
        for row in rows {
            if try row.keys.contains(where: predicate) { return true }
        }
        for category in categories ?? [] {
            if try category.keys.contains(where: predicate) { return true }
        }
        guard let chrome else { return false }
        return try chrome.bottom.contains(where: predicate) || chrome.leading.contains(where: predicate)
            || chrome.trailing.contains(where: predicate)
    }

    /// Authored function keys only; rows and categories may contain controls too.
    var chromeKeys: [LayoutKey] { chrome?.allKeys ?? [] }

    func key(at path: KeyboardPageKeyPath) -> LayoutKey? {
        switch path {
        case .row(let row, let key):
            guard rows.indices.contains(row), rows[row].keys.indices.contains(key) else { return nil }
            return rows[row].keys[key]
        case .chrome(let region, let key):
            guard let keys = chrome?.keys(in: region), keys.indices.contains(key) else { return nil }
            return keys[key]
        }
    }

    /// Draft mutation deliberately allows invalid intermediate values; save validates the whole
    /// draft. An address that no longer exists is a no-op, mirroring `LayoutDefinition`.
    func replacingKey(at path: KeyboardPageKeyPath, with key: LayoutKey) -> KeyboardPageDefinition {
        guard self.key(at: path) != nil else { return self }
        var page = self
        switch path {
        case .row(let row, let index):
            var keys = page.rows[row].keys
            keys[index] = key
            page.rows[row] = LayoutRow(keys: keys)
        case .chrome(let region, let index):
            if let chrome = page.chrome, let updated = chrome.replacingKey(in: region, at: index, with: key) {
                page.chrome = updated
            }
        }
        return page
    }

    func settingChrome(_ chrome: KeyboardPageChrome?) -> KeyboardPageDefinition {
        var page = self
        page.chrome = chrome
        return page
    }

    func settingSplit(_ split: LayoutSplitConfiguration?) -> KeyboardPageDefinition {
        var page = self
        page.split = split
        return page
    }
}
