import Foundation

public enum KeyboardCompositionPreferences {
    public static let enabledKey = "keyboard.inlineCompositionEnabled"
    public static let defaultInlineEnabled = true
    public static var defaults: UserDefaults {
        let store = KeyboardRecipeStore.sharedDefaults() ?? .standard
        // Registration is volatile: replace the old registered false, but never overwrite
        // a persistent false chosen by the user. AppStorage and both adapters use this store.
        store.register(defaults: [enabledKey: defaultInlineEnabled])
        return store
    }
    public static var inlineEnabled: Bool {
        get { SharedPreferences.object(forKey: enabledKey, in: defaults) as? Bool ?? defaultInlineEnabled }
        set { SharedPreferences.set(newValue, forKey: enabledKey, in: defaults) }
    }
}
