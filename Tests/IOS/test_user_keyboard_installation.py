"""Actual host model and installation-status evaluator; storage is a fixture seam."""
import sys
import unittest

from swift_probe import ROOT, compile_swift, run, scratch_directory, section


@unittest.skipUnless(sys.platform == "darwin", "requires macOS Swift/Combine")
class UserKeyboardInstallationTests(unittest.TestCase):
    def test_updated_installation_can_save_unchanged_roster(self):
        adapter = (ROOT / "Apps/HostApp/DictionaryImportCenterUserKeyboards.swift").read_text()
        evaluator = section(adapter, "    func isCurrentInstallation(", "    private func currentContext(")
        center = (ROOT / "Apps/HostApp/UserKeyboardCenter.swift").read_text()
        view = (ROOT / "Apps/HostApp/UserKeyboardManagementView.swift").read_text()
        can_save = section(view, "    private var canSave: Bool {", "    private func displayName(")
        draft_changes = section(view, "    private var hasChanges: Bool", "    /// Keyboards turned on")
        fixture = (ROOT / "Tests/IOS/Fixtures/UserKeyboardInstallation.swift").read_text()
        source = fixture.replace("// PRODUCTION_EVALUATOR", evaluator)
        source = source.replace("// PRODUCTION_CENTER", center)
        source = source.replace("// PRODUCTION_DRAFT_CHANGES", draft_changes.replace("private var hasChanges", "var hasChanges"))
        source = source.replace("// PRODUCTION_SAVE_ELIGIBILITY", can_save.replace("private var canSave", "var canSave"))
        with scratch_directory("user-keyboard-installation") as directory:
            generated = directory / "InstallationProbe.swift"
            generated.write_text(source)
            binary = compile_swift(directory, [generated], library=True, dependencies=("KeyboardCore",))
            print(run([str(binary)]), end="")


if __name__ == "__main__":
    unittest.main()
