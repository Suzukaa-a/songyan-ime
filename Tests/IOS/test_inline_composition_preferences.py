"""Exercise the production Foundation preference API without installing either iOS app."""
import sys
import unittest

from swift_probe import ROOT, run_swift


@unittest.skipUnless(sys.platform == "darwin", "requires the macOS Swift toolchain")
class InlineCompositionPreferencesTests(unittest.TestCase):
    def test_registered_default_preserves_explicit_choice(self):
        source = (ROOT / "Apps/SharedKeyboard/KeyboardCompositionPreferences.swift").read_text()
        preference = source.split("public enum KeyboardCompositionPreferences {", 1)[1]
        preference = "public enum KeyboardCompositionPreferences {" + preference.split("\n}\n", 1)[0] + "\n}"
        paths = (ROOT / "Apps/SharedKeyboard/RimePaths.swift").read_text()
        overlay = paths.split("public enum SharedPreferences {", 1)[1]
        overlay = "public enum SharedPreferences {" + overlay.split("\n}\n", 1)[0] + "\n}"
        program = r'''
import Foundation
import os
enum KeyboardRecipeStore {
    static let groupID = "app.songyan.preference-test." + UUID().uuidString
    static func sharedDefaults() -> UserDefaults? { UserDefaults(suiteName: groupID) }
    nonisolated(unsafe) static var canWriteSharedContainer = true
}
''' + overlay + "\n" + preference + r'''
let key = KeyboardCompositionPreferences.enabledKey
let domain = KeyboardRecipeStore.groupID
let store = UserDefaults(suiteName: domain)!
defer { store.removePersistentDomain(forName: domain) }
store.register(defaults: [key: false])
precondition(!store.bool(forKey: key))
precondition(KeyboardCompositionPreferences.inlineEnabled)
precondition(KeyboardCompositionPreferences.defaults.bool(forKey: key))
precondition(store.persistentDomain(forName: domain)?[key] == nil)
KeyboardCompositionPreferences.inlineEnabled = false
precondition(!KeyboardCompositionPreferences.inlineEnabled)
precondition(!KeyboardCompositionPreferences.defaults.bool(forKey: key))
precondition(UserDefaults(suiteName: domain)!.object(forKey: key) as? Bool == false)
KeyboardCompositionPreferences.inlineEnabled = true
precondition(KeyboardCompositionPreferences.inlineEnabled)
// AppStorage/direct-store writes and the common setter must share one persistent key.
KeyboardCompositionPreferences.defaults.set(false, forKey: key)
precondition(!KeyboardCompositionPreferences.inlineEnabled)
// Read-only (a keyboard without Full Access): the choice holds for this process only.
KeyboardCompositionPreferences.inlineEnabled = true
KeyboardRecipeStore.canWriteSharedContainer = false
KeyboardCompositionPreferences.inlineEnabled = false
precondition(!KeyboardCompositionPreferences.inlineEnabled)
precondition(UserDefaults(suiteName: domain)!.object(forKey: key) as? Bool == true)
print("default/registered-false/explicit-false/shared-reader checks passed")
'''
        print(run_swift("", program, prefix="composition-preferences"), end="")


if __name__ == "__main__":
    unittest.main()
