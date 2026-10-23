"""Strict idle paste policy, production controller wiring, and ABA lease races."""
import sys
import unittest

from swift_probe import ROOT, controller_sources, production_modules, run, scratch_directory, section, type_source_text

PASTE = ROOT / "Apps/SharedKeyboard/QuickPasteView.swift"
SHARED = ROOT / "Apps/SharedKeyboard"
MEMO = SHARED / "KeyboardPanelView+LayoutDefinitions.swift"
FIXTURE = ROOT / "Tests/IOS/Fixtures/IdlePastePolicy.swift"


def closure_body(source, opener):
    """The body of the closure `opener`, cut at its matching closing brace."""
    start = source.index(opener)
    depth = 0
    for index in range(source.index("{", start), len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start + len(opener):index]
    raise AssertionError("unterminated closure: " + opener[:40])


def panel_fragments(source, memo):
    return {
        # The memo closes its file.
        "/* PRODUCTION_DEFINITION_MEMO */": memo[memo.index("final class DefinitionResolutionMemo {"):],
        "/* PRODUCTION_DEFINITION_CHROME */": section(source, "    var usesConfiguredLayout:",
                                                      "    /// Exact match of a bundled merged letter layout"),
        "/* PRODUCTION_IDLE_GETTER */": section(source, "    private var quickPasteIdleInput:",
                                                "    private var panelBody:"),
        "/* PRODUCTION_SYMBOL_ERROR_GETTER */": section(source, "    var t9QuickSymbolsError:",
                                                        "    // MARK: Key feedback"),
        "/* PRODUCTION_RENDER_OBSERVATION */": section(source, "        quickPasteSlot.observe(",
                                                       "        return VStack(spacing: 0)"),
        "/* PRODUCTION_INPUT_CONTEXT */": closure_body(source, "inputContext: {"),
        "/* PRODUCTION_INSERT_OUTLET */": closure_body(source, "insertLiteral: { [weak controller] text in"),
        "/* PRODUCTION_ERROR_RESULT */": closure_body(source, "onError: { error in"),
    }


@unittest.skipUnless(sys.platform == "darwin", "requires macOS Swift")
class IdlePasteProductionTests(unittest.TestCase):
    def test_complete_production_policy_lease_controller_and_symbol_model(self):
        with scratch_directory("idle-paste-policy") as directory:
            modules = production_modules()
            existing = (ROOT / "Tests/IOS/Fixtures/ControllerInputRegressions.swift").read_text(encoding="utf-8")
            platform = directory / "PlatformSeam.swift"
            platform.write_text(existing.split("@main struct ControllerInputChecks", 1)[0], encoding="utf-8")
            controller = controller_sources(directory)
            queue = directory / "EngineOpQueue.swift"
            queue.write_text((ROOT / "Apps/SharedKeyboard/EngineOpQueue.swift").read_text(encoding="utf-8"), encoding="utf-8")
            generated = FIXTURE.read_text(encoding="utf-8")
            fragments = panel_fragments(type_source_text(SHARED, "KeyboardPanelView"), MEMO.read_text(encoding="utf-8"))
            for marker, fragment in fragments.items():
                self.assertEqual(generated.count(marker), 1, marker)
                generated = generated.replace(marker, fragment)
            fixture = directory / "IdlePastePolicy.swift"
            fixture.write_text(generated, encoding="utf-8")
            binary = directory / "probe"
            run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
                 "-I", str(modules), "-L", str(modules),
                 "-module-cache-path", str(directory / "module-cache"),
                 "-lKeyboardCore", "-lLayoutKit", "-lCandidateKit",
                 "-Xlinker", "-rpath", "-Xlinker", str(modules),
                 str(PASTE), str(ROOT / "Apps/SharedKeyboard/T9QuickSymbolModel.swift"),
                 *map(str, controller), str(queue), str(platform), str(fixture), "-o", str(binary)])
            runtime = directory / "runtime"
            runtime.mkdir()
            print(run([str(binary), str(runtime)]), end="")


if __name__ == "__main__":
    unittest.main()
