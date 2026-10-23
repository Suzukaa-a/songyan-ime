#!/usr/bin/env python3
"""Keep bundle, App Group and deployment identities in one place."""

import plistlib
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
XCCONFIG = ROOT / "Config/Identity.xcconfig"
GROUP_VARIABLE = "$(SONGYAN_APP_GROUP)"


def identity_settings():
    text = XCCONFIG.read_text(encoding="utf-8")
    return dict(re.findall(r"^([A-Z_][A-Z0-9_]*) = (.*)$", text, re.MULTILINE))


class ProjectIdentityConsistencyTests(unittest.TestCase):
    def test_both_configurations_derive_identity_from_the_xcconfig(self):
        project = (ROOT / "Songyan.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
        self.assertEqual(project.count("baseConfigurationReference = A0000000000000000000000072"), 2)
        bundle_ids = re.findall(r"PRODUCT_BUNDLE_IDENTIFIER = ([^;]+);", project)
        self.assertEqual(sorted(bundle_ids), sorted(['"$(SONGYAN_BUNDLE_ID)"'] * 2
                                                    + ['"$(SONGYAN_BUNDLE_ID).keyboard"'] * 2))
        self.assertNotIn("DEVELOPMENT_TEAM", project)
        self.assertEqual(set(re.findall(r"IPHONEOS_DEPLOYMENT_TARGET = ([^;]+);", project)), {"17.0"})
        self.assertEqual(set(re.findall(r"MARKETING_VERSION = ([^;]+);", project)), {"0.1.0"})
        self.assertEqual(set(re.findall(r"CURRENT_PROJECT_VERSION = ([^;]+);", project)), {"1"})
        self.assertEqual(re.findall(r"APPLICATION_EXTENSION_API_ONLY = ([^;]+);", project), ["YES", "YES"])

    def test_app_group_flows_from_xcconfig_to_entitlements_plists_and_runtime(self):
        settings = identity_settings()
        self.assertEqual(settings["SONGYAN_BUNDLE_ID"], "app.songyan.ime")
        self.assertEqual(settings["SONGYAN_APP_GROUP"], "group.app.songyan.shared")
        for target in ("HostApp", "KeyboardExtension"):
            with (ROOT / f"Apps/{target}/{target}.entitlements").open("rb") as handle:
                entitlements = plistlib.load(handle)
            self.assertEqual(entitlements["com.apple.security.application-groups"], [GROUP_VARIABLE])
            with (ROOT / f"Apps/{target}/Info.plist").open("rb") as handle:
                self.assertEqual(plistlib.load(handle)["SongyanAppGroup"], GROUP_VARIABLE)

        runtime = (ROOT / "Apps/SharedKeyboard/RimePaths.swift").read_text(encoding="utf-8")
        self.assertIn(f'defaultGroupID = "{settings["SONGYAN_APP_GROUP"]}"', runtime)


if __name__ == "__main__":
    unittest.main()
