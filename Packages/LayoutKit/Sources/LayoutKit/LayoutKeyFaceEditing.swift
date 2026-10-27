import Foundation

/// Title edits for key editors. `allowsTitleMode` is true where keys can follow the live keyboard
/// state (pages, and main-layout function keys); elsewhere every edit keeps the stored face.
public extension LayoutKey {
    var isFunctionKey: Bool { action.type != .code && action.type != .literal }

    /// Literal keys with a live face (a paired branch, or an explicit title mode carried by new
    /// built-in rows) get the same follow-function/custom choice as function keys. A legacy fixed
    /// literal with no title mode never had one.
    var supportsLiveTitle: Bool {
        if isFunctionKey { return true }
        guard action.type == .literal else { return false }
        return action.asciiValue != nil || titleMode != nil
    }

    /// A legacy space key or paired literal without a title mode always shows its stored label;
    /// showing "follow" for it would promise a live title it never had. Other implicit nil cases
    /// (enter, globe, backspace, shift) keep following the live function title.
    var displayedTitleMode: LayoutKeyTitleMode {
        if titleMode == nil, action.type == .space || action.asciiValue != nil { return .custom }
        return titleMode ?? .automatic
    }

    /// Editing a title switches a live key to the author's own title. Keys without a live face
    /// keep their existing title semantics.
    func editingLabel(_ text: String, allowsTitleMode: Bool) -> LayoutKey {
        let titled = title(text)
        return allowsTitleMode && supportsLiveTitle ? titled : titled.settingTitleMode(titleMode)
    }

    /// A character key carries no title class; switching to a function key restores the live
    /// title. Literal edits keep the face the key already had: pairing a legacy fixed key must
    /// not promote its author label into a live title.
    func editingAction(_ newAction: LayoutAction, allowsTitleMode: Bool) -> LayoutKey {
        let updated = settingAction(newAction)
        guard allowsTitleMode else { return updated }
        switch newAction.type {
        case .code:
            return updated.settingTitleMode(nil)
        case .literal:
            // A function key switched into literal starts as fixed text; editing an existing
            // literal (including adding or clearing its ASCII value) keeps its stored face.
            return updated.settingTitleMode(action.type == .literal ? titleMode : nil)
        default:
            return updated.settingTitleMode(titleMode ?? .automatic)
        }
    }
}
