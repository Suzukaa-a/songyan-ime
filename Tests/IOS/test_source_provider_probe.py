"""Production-coverage probe for SourcePublishedKeyboardProvider.snapshot and
DictionaryImportCenter.addableKeyboards(packageID:): compiles the REAL
production function bodies against mocked storage seams (fixture activation
record + synchronous read queue). Run via swift_probe like the installation
fixture; assertions live in the Swift probe main.
"""
import sys
import unittest

from swift_probe import ROOT, compile_swift, run, scratch_directory, section


def extract(path: str, start: str, end: str | None = None) -> str:
    text = (ROOT / path).read_text()
    return section(text, start, end)


@unittest.skipUnless(sys.platform == "darwin", "requires macOS Swift")
class SourceProviderProbeTests(unittest.TestCase):
    def test_real_snapshot_and_addable_bodies(self):
        adapter = (ROOT / "Apps/HostApp/DictionaryImportCenterUserKeyboards.swift").read_text()
        # The provider struct runs from its declaration to end-of-file; it
        # contains snapshot/publishedKeyboards/rosterKey/matches verbatim.
        provider_body = adapter[adapter.index("struct SourcePublishedKeyboardProvider"):]
        # Production snapshot + flat read + rosterKey + matches, verbatim.
        fixture = (ROOT / "Tests/IOS/Fixtures/SourceProviderProbe.swift").read_text()
        # The production provider struct (snapshot/publishedKeyboards/rosterKey/
        # matches) replaces the fixture placeholder wholesale.
        source = fixture.replace("// PRODUCTION_PROVIDER_STRUCT", provider_body)
        provider = (ROOT / "Apps/SharedKeyboard/PublishedKeyboardProvider.swift").read_text()
        # Both keyboards helpers verbatim: from the first helper's doc comment to the type's closing brace.
        helper = provider[provider.index("    /// The only source of truth"):provider.rindex("}")]
        source = source.replace("// PRODUCTION_KEYBOARDS_HELPER", helper)
        with scratch_directory("source-provider-probe") as directory:
            generated = directory / "SourceProviderProbe.swift"
            generated.write_text(source)
            binary = compile_swift(directory, [generated], library=True,
                                   dependencies=("KeyboardCore",))
            print(run([str(binary)]), end="")


if __name__ == "__main__":
    unittest.main()
