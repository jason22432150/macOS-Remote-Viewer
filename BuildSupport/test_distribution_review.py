"""Review queue must never silently approve or omit evidence."""
import copy
import importlib.util
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("review", Path(__file__).with_name("distribution-review.py"))
review = importlib.util.module_from_spec(spec)
spec.loader.exec_module(review)

def fixture():
    def row(ref):
        return {"component": ref, "review_status": "required", "license_conclusion": None,
                "signed_files": []}
    app = row("app-origin-unverified")
    ffmpeg = row("homebrew:ffmpeg@1")
    ffmpeg.update(installed_recipe_evidence={"formula": "ffmpeg", "version": "1",
                  "ffmpeg_build_metadata": [{"license": "GPL version 3 or later", "configuration": "--enable-gpl"}]},
                  upstream_source_candidates={"formula": "ffmpeg", "version": "1",
                  "plan": {"literal_license_candidates": ["GPL-3.0-or-later"],
                           "literal_source_candidates": [{"line": 3, "url": "https://ffmpeg.org/source",
                                                          "sha256": "a"*64}],
                           "unresolved_declarations": [{"line": 4, "declaration": "license all_of: []"}],
                           "review_hints": [{"role": "local-tap-patch-unverified"}]},
                  "downloads": [{"line": 3, "status": "redirect-blocked"}]},
                  inline_patch_evidence=None, notice_status="candidates-collected")
    return {"scope": "candidate-test-only", "release_ready": False, "components": [app, ffmpeg]}

class ReviewTests(unittest.TestCase):
    def test_missing_source_gpl_and_missing_project_license_remain_explicit(self):
        result = review.make_review(fixture(), [])
        self.assertIs(result["release_ready"], False)
        self.assertTrue(all(r["license_conclusion"] is None for r in result["components"]))
        self.assertEqual(result["task_counts"]["resolve-missing-source-bytes"], 1)
        self.assertEqual(result["task_counts"]["resolve-unverified-local-tap-patch"], 1)
        self.assertEqual(result["task_counts"]["review-gpl-binary-linkage-compatibility"], 1)
        self.assertEqual(result["task_counts"]["resolve-project-root-license-not-found"], 1)
        self.assertEqual(len(result["components"][1]["evidence"]["nonliteral_license_declarations"]), 1)

    def test_project_license_evidence_does_not_approve(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            self.assertEqual(review.project_license_files(root), [])
            (root / "LICENSE").write_text("candidate only")
            found = review.project_license_files(root)
            self.assertEqual(found[0]["path"], "LICENSE")
            result = review.make_review(fixture(), found)
            self.assertNotIn("resolve-project-root-license-not-found", result["task_counts"])
            self.assertIn("review-project-license-and-ownership", result["task_counts"])
            self.assertIs(result["release_ready"], False)

    def test_rejects_preapproved_duplicate_and_identity_mismatch(self):
        for mutation in ("approval", "duplicate", "identity", "coverage"):
            with self.subTest(mutation=mutation):
                inv = fixture()
                if mutation == "approval":
                    inv["components"][1]["license_conclusion"] = "MIT"
                elif mutation == "duplicate":
                    inv["components"].append(copy.deepcopy(inv["components"][0]))
                elif mutation == "identity":
                    inv["components"][1]["installed_recipe_evidence"]["version"] = "2"
                else:
                    inv["components"][1]["upstream_source_candidates"]["downloads"] = []
                with self.assertRaises(ValueError):
                    review.make_review(inv, [])

if __name__ == "__main__":
    unittest.main()
