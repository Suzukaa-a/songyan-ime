import Foundation

/// An area of a page a key can live in. Editors move and copy keys between these areas; a
/// categorised page has no row area and its left rail is category navigation.
public enum KeyboardPageKeyRegion: Hashable, Sendable {
    case rows
    case chrome(KeyboardPageChrome.Region)
}

public extension KeyboardPageKeyPath {
    var region: KeyboardPageKeyRegion {
        switch self {
        case .row: return .rows
        case .chrome(let region, _): return .chrome(region)
        }
    }
}

public extension KeyboardPageChrome {
    func settingKeys(_ keys: [LayoutKey], in region: Region) -> KeyboardPageChrome {
        var chrome = self
        switch region {
        case .bottom: chrome.bottom = keys
        case .leading: chrome.leading = keys
        case .trailing: chrome.trailing = keys
        }
        return chrome
    }
}

public extension LayoutSplitConfiguration {
    /// Stores a cut for every row, clamped to the row's current key count, so adding or removing
    /// keys never leaves a cut outside its row.
    func adjusted(to rows: [LayoutRow]) -> LayoutSplitConfiguration {
        var split = self
        split.rowBreaks = rows.indices.map { breakIndex(row: $0, keyCount: rows[$0].keys.count) }
        return split
    }
}

/// Structural edits for the page editor. Every edit returns a new page (nil when the edit cannot
/// finish), so a move that fails halfway never loses the key, and every edit re-clamps the split
/// cuts to the rows it changed.
public extension KeyboardPageDefinition {
    /// Content rows plus the authored footer row. The footer cut lives at `rows.count`, so a stored
    /// footer cut stays editable.
    var splitRows: [LayoutRow] {
        guard let bottom = chrome?.bottom, !bottom.isEmpty else { return rows }
        return rows + [LayoutRow(keys: bottom)]
    }

    /// Areas the author can put keys in, in display order.
    var editableKeyRegions: [KeyboardPageKeyRegion] {
        let categorized = symbolPresentation == .categorized
        var regions: [KeyboardPageKeyRegion] = []
        if !categorized { regions.append(.rows) }
        regions.append(.chrome(.bottom))
        if !categorized { regions.append(.chrome(.leading)) }
        regions.append(.chrome(.trailing))
        return regions
    }

    /// The first key the editor selects: the first row key, else the first authored function key.
    var firstKeyPath: KeyboardPageKeyPath? {
        if symbolPresentation != .categorized, let first = rows.first, !first.keys.isEmpty {
            return .row(0, key: 0)
        }
        guard let chrome else { return nil }
        for region in [KeyboardPageChrome.Region.bottom, .trailing, .leading] where !chrome.keys(in: region).isEmpty {
            return .chrome(region, key: 0)
        }
        return nil
    }

    func settingSplitAdjusted(_ split: LayoutSplitConfiguration?) -> KeyboardPageDefinition {
        var page = self
        page.split = split?.adjusted(to: page.splitRows)
        return page
    }

    /// Whether the key can leave its place: a page keeps at least one content row, so the last key
    /// of the only row stays.
    func canRemoveKey(at path: KeyboardPageKeyPath) -> Bool {
        guard key(at: path) != nil else { return false }
        if case .row(let row, _) = path { return rows[row].keys.count > 1 || rows.count > 1 }
        return true
    }

    /// Whether one more key fits at the end of the area (the last row for the row area).
    func canAppendKey(to region: KeyboardPageKeyRegion) -> Bool {
        switch region {
        case .rows:
            guard let last = rows.last else { return false }
            return last.keys.count < LayoutResourceBudget.keysPerRegion
        case .chrome(let region):
            guard let chrome else { return false }
            return chrome.keys(in: region).count < LayoutResourceBudget.keysPerRegion
        }
    }

    func canMoveKey(at path: KeyboardPageKeyPath, to region: KeyboardPageKeyRegion) -> Bool {
        region != path.region && canRemoveKey(at: path) && canAppendKey(to: region)
    }

    func canCopyKey(at path: KeyboardPageKeyPath, to region: KeyboardPageKeyRegion) -> Bool {
        region != path.region && key(at: path) != nil && canAppendKey(to: region)
    }

    /// Removes one key. A row left without keys goes with it.
    func removingKey(at path: KeyboardPageKeyPath) -> KeyboardPageDefinition? {
        guard canRemoveKey(at: path) else { return nil }
        var page = self
        switch path {
        case .chrome(let region, let index):
            guard let chrome = page.chrome else { return nil }
            var keys = chrome.keys(in: region)
            keys.remove(at: index)
            page.chrome = chrome.settingKeys(keys, in: region)
        case .row(let row, let index):
            if page.rows[row].keys.count == 1 {
                page.rows.remove(at: row)
            } else {
                var keys = page.rows[row].keys
                keys.remove(at: index)
                page.rows[row] = LayoutRow(keys: keys)
            }
        }
        return page.settingSplitAdjusted(page.split)
    }

    /// Appends a key to the end of an area (the last row for the row area).
    func appendingKey(
        _ key: LayoutKey, to region: KeyboardPageKeyRegion
    ) -> (page: KeyboardPageDefinition, path: KeyboardPageKeyPath)? {
        guard canAppendKey(to: region) else { return nil }
        var page = self
        let path: KeyboardPageKeyPath
        switch region {
        case .rows:
            let row = page.rows.count - 1
            page.rows[row] = LayoutRow(keys: page.rows[row].keys + [key])
            path = .row(row, key: page.rows[row].keys.count - 1)
        case .chrome(let region):
            guard let chrome = page.chrome else { return nil }
            let keys = chrome.keys(in: region) + [key]
            page.chrome = chrome.settingKeys(keys, in: region)
            path = .chrome(region, key: keys.count - 1)
        }
        return (page.settingSplitAdjusted(page.split), path)
    }

    func movingKey(
        at path: KeyboardPageKeyPath, to region: KeyboardPageKeyRegion
    ) -> (page: KeyboardPageDefinition, path: KeyboardPageKeyPath)? {
        guard canMoveKey(at: path, to: region), let key = key(at: path) else { return nil }
        return removingKey(at: path)?.appendingKey(key, to: region)
    }

    func copyingKey(
        at path: KeyboardPageKeyPath, to region: KeyboardPageKeyRegion
    ) -> (page: KeyboardPageDefinition, path: KeyboardPageKeyPath)? {
        guard canCopyKey(at: path, to: region), let key = key(at: path) else { return nil }
        return appendingKey(key, to: region)
    }

    /// Swaps a function key with its neighbour inside its own area.
    func reorderingChromeKey(
        at path: KeyboardPageKeyPath, by offset: Int
    ) -> (page: KeyboardPageDefinition, path: KeyboardPageKeyPath)? {
        guard case .chrome(let region, let index) = path, let chrome else { return nil }
        var keys = chrome.keys(in: region)
        let target = index + offset
        guard keys.indices.contains(index), keys.indices.contains(target) else { return nil }
        keys.swapAt(index, target)
        return (settingChrome(chrome.settingKeys(keys, in: region)), .chrome(region, key: target))
    }

    /// Inserts a copy of a function key right after it.
    func duplicatingChromeKey(
        at path: KeyboardPageKeyPath
    ) -> (page: KeyboardPageDefinition, path: KeyboardPageKeyPath)? {
        guard case .chrome(let region, let index) = path, let chrome else { return nil }
        var keys = chrome.keys(in: region)
        guard keys.indices.contains(index), keys.count < LayoutResourceBudget.keysPerRegion else { return nil }
        keys.insert(keys[index], at: index + 1)
        let page = settingChrome(chrome.settingKeys(keys, in: region))
        return (page.settingSplitAdjusted(page.split), .chrome(region, key: index + 1))
    }

    /// Where the selection lands after the key at `path` was removed: its neighbour in the same
    /// area, else the first key the page still has.
    func selectionAfterRemoving(_ path: KeyboardPageKeyPath) -> KeyboardPageKeyPath? {
        switch path {
        case .chrome(let region, let index):
            let count = chrome?.keys(in: region).count ?? 0
            if count > 0 { return .chrome(region, key: min(index, count - 1)) }
        case .row(let row, let index):
            if rows.indices.contains(row), !rows[row].keys.isEmpty {
                return .row(row, key: min(index, rows[row].keys.count - 1))
            }
        }
        return firstKeyPath
    }
}
