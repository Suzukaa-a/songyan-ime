#!/usr/bin/env python3
"""Static gate for the shipping keyboard-extension declarations."""

import plistlib
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class KeyboardExtensionContractTests(unittest.TestCase):
    def test_keyboard_extension_declares_real_capabilities(self):
        with (ROOT / "Apps/KeyboardExtension/Info.plist").open("rb") as handle:
            info = plistlib.load(handle)
        extension = info["NSExtension"]
        attributes = extension["NSExtensionAttributes"]
        self.assertEqual(extension["NSExtensionPointIdentifier"], "com.apple.keyboard-service")
        self.assertEqual(extension["NSExtensionPrincipalClass"], "$(PRODUCT_MODULE_NAME).KeyboardViewController")
        self.assertIs(attributes["IsASCIICapable"], True)
        self.assertIs(attributes["RequestsOpenAccess"], True)


if __name__ == "__main__":
    unittest.main()
