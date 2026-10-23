#!/usr/bin/env python3
"""Static project-structure test: privacy manifest target membership.

This is a *structural* check of `Songyan.xcodeproj/project.pbxproj`, not a
source grep. It parses the project graph via `plutil` and asserts, for each
shipping bundle, that the correct `PrivacyInfo.xcprivacy` is a member of that
target's Resources build phase and resolves to the expected on-disk file:

    HostApp          (com.apple.product-type.application) -> Apps/HostApp/PrivacyInfo.xcprivacy
    KeyboardExtension(com.apple.product-type.app-extension) -> Apps/KeyboardExtension/PrivacyInfo.xcprivacy

It also validates each manifest's content against Apple's published
required-reason API categories and reason codes:
https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api

Run: python3 Tests/ProjectStructure/test_privacy_manifest_target_membership.py
Exit code 0 on success, 1 on any failure. No Xcode/simulator required.
"""
from __future__ import annotations

import json
import plistlib
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PBXPROJ = ROOT / "Songyan.xcodeproj" / "project.pbxproj"

# Apple's published reason codes per required-reason API category. Only these
# values may appear for the category they belong to.
APPLE_REASONS: dict[str, set[str]] = {
    "NSPrivacyAccessedAPICategoryFileTimestamp": {"DDA9.1", "C617.1", "3B52.1", "0A2A.1"},
    "NSPrivacyAccessedAPICategorySystemBootTime": {"35F9.1", "8FFB.1", "3D61.1"},
    "NSPrivacyAccessedAPICategoryDiskSpace": {"85F4.1", "E174.1", "7D9E.1", "B728.1"},
    "NSPrivacyAccessedAPICategoryUserDefaults": {"CA92.1", "1C8F.1", "C56D.1", "AC6B.1"},
    "NSPrivacyAccessedAPICategoryActiveKeyboards": {"3EC4.1", "54BD.1"},
}
APPLE_CATEGORIES = set(APPLE_REASONS)

# What this project must declare, and the exact reason codes used by its code.
COMMON_REASONS = {
    "NSPrivacyAccessedAPICategoryUserDefaults": {"CA92.1", "1C8F.1"},
    "NSPrivacyAccessedAPICategorySystemBootTime": {"35F9.1"},
    "NSPrivacyAccessedAPICategoryFileTimestamp": {"C617.1"},
}
EXPECTED = {
    "HostApp": {
        **COMMON_REASONS,
        # Only the Host reads metadata from security-scoped document picker URLs.
        "NSPrivacyAccessedAPICategoryFileTimestamp": {"C617.1", "3B52.1"},
    },
    "KeyboardExtension": COMMON_REASONS,
}

TARGETS = {
    # target name -> (productType, manifest path relative to repo root)
    "HostApp": ("com.apple.product-type.application", "Apps/HostApp/PrivacyInfo.xcprivacy"),
    "KeyboardExtension": ("com.apple.product-type.app-extension",
                          "Apps/KeyboardExtension/PrivacyInfo.xcprivacy"),
}


def load_project() -> dict:
    raw = subprocess.check_output(
        ["plutil", "-convert", "json", "-o", "-", str(PBXPROJ)], text=True)
    return json.loads(raw)


class ProjectGraph:
    def __init__(self, project: dict) -> None:
        self.objects = project["objects"]
        self.parent: dict[str, str] = {}
        for oid, obj in self.objects.items():
            for key in ("children", "files"):
                for child in obj.get(key, []) or []:
                    self.parent[child] = oid

    def by_isa(self, isa: str):
        return {oid: obj for oid, obj in self.objects.items() if obj.get("isa") == isa}

    def target_named(self, name: str):
        for oid, obj in self.by_isa("PBXNativeTarget").items():
            if obj.get("name") == name:
                return oid, obj
        return None, None

    def resources_phase_manifest_refs(self, target: dict) -> list[tuple[str, str]]:
        """(fileRefID, resolved repo-relative path) for every resource build file."""
        result: list[tuple[str, str]] = []
        for phase_id in target.get("buildPhases", []):
            phase = self.objects.get(phase_id, {})
            if phase.get("isa") != "PBXResourcesBuildPhase":
                continue
            for build_file_id in phase.get("files", []):
                build_file = self.objects.get(build_file_id, {})
                file_ref_id = build_file.get("fileRef")
                if not file_ref_id:
                    continue
                result.append((file_ref_id, self.resolve_path(file_ref_id)))
        return result

    def resolve_path(self, file_ref_id: str) -> str:
        ref = self.objects.get(file_ref_id, {})
        parts = [ref.get("path", "")]
        current = self.parent.get(file_ref_id)
        while current:
            node = self.objects.get(current, {})
            if node.get("isa") == "PBXGroup" and node.get("path"):
                parts.append(node["path"])
            current = self.parent.get(current)
        return "/".join(reversed([p for p in parts if p]))


class PrivacyManifestMembershipTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.graph = ProjectGraph(load_project())

    def test_manifest_files_exist(self) -> None:
        for name, (_, rel) in TARGETS.items():
            with self.subTest(target=name):
                self.assertTrue((ROOT / rel).is_file(), f"missing manifest for {name}: {rel}")

    def test_each_target_resources_contain_its_manifest(self) -> None:
        for name, (product_type, rel) in TARGETS.items():
            with self.subTest(target=name):
                _, target = self.graph.target_named(name)
                self.assertIsNotNone(target, f"target {name} not found")
                self.assertEqual(target.get("productType"), product_type)
                refs = self.graph.resources_phase_manifest_refs(target)
                paths = {path for _, path in refs if path.endswith("PrivacyInfo.xcprivacy")}
                self.assertIn(rel, paths,
                              f"{name} Resources must include {rel}; got {sorted(paths)}")

    def test_manifests_are_not_cross_wired(self) -> None:
        # The Host manifest must not land in the appex bundle and vice versa.
        for name, (_, rel) in TARGETS.items():
            other = next(r for n, (_, r) in TARGETS.items() if n != name)
            with self.subTest(target=name):
                _, target = self.graph.target_named(name)
                paths = {p for _, p in self.graph.resources_phase_manifest_refs(target)
                         if p.endswith("PrivacyInfo.xcprivacy")}
                self.assertNotIn(other, paths)

    def test_manifest_reference_type_is_resource(self) -> None:
        for name, (_, rel) in TARGETS.items():
            with self.subTest(target=name):
                _, target = self.graph.target_named(name)
                ref_ids = [ref for ref, path in self.graph.resources_phase_manifest_refs(target)
                           if path == rel]
                self.assertEqual(len(ref_ids), 1)
                ref = self.graph.objects[ref_ids[0]]
                self.assertTrue(ref.get("lastKnownFileType", "").startswith("text"),
                                f"manifest {rel} must be a recognised text resource")

    def test_manifest_contents_match_apple_reason_codes(self) -> None:
        for name, (_, rel) in TARGETS.items():
            with self.subTest(target=name):
                with open(ROOT / rel, "rb") as handle:
                    manifest = plistlib.load(handle)
                self.assertIs(manifest.get("NSPrivacyTracking"), False)
                self.assertIn("NSPrivacyCollectedDataTypes", manifest)
                self.assertEqual(manifest.get("NSPrivacyCollectedDataTypes"), [])
                self.assertEqual(set(manifest).issubset(
                    {"NSPrivacyTracking", "NSPrivacyTrackingDomains",
                     "NSPrivacyCollectedDataTypes", "NSPrivacyAccessedAPITypes"}), True,
                    "manifest must use only official top-level keys")

                entries = manifest.get("NSPrivacyAccessedAPITypes")
                self.assertIsInstance(entries, list)
                declared: dict[str, list[str]] = {}
                for entry in entries:
                    self.assertEqual(set(entry), {"NSPrivacyAccessedAPIType",
                                                  "NSPrivacyAccessedAPITypeReasons"})
                    category = entry["NSPrivacyAccessedAPIType"]
                    self.assertIn(category, APPLE_CATEGORIES, f"unknown category {category}")
                    reasons = entry["NSPrivacyAccessedAPITypeReasons"]
                    self.assertTrue(reasons)
                    for reason in reasons:
                        self.assertIn(reason, APPLE_REASONS[category],
                                      f"{reason} is not a valid code for {category}")
                    declared[category] = set(reasons)

                self.assertEqual(declared, {k: set(v) for k, v in EXPECTED[name].items()},
                                 f"{rel} declared reasons differ from the audited expectations")


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False).result.wasSuccessful() else 1)
