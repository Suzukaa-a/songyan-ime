"""Key feedback levels: preference bounds and defaults, and the per-level click assets."""
import sys
import unittest

from swift_probe import ROOT, run_swift

SERVICE = ROOT / "Apps/SharedKeyboard/KeyboardFeedbackService.swift"


def levels_and_preferences_source():
    """The level enum and preferences store; the UIKit/CoreHaptics service stays out."""
    text = SERVICE.read_text()
    levels = text[text.index("public enum KeyboardFeedbackLevel"):
                  text.index("// MARK: - Key feedback preferences")]
    prefs = text[text.index("public enum KeyboardFeedbackPreferences"):
                 text.index("// MARK: - Key click audio")]
    # The shipped store reads the App Group suite, which a standalone probe lacks.
    store_line = "public static var defaults: UserDefaults { KeyboardRecipeStore.sharedDefaults() ?? .standard }"
    assert store_line in prefs, "preferences store anchor drifted"
    prefs = prefs.replace(store_line, "static var defaultsOverride: UserDefaults?\n"
                                     "    public static var defaults: UserDefaults { defaultsOverride ?? .standard }")
    paths = (ROOT / "Apps/SharedKeyboard/RimePaths.swift").read_text()
    overlay = "public enum SharedPreferences {" + paths.split("public enum SharedPreferences {", 1)[1].split("\n}\n", 1)[0]
    store = ("import os\nenum KeyboardRecipeStore {\n"
             "    nonisolated(unsafe) static var canWriteSharedContainer = true\n}\n")
    return levels + prefs + store + overlay + "\n}\n"


@unittest.skipUnless(sys.platform == "darwin", "requires the macOS Swift toolchain")
class KeyboardFeedbackLevelTests(unittest.TestCase):
    def test_levels_defaults_assets_and_key_path(self):
        production = levels_and_preferences_source()
        checks = (ROOT / "Tests/IOS/Fixtures/feedback-levels-main.swift").read_text()
        # macOS has no UIKit; the shim supplies the one UIKit type the extraction uses.
        shim = (ROOT / "Tests/IOS/Fixtures/feedback-levels-shim.swift").read_text()
        program = shim + "\nimport Foundation\n" + production + checks.replace("__ROOT__", str(ROOT))
        print(run_swift("", program, prefix="feedback-levels"), end="")


if __name__ == "__main__":
    unittest.main()
