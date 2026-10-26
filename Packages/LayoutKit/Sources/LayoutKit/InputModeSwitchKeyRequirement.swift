import Foundation

/// Entry-context rule for the system input-mode switch key: an App Store review expects a keyboard
/// switch key when the host reports that it needs one. The data package never reads UIKit, so the
/// caller passes the host flag. This is deliberately separate from `validate()`: a catalog saved on
/// a device without the requirement must stay readable, and only the explicit save/import entry
/// point applies the local requirement.
public extension LayoutDefinition {
    /// True when a primary `.globe` key is actually renderable. Long-press alternates never count,
    /// and an engine-owned disambiguation area is not an entry point the user can tap. The filter
    /// matches the runtime's own visible-area rule (`Facts.hasGlobe`): rows plus every auxiliary
    /// area that is not engine-owned; a configured/DIY layout draws both side columns.
    var hasInputModeSwitchKey: Bool {
        let areas = (auxiliaryAreas ?? []).filter { !$0.requiresEngineDisambiguation }
        return (rows.flatMap(\.keys) + areas.flatMap(\.keys)).contains { $0.action.type == .globe }
    }

    /// Callers pass the host's `needsInputModeSwitchKey`. A requirement failure names the missing
    /// key so the editor can point at the function area; `required == false` never throws.
    func validateRequiredInputModeSwitchKey(_ required: Bool) throws {
        guard required, !hasInputModeSwitchKey else { return }
        throw LayoutError.invalid("缺少地球键，请添加后再保存或导入。")
    }
}

public extension KeyboardPageDefinition {
    /// True when the page really offers a globe entry point.
    ///
    /// A legacy page (`chrome == nil`) still draws the built-in footer's globe until the editor
    /// materialises it, so it counts. Authored pages must carry the globe as data: rows on a row
    /// page, or the permanent function area. A categorised page's categories (and their recent
    /// snapshot) are content backups, not the fixed entry point, so only its chrome counts.
    var hasInputModeSwitchKey: Bool {
        guard let chrome else { return true }
        if symbolPresentation == .categorized {
            // Only the permanent function area is visible on every category, including the
            // recent/dynamic one whose content changes independently; a globe inside one category
            // disappears as soon as the user switches away, so it is not a stable entry point.
            return chrome.allKeys.contains { $0.action.type == .globe }
        }
        return (rows.flatMap(\.keys) + chrome.allKeys).contains { $0.action.type == .globe }
    }

    func validateRequiredInputModeSwitchKey(_ required: Bool) throws {
        guard required, !hasInputModeSwitchKey else { return }
        throw LayoutError.invalid("缺少地球键，请添加后再保存或导入。")
    }
}
