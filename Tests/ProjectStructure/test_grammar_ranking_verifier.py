"""Unit-test the ranking evidence verifier, not a substitute for native replay."""
import importlib.util
import unittest
from copy import deepcopy
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("grammar_ranking", ROOT / "Tools/BuildRimeIOS/scripts/verify-grammar-ranking.py")
RANKING = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RANKING)


class GrammarRankingVerifierTests(unittest.TestCase):
    def setUp(self):
        self.fixture = {"model_sha256": "0" * 64, "cases": [
            {"code": "abc", "enabled_prefix": ["A"], "disabled_prefix": ["B"]}
        ]}
        self.enabled = {"mode": "enabled", "version": "1.17.0", "platform": "unit fixture", "schema": "songyan_quanpin",
                        "modelSHA256": "0" * 64, "grammarRegistered": True, "luaRegistered": True,
                        "final": {"loads": [{"success": True, "entries": 10}], "queryCount": 5, "lookupCount": 4, "matchCount": 3},
                        "replay": [{"code": "abc", "candidates": ["A", "B"], "commit": "A"}]}
        self.disabled = deepcopy(self.enabled)
        self.disabled.update(mode="disabled", modelSHA256=None,
                             final={"loads": [], "queryCount": 0},
                             replay=[{"code": "abc", "candidates": ["B", "A"], "commit": "B"}])

    def test_exact_calibrated_pair_is_accepted(self):
        result = RANKING.verify_reports(self.enabled, self.disabled, self.fixture)
        self.assertEqual(result["changed_cases"], ["abc"])
        self.assertIn("not iOS", result["scope"])

    def test_load_only_without_decoder_lookups_is_rejected(self):
        self.enabled["final"]["matchCount"] = 0
        with self.assertRaisesRegex(ValueError, "lookup/match"):
            RANKING.verify_reports(self.enabled, self.disabled, self.fixture)

    def test_wrong_model_hash_or_live_control_model_is_rejected(self):
        self.enabled["modelSHA256"] = "f" * 64
        with self.assertRaisesRegex(ValueError, "identity/control"):
            RANKING.verify_reports(self.enabled, self.disabled, self.fixture)
        self.enabled["modelSHA256"] = "0" * 64
        self.disabled["final"]["loads"] = [{"success": True}]
        with self.assertRaisesRegex(ValueError, "control consumed"):
            RANKING.verify_reports(self.enabled, self.disabled, self.fixture)

    def test_candidate_calibration_and_order_are_required(self):
        self.enabled["replay"][0]["candidates"] = ["B", "A"]
        with self.assertRaisesRegex(ValueError, "calibration"):
            RANKING.verify_reports(self.enabled, self.disabled, self.fixture)
        self.fixture["cases"][0]["enabled_prefix"] = ["B"]
        with self.assertRaisesRegex(ValueError, "ranking difference"):
            RANKING.verify_reports(self.enabled, self.disabled, self.fixture)

    def test_cross_engine_and_wrong_input_are_rejected(self):
        self.disabled["version"] = "other"
        with self.assertRaisesRegex(ValueError, "versions differ"):
            RANKING.verify_reports(self.enabled, self.disabled, self.fixture)
        self.disabled["version"] = "1.17.0"
        self.disabled["replay"][0]["code"] = "different"
        with self.assertRaisesRegex(ValueError, "fixed input"):
            RANKING.verify_reports(self.enabled, self.disabled, self.fixture)


if __name__ == "__main__":
    unittest.main()
