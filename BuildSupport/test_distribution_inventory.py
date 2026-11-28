"""Distribution evidence coverage regressions; no macOS runtime required."""
import copy
import importlib.util
import unittest
import tempfile
from pathlib import Path

spec = importlib.util.spec_from_file_location("distribution_inventory", Path(__file__).with_name("distribution-inventory.py"))
inv = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inv)

def props(values):
    return [{"name": k, "value": v} for k, v in values.items()]

def file(name, values):
    return {"type": "file", "bom-ref": "file:" + name, "name": name,
            "hashes": [{"alg": "SHA-256", "content": "a" * 64}],
            "properties": props({"mrv:bundle-path": name, **values})}

def keg(name, version, path):
    return {"type": "library", "bom-ref": "homebrew:" + name + "@" + version,
            "name": name, "version": version, "components": [
                file(path, {"mrv:formula": name, "mrv:version": version,
                            "mrv:source-sha256": "b" * 64})]}

class DistributionInventoryTests(unittest.TestCase):
    def fixture(self):
        other = keg("glib", "2.90.1", "Contents/Frameworks/libglib.dylib")
        app = file("Contents/MacOS/app", {})
        baseline = {"components": [app, other, keg("spice-gtk", "0.43_1", inv.TARGET)]}
        modified = {"type": "library", "bom-ref": inv.MODIFIED, "version": "0.43",
                    "components": [file(inv.TARGET, {
                        "mrv:build-origin": "locally-built-modified-spice-gtk",
                        "mrv:source-sha256": "c" * 64,
                        "mrv:baseline-source-sha256": "b" * 64,
                        "mrv:source-evidence-sha256": "d" * 64,
                        "mrv:candidate-patch-sha256": "e" * 64})]}
        candidate = {"components": [copy.deepcopy(app), copy.deepcopy(other), modified],
                     "metadata": {"properties": props({"mrv:distribution-scope":
                         "candidate-test-only; distribution review incomplete"})}}
        entries = [{"formula": n, "version": v, "files": [], "status": "missing-review-required",
                    "advisory_ids": []} for n, v in (("glib", "2.90.1"), ("spice-gtk", "0.43_1"))]
        report = {"notices": entries, "packages": copy.deepcopy(entries)}
        stage = {"source_evidence_sha256": "d" * 64, "candidate_raw_sha256": "c" * 64,
                 "candidate_patch_sha256": "e" * 64, "candidate_signed_sha256": "a" * 64}
        return baseline, candidate, report, stage, "d" * 64, "f" * 40

    def test_unique_artifact_resolves_nested_upload_layout(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            child = root / "nested"
            child.mkdir()
            archive = child / "source.zip"
            archive.write_bytes(b"fixture")
            self.assertEqual(inv.only(root, "source.zip"), archive)
            (root / "source.zip").write_bytes(b"duplicate")
            with self.assertRaises(ValueError):
                inv.only(root, "source.zip")
            with self.assertRaises(ValueError):
                inv.only(root, "missing.zip")

    def test_exact_coverage_and_no_implicit_approval(self):
        result = inv.make_inventory(*self.fixture())
        self.assertIs(result["release_ready"], False)
        self.assertEqual(result["signed_file_count"], 3)
        rows = {r["component"]: r for r in result["components"]}
        self.assertEqual(set(rows), {"app-origin-unverified", "homebrew:glib@2.90.1",
                                     inv.MODIFIED, "cocoaspice:" + "f" * 40})
        self.assertTrue(all(r["review_status"] == "required" and r["license_conclusion"] is None
                            for r in rows.values()))
        self.assertEqual(rows[inv.MODIFIED]["source_evidence_sha256"], "d" * 64)

    def test_rejects_changed_coverage_origin_and_binding(self):
        for mutation in ("missing", "duplicate", "origin", "source", "audit", "scope"):
            with self.subTest(mutation=mutation):
                args = self.fixture()
                _, candidate, report, stage, _, _ = args
                if mutation == "missing":
                    candidate["components"].pop(0)
                elif mutation == "duplicate":
                    candidate["components"].append(candidate["components"][0])
                elif mutation == "origin":
                    candidate["components"][1]["components"][0]["properties"][-1]["value"] = "0" * 64
                elif mutation == "source":
                    stage["source_evidence_sha256"] = "0" * 64
                elif mutation == "audit":
                    report["notices"].pop()
                else:
                    candidate["metadata"]["properties"][0]["value"] = "release-ready"
                with self.assertRaises(ValueError):
                    inv.make_inventory(*args)

if __name__ == "__main__":
    unittest.main()
