"""Real draft factory copies and key-face edits preserve author data."""
import sys
import unittest

from swift_probe import ROOT, production_modules, run, scratch_directory

FACTORY = ROOT / "Apps/HostApp/KeyboardPageDraftFactory.swift"
EDITOR = ROOT / "Apps/HostApp/LayoutEditorView.swift"
FIXTURE = ROOT / "Tests/IOS/Fixtures/KeyboardPageDraftProbe.swift"


def swift_declaration(source, opener):
    """The declaration text of a Swift member, from its opening line to its matching brace."""
    start = source.index(opener)
    depth = 0
    for index in range(source.index("{", start), len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise AssertionError("unterminated declaration: " + opener[:60])


def generated_fixture(factory_source, editor_source):
    markers = {
        "/* PRODUCTION_COPY_FUNCTION */": (factory_source, "    static func copy("),
        "/* PRODUCTION_EDITABLE_DRAFT_FUNCTION */": (factory_source, "    static func editableDraft("),
        "/* PRODUCTION_SUPPORTS_LIVE_TITLE */": (editor_source, "    private var supportsLiveTitle"),
        "/* PRODUCTION_DISPLAYED_TITLE_MODE */": (editor_source, "    private var displayedTitleMode"),
        "/* PRODUCTION_UPDATING_ACTION */": (editor_source, "    private func updatingAction("),
        "/* PRODUCTION_UPDATING_LABEL */": (editor_source, "    private func updatingLabel("),
    }
    generated = FIXTURE.read_text(encoding="utf-8")
    for marker, (source, opener) in markers.items():
        if generated.count(marker) != 1:
            raise AssertionError("fixture must carry exactly one " + marker)
        declaration = swift_declaration(source, opener)
        if opener.startswith("    private "):
            declaration = declaration.replace("    private ", "    ", 1)
        generated = generated.replace(marker, declaration)
    return generated


@unittest.skipUnless(sys.platform == "darwin", "requires macOS Swift")
class KeyboardPageDraftTests(unittest.TestCase):
    def test_real_copy_keeps_author_rows_split_and_face(self):
        with scratch_directory("keyboard-page-drafts") as directory:
            modules = production_modules()
            fixture = directory / "KeyboardPageDraftProbe.swift"
            fixture.write_text(
                generated_fixture(
                    FACTORY.read_text(encoding="utf-8"), EDITOR.read_text(encoding="utf-8")),
                encoding="utf-8")
            binary = directory / "probe"
            run([
                "xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
                "-I", str(modules), "-L", str(modules),
                "-module-cache-path", str(directory / "module-cache"),
                "-lKeyboardCore", "-lLayoutKit",
                "-Xlinker", "-rpath", "-Xlinker", str(modules),
                str(fixture), "-o", str(binary),
            ])
            print(run([str(binary)]), end="")


if __name__ == "__main__":
    unittest.main()
