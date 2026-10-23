#!/usr/bin/env python3
"""The vendored RimeKit slices match the manifest and export the engine entry points."""

import hashlib
import json
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = ROOT / "Packages/RimeBridge"
MANIFEST = PACKAGE / "RimeKitArtifact.json"
REQUIRED_SYMBOLS = ("_rb_require_lua", "_rb_require_grammar", "_rb_require_t9", "_rb_require_predict",
                    "_rb_predict_components_registered", "_rb_component_available")


class RimeKitArtifactContractTests(unittest.TestCase):
    def setUp(self):
        self.manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
        self.artifact = PACKAGE / self.manifest["artifactPath"]

    def test_manifest_lists_both_slices(self):
        self.assertEqual(self.manifest["formatVersion"], 1)
        self.assertEqual(self.manifest["module"], "RimeKit")
        self.assertEqual(self.manifest["artifactPath"], "Vendored/RimeKit.xcframework")
        self.assertEqual(set(self.manifest["slices"]), {"ios-arm64", "ios-arm64-simulator"})

    def test_slice_archives_match_manifest_and_export_entry_points(self):
        for name, descriptor in self.manifest["slices"].items():
            with self.subTest(slice=name):
                archive = self.artifact / descriptor["archive"]
                self.assertTrue(archive.is_file(), archive)
                self.assertEqual(hashlib.sha256(archive.read_bytes()).hexdigest(), descriptor["sha256"])
                symbols = subprocess.check_output(["nm", "-g", str(archive)], text=True)
                for symbol in REQUIRED_SYMBOLS:
                    self.assertIn(symbol, symbols)

    def test_no_prediction_database_is_bundled(self):
        bundled = [p for p in ROOT.joinpath("Resources").rglob("*") if p.name.endswith("predict.db")]
        self.assertEqual(bundled, [], "no predict.db of unverified license may be bundled")


if __name__ == "__main__":
    unittest.main()
