#!/usr/bin/env python3
"""Static attribution checks for components distributed in the HostApp."""

import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LEGAL = ROOT / "Resources/Legal"
ENGINE = ROOT / "Resources/EngineResources"
NOTICE = (LEGAL / "ThirdPartyNotices.txt").read_text(encoding="utf-8")
VIEW = (ROOT / "Apps/HostApp/EngineStatusView.swift").read_text(encoding="utf-8")


class ThirdPartyNoticesContractTests(unittest.TestCase):
    def test_engine_capabilities_are_attributed(self):
        capabilities = json.loads((ENGINE / "engine-capabilities.json").read_text(encoding="utf-8"))
        for name in ("librime", "librime-lua", "lua", "opencc", "marisa", "librime-octagram"):
            with self.subTest(component=name):
                self.assertIn(name, capabilities)
                self.assertIn(name, NOTICE.lower())
        for path in (
            ENGINE / "licenses/librime-lua-ad1e4a6-LICENSE.txt",
            ENGINE / "licenses/Lua-5.4.9-LICENSE.txt",
            ENGINE / "licenses/librime-octagram-LICENSE",
        ):
            self.assertTrue(path.is_file(), path)
            self.assertIn(path.name, NOTICE)
            self.assertIn(path.name, VIEW)

    def test_resolved_package_dependencies_have_bundled_mit_terms(self):
        resolved = json.loads((ROOT / "Packages/PackageManager/Package.resolved").read_text(encoding="utf-8"))
        names = {pin["identity"]: pin["state"]["version"] for pin in resolved["pins"]}
        self.assertEqual(names, {"yams": "5.4.0", "zipfoundation": "0.9.20"})
        for name, version in (("Yams", "5.4.0"), ("ZIPFoundation", "0.9.20")):
            path = LEGAL / "licenses" / f"{name}-{version}-LICENSE.txt"
            with self.subTest(component=name):
                self.assertIn(name, NOTICE)
                self.assertIn(path.name, NOTICE)
                self.assertIn("Permission is hereby granted", path.read_text(encoding="utf-8"))
                self.assertIn(path.name, VIEW)

    def test_opencc_notice_matches_bundled_data(self):
        data = ENGINE / "opencc"
        self.assertEqual(len(list(data.glob("*.ocd2"))), 16)
        self.assertEqual(len(list(data.glob("*.json"))), 14)
        self.assertIn("16 compiled .ocd2 dictionaries and 14 JSON configs", NOTICE)
        self.assertNotIn("NOT shipped with the app", NOTICE)
        self.assertNotIn("not currently shipped", NOTICE)
        project = (ROOT / "Songyan.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
        self.assertIn("EngineResources in Resources", project)
        self.assertTrue((LEGAL / "licenses/opencc-1.1.9-LICENSE.txt").is_file())

    def test_adapted_schemas_have_offline_terms_and_change_notices(self):
        # The root LICENSE is a copyright header followed by the verbatim GPL text.
        gpl = (LEGAL / "licenses/GPL-3.0.txt").read_bytes()
        root_license = (ROOT / "LICENSE").read_bytes()
        self.assertTrue(root_license.endswith(gpl))
        self.assertIn(b"Copyright (C) 2026", root_license[: len(root_license) - len(gpl)])
        self.assertIn(b"GNU GENERAL PUBLIC LICENSE", gpl)
        self.assertIn("GNU LESSER GENERAL PUBLIC LICENSE",
                      (LEGAL / "licenses/LGPL-3.0.txt").read_text(encoding="utf-8"))
        package = ROOT / "Resources/BuiltinPackages/Basic"
        source = (package / "songyan_flypy.schema.yaml").read_text(encoding="utf-8")
        self.assertIn("rime-clover-flypy", source)
        self.assertIn("LGPL-3.0", source)
        self.assertIn("Modified by this project:", source)
        # Generated companions carry the adapted rules, so each points back to the notice.
        for companion in sorted(package.glob("keyboard_*.schema.yaml")):
            with self.subTest(schema=companion.name):
                header = companion.read_text(encoding="utf-8")[:400]
                self.assertIn("Rule sources and licenses: see songyan_", header)
        for license_name in ("GPL-3.0.txt", "LGPL-3.0.txt"):
            self.assertIn(license_name, NOTICE)
            self.assertIn(license_name, VIEW)
        self.assertNotIn("docs/licenses/", NOTICE)

    def test_vendored_engine_and_package_code_is_attributed(self):
        # Code vendored inside upstream sources (OpenCC deps, librime include/, Yams' CYaml).
        for name, license_file, marker in (
            ("RapidJSON 1.1.0", "rapidjson-1.1.0-LICENSE.txt", "THL A29 Limited"),
            ("LibYAML", "libyaml-LICENSE.txt", "Kirill Simonov"),
            ("X11 keysym", "X11-keysym-NOTICE.txt", "The Open Group"),
            ("UTF8-CPP", "boost-1.89.0-LICENSE_1_0.txt", "Boost Software License"),
        ):
            with self.subTest(component=name):
                self.assertIn(name, NOTICE)
                self.assertIn(marker, (LEGAL / "licenses" / license_file).read_text(encoding="utf-8"))
                self.assertIn(license_file, NOTICE)
                self.assertIn(license_file, VIEW)

    def test_librime_lua_mit_files_are_attributed(self):
        notices = ENGINE / "licenses/librime-lua-ad1e4a6-MIT-NOTICES.txt"
        text = notices.read_text(encoding="utf-8")
        for line in (
            "Copyright (C) 2022 Shewer Lu <shewer@gmail.com>",
            "Copyright (C) 2023 Shewer Lu <shewer@gmail.com>",
            "Copyright (c) 2015 Kepler Project.",
            "Copyright (C) 1994-2018 Lua.org, PUC-Rio.",
        ):
            with self.subTest(line=line):
                self.assertIn(line, text)
        self.assertIn("Permission is hereby granted", text)
        self.assertIn("Shewer Lu", NOTICE)
        self.assertIn(notices.name, NOTICE)
        self.assertIn(notices.name, VIEW)
        self.assertIn("Junekey Jeon", NOTICE)

    def test_bundled_rime_prelude_is_attributed(self):
        prelude = ROOT / "Packages/PackageManager/Sources/PackageManager/Resources/RimePrelude"
        pin = re.search(r"^Pin: ([0-9a-f]{40})", (prelude / "PROVENANCE.md").read_text(encoding="utf-8"), re.M)
        self.assertIsNotNone(pin)
        self.assertIn(pin.group(1), NOTICE)
        self.assertIn("GNU LESSER GENERAL PUBLIC LICENSE", (prelude / "LICENSE").read_text(encoding="utf-8"))
        self.assertIn("PackageManager_PackageManager.bundle/RimePrelude/LICENSE", NOTICE)
        self.assertIn("PackageManager_PackageManager.bundle/RimePrelude/LICENSE", VIEW)

    def test_in_app_offline_license_links_resolve(self):
        resources = re.findall(r'resource: "((?:Legal|EngineResources)/licenses/[^\"]+)"', VIEW)
        self.assertGreaterEqual(len(resources), 7)
        for resource in resources:
            with self.subTest(resource=resource):
                self.assertTrue((ROOT / "Resources" / resource).is_file(), resource)


if __name__ == "__main__":
    unittest.main()
