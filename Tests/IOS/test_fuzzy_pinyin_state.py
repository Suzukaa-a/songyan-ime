"""Fuzzy pinyin settings state: a failed save must never leak its draft across targets.

Compiles the production refresh/save preamble, PublishedContext and State out of
FuzzyPinyinCenter and drives them with a scripted published read.
"""
import sys
import unittest

from swift_probe import ROOT, run_swift, section

CENTER = ROOT / "Apps/HostApp/FuzzyPinyinCenter.swift"
FIXTURE = ROOT / "Tests/IOS/Fixtures/FuzzyPinyinState.swift"

SLICES = {
    "/* PRODUCTION_PREFS */": (
        "    static func preferred(packageID: String?, schemaID: String) -> Set<String> {",
        "\n    enum State: Equatable, Sendable {"),
    "/* PRODUCTION_STATE */": (
        "    enum State: Equatable, Sendable {",
        "\n    /// What the keyboard currently uses"),
    "/* PRODUCTION_CONTEXT */": (
        "    struct PublishedContext: Equatable, Sendable {",
        "\n    private(set) var applyTask"),
    "/* PRODUCTION_REFRESH */": (
        "    func refresh() async {",
        "\n    /// Reads the published compiled schema"),
    "/* PRODUCTION_SAVE_PREAMBLE */": (
        "    func save() {",
        "\n        let ids = FuzzyPinyin.allPairs.filter"),
}


def generated_program():
    program = FIXTURE.read_text(encoding="utf-8")
    center = CENTER.read_text(encoding="utf-8")
    for marker, (start, end) in SLICES.items():
        program = program.replace(marker, section(center, start, end))
    return program


@unittest.skipUnless(sys.platform == "darwin", "requires macOS Swift")
class FuzzyPinyinStateTests(unittest.TestCase):
    def test_failed_draft_never_leaks_across_targets(self):
        print(run_swift("", generated_program(), prefix="fuzzy-pinyin-state"), end="")


if __name__ == "__main__":
    unittest.main()
