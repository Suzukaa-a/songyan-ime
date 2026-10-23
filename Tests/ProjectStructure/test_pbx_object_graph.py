#!/usr/bin/env python3
"""Structural gates for the hand-maintained Xcode project graph."""

from __future__ import annotations

import collections
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PROJECT = ROOT / "Songyan.xcodeproj/project.pbxproj"
OBJECT_ID = r"[A-Za-z0-9]{24,}"
OBJECT_START = re.compile(rf"^\s*({OBJECT_ID})(?: /\*.*?\*/)? = \{{")


def project_objects(source: str) -> dict[str, str]:
    """Return top-level PBX object bodies while preserving nested dictionaries."""
    lines = source.splitlines()
    objects: dict[str, str] = {}
    index = 0
    while index < len(lines):
        match = OBJECT_START.match(lines[index])
        if match is None:
            index += 1
            continue
        identifier = match.group(1)
        body = [lines[index]]
        depth = lines[index].count("{") - lines[index].count("}")
        while depth > 0:
            index += 1
            body.append(lines[index])
            depth += lines[index].count("{") - lines[index].count("}")
        objects[identifier] = "\n".join(body)
        index += 1
    return objects


def value(body: str, key: str) -> str | None:
    match = re.search(rf"\b{re.escape(key)} = ([^;]+);", body)
    if match is None:
        return None
    raw = match.group(1).strip()
    reference = re.fullmatch(rf"({OBJECT_ID})(?: /\*.*?\*/)?", raw)
    if reference is not None:
        return reference.group(1)
    return raw.strip('"')


def list_references(body: str, key: str) -> list[str]:
    match = re.search(rf"\b{re.escape(key)} = \((.*?)\);", body, re.DOTALL)
    if match is None:
        return []
    return re.findall(rf"^\s*({OBJECT_ID})(?: /\*.*?\*/)?,$", match.group(1), re.MULTILINE)


class PBXObjectGraphTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = PROJECT.read_text(encoding="utf-8")
        cls.objects = project_objects(cls.source)

    def test_every_object_reference_resolves(self):
        keys = (
            "fileRef", "productRef", "productReference", "package", "target",
            "targetProxy", "buildConfigurationList", "baseConfigurationReference",
            "remoteGlobalIDString", "containerPortal", "rootObject",
        )
        keyed = re.findall(
            rf"\b(?:{'|'.join(keys)}) = ({OBJECT_ID})\b", self.source
        )
        listed = re.findall(
            rf"^\s*({OBJECT_ID})(?: /\*.*?\*/)?,$", self.source, re.MULTILINE
        )
        missing = sorted((set(keyed) | set(listed)) - self.objects.keys())
        self.assertEqual(missing, [], f"dangling PBX object references: {missing}")

    def test_local_package_reference_paths_exist(self):
        paths = []
        for body in self.objects.values():
            if "isa = XCLocalSwiftPackageReference;" not in body:
                continue
            relative_path = value(body, "relativePath")
            self.assertIsNotNone(relative_path)
            paths.append(relative_path)
            self.assertTrue((ROOT / relative_path).is_dir(), relative_path)
        self.assertGreater(len(paths), 0)

    def test_shared_keyboard_sources_are_in_both_targets_exactly_once(self):
        file_references = {
            identifier: value(body, "path")
            for identifier, body in self.objects.items()
            if "isa = PBXFileReference;" in body
        }
        build_files = {
            identifier: value(body, "fileRef")
            for identifier, body in self.objects.items()
            if "isa = PBXBuildFile;" in body and value(body, "fileRef") is not None
        }
        shared_groups = [
            body for body in self.objects.values()
            if "isa = PBXGroup;" in body and value(body, "path") == "SharedKeyboard"
        ]
        self.assertEqual(len(shared_groups), 1)
        shared_names = {
            file_references[identifier]
            for identifier in list_references(shared_groups[0], "children")
        }
        disk_names = {path.name for path in (ROOT / "Apps/SharedKeyboard").glob("*.swift")}
        self.assertEqual(shared_names, disk_names)

        target_sources: dict[str, collections.Counter[str]] = {}
        for body in self.objects.values():
            if "isa = PBXNativeTarget;" not in body:
                continue
            target_name = value(body, "name")
            source_phases = [
                self.objects[identifier]
                for identifier in list_references(body, "buildPhases")
                if "isa = PBXSourcesBuildPhase;" in self.objects[identifier]
            ]
            self.assertEqual(len(source_phases), 1, target_name)
            names = []
            for build_file in list_references(source_phases[0], "files"):
                file_reference = build_files.get(build_file)
                if file_reference is not None:
                    names.append(file_references[file_reference])
            target_sources[target_name] = collections.Counter(names)

        self.assertEqual(set(target_sources), {"HostApp", "KeyboardExtension"})
        for target_name, sources in target_sources.items():
            for shared_name in shared_names:
                self.assertEqual(sources[shared_name], 1, f"{target_name}: {shared_name}")
        extension_names = {path.name for path in (ROOT / "Apps/KeyboardExtension").glob("*.swift")}
        self.assertIn("KeyboardViewController.swift", extension_names)
        self.assertEqual(
            set(target_sources["KeyboardExtension"]),
            shared_names | extension_names,
        )
        for extension_name in extension_names:
            self.assertEqual(target_sources["KeyboardExtension"][extension_name], 1, extension_name)
            self.assertEqual(target_sources["HostApp"][extension_name], 0, extension_name)


if __name__ == "__main__":
    unittest.main()
