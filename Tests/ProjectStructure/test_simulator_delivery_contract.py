#!/usr/bin/env python3
"""Static safety contract for simulator delivery operations."""

import importlib.util
import json
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Tools/BuildRimeIOS/scripts/deliver-simulator.py"


class SimulatorDeliveryContractTests(unittest.TestCase):
    def test_install_requires_a_named_isolated_device_before_boot_or_install(self):
        spec = importlib.util.spec_from_file_location("simulator_delivery_guard", SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        for device in ({}, {"name": "Dev Simulator"}, {"name": "Other-Device-Isolated-old"}):
            with self.subTest(device=device), self.assertRaisesRegex(RuntimeError, "-Isolated"):
                module.require_isolated_device(device)
        module.require_isolated_device({"name": "Other-Device-Isolated"})

    def test_nonisolated_target_never_reaches_simctl_mutations(self):
        spec = importlib.util.spec_from_file_location("simulator_delivery_install_guard", SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        device = {"udid": "primary", "name": "Dev Simulator", "state": "Shutdown"}
        devices = json.dumps({"devices": {"iOS": [device]}}).encode()
        with tempfile.TemporaryDirectory() as temporary:
            evidence = Path(temporary)
            with patch.object(module, "verify", return_value=({"HostApp": {"bundleID": "test.host"}}, {})), \
                 patch.object(module, "run", return_value=devices) as simctl:
                with self.assertRaisesRegex(RuntimeError, "-Isolated"):
                    module.install_on_device(evidence / "app", evidence, "primary")
                simctl.assert_called_once_with("xcrun", "simctl", "list", "devices", "--json")
            self.assertFalse((evidence / "device-initial-state.json").exists())
            self.assertFalse((evidence / "installed-device.txt").exists())

    def test_existing_app_is_refused_before_install(self):
        spec = importlib.util.spec_from_file_location("simulator_delivery_contract", SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        appinfo = ["xcrun", "simctl", "appinfo", "isolated", "test.host"]
        with patch.object(module.subprocess, "run",
                          return_value=subprocess.CompletedProcess(appinfo, 0, "installed", "")) as probe:
            with self.assertRaisesRegex(RuntimeError, "Refusing to replace an installed HostApp"):
                module.refuse_existing_install("isolated", "test.host")
            probe.assert_called_once_with(appinfo, check=False, capture_output=True, text=True)
        absent = subprocess.CompletedProcess(appinfo, 3, "",
                                             "No application record found for that bundle identifier")
        with patch.object(module.subprocess, "run", return_value=absent):
            module.refuse_existing_install("isolated", "test.host")
        ambiguous = subprocess.CompletedProcess(appinfo, 3, "", "Simulator service unavailable")
        with patch.object(module.subprocess, "run", return_value=ambiguous):
            with self.assertRaisesRegex(RuntimeError, "Cannot prove the target HostApp is absent"):
                module.refuse_existing_install("isolated", "test.host")
    def test_simulated_entitlements_require_exact_team_bundle_and_group(self):
        spec = importlib.util.spec_from_file_location("simulator_delivery_signing", SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        source = module.entitlement_sources()["HostApp"]
        bundle = "app.songyan.ime"
        full = module.simulated_entitlements(source, bundle, "ABCDE12345")
        self.assertEqual(full["application-identifier"], "ABCDE12345." + bundle)
        self.assertEqual(full[module.GROUPS], ["group.app.songyan.shared"])
        self.assertEqual(module.entitlement_team(full, source, bundle), "ABCDE12345")
        for invalid in ("", "short", "ABCDE1234x", "ABCDE123452"):
            with self.assertRaisesRegex(RuntimeError, "Simulator Team ID"):
                module.simulated_entitlements(source, bundle, invalid)
        for altered in (
            {module.GROUPS: full[module.GROUPS]},
            {**full, "application-identifier": "ABCDE12345.other.bundle"},
            {**full, module.GROUPS: []},
            {**full, "com.apple.developer.team-identifier": "DIFFERENT1"},
        ):
            with self.assertRaises(RuntimeError):
                module.entitlement_team(altered, source, bundle)

    def test_signing_requires_explicit_team_before_creating_delivery(self):
        spec = importlib.util.spec_from_file_location("simulator_delivery_cli", SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with patch("sys.argv", ["deliver-simulator.py", "--from-build", "/nonexistent"]), \
             patch.dict(module.os.environ, {"SONGYAN_SIMULATOR_UDID": ""}), \
             patch.object(module, "entitlement_sources", side_effect=AssertionError("too late")):
            with self.assertRaises(SystemExit) as failure:
                module.main()
            self.assertEqual(failure.exception.code, 2)
    def test_registered_group_requires_exact_install_mapping(self):
        spec = importlib.util.spec_from_file_location("simulator_delivery_mapping", SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        group = "group.app.songyan.shared"
        with tempfile.TemporaryDirectory() as directory:
            valid = {"GroupContainers": {group: Path(directory).as_uri()}}
            with patch.object(module, "run", return_value=plistlib.dumps(valid)):
                self.assertEqual(module.registered_group_path("isolated", "test.host", group),
                                 Path(directory).resolve())
            for invalid in (
                {"GroupContainers": {}},
                {"GroupContainers": {group: directory}},
                {"GroupContainers": {group: Path(directory, "missing").as_uri()}},
            ):
                with patch.object(module, "run", return_value=plistlib.dumps(invalid)):
                    with self.assertRaises(RuntimeError):
                        module.registered_group_path("isolated", "test.host", group)
    def test_certificate_team_must_match_entitlement_team(self):
        spec = importlib.util.spec_from_file_location("simulator_delivery_certificate", SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        valid = "Authority=Apple Development: Local Identity\nTeamIdentifier=ABCDE12345\n"
        module.require_matching_signing_team(valid, "ABCDE12345")
        for signature, team in (
            (valid, "FGHIJ67890"),
            ("Signature=adhoc\nTeamIdentifier=not set\n", "ABCDE12345"),
            ("Authority=Apple Development: Local Identity\nTeamIdentifier=not set\n",
             "ABCDE12345"),
        ):
            with self.assertRaisesRegex(RuntimeError, "signature Team does not match App ID"):
                module.require_matching_signing_team(signature, team)

    def test_signing_requires_real_certificate_before_creating_delivery(self):
        spec = importlib.util.spec_from_file_location("simulator_delivery_identity", SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        argv = ["deliver-simulator.py", "--from-build", "/nonexistent",
                "--simulator-team-id", "ABCDE12345"]
        with patch("sys.argv", argv), patch.dict(module.os.environ, {"SONGYAN_SIMULATOR_UDID": ""}):
            with self.assertRaises(SystemExit) as failure:
                module.main()
            self.assertEqual(failure.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
