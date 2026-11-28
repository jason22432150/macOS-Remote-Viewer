"""Installed recipe evidence tests with synthetic files, no Homebrew required."""
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("recipe_evidence", Path(__file__).with_name("homebrew-recipe-evidence.py"))
ev = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ev)

class RecipeEvidenceTests(unittest.TestCase):
    def test_installed_recipe_requires_core_and_regular_files(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            (root / ".brew").mkdir()
            formula = root / ".brew/glib.rb"
            formula.write_text("class Glib < Formula; end")
            receipt = root / "INSTALL_RECEIPT.json"
            receipt.write_text(json.dumps({"source": {"tap": "homebrew/core"}}))
            self.assertEqual(ev.recipe(root, "glib"), (formula, receipt))
            receipt.write_text(json.dumps({"source": {"tap": "other/tap"}}))
            with self.assertRaises(ValueError):
                ev.recipe(root, "glib")
            receipt.write_text(json.dumps({"source": {"tap": "homebrew/core"}}))
            formula.unlink()
            formula.symlink_to(receipt)
            with self.assertRaises(ValueError):
                ev.recipe(root, "glib")

    def test_archive_coverage_binding_and_ffmpeg_metadata(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            bom, native, formula, receipt, review = [root / n for n in
                ("bom.json", "native.json", "formula.rb", "receipt.json", "review.json")]
            native.write_text("{}")
            bom.write_text(json.dumps({"components": [{"bom-ref": "homebrew:ffmpeg@1", "name": "ffmpeg",
                "version": "1", "components": [{"name": "Contents/Frameworks/libavcodec.1.dylib",
                "properties": [{"name": "mrv:keg-path", "value": "lib/libavcodec.1.dylib"},
                               {"name": "mrv:source-sha256", "value": "a"*64}]}]}]}))
            formula.write_text("class Ffmpeg < Formula; end")
            receipt.write_text(json.dumps({"source": {"tap": "homebrew/core"}}))
            row = {"formula": "ffmpeg", "version": "1", "license_conclusion": None,
                   "formula_sha256": ev.digest(formula), "receipt_sha256": ev.digest(receipt),
                   "ffmpeg_build_metadata": [{"bundle_path": "Contents/Frameworks/libavcodec.1.dylib",
                       "source_sha256": "a"*64, "symbol": "avcodec",
                       "configuration": "--enable-gpl", "license": "GPL version 2 or later"}]}
            entries = {"ffmpeg/1/formula.rb": formula, "ffmpeg/1/INSTALL_RECEIPT.json": receipt,
                       "review.json": review}
            for i, rows in enumerate(([row], [], [dict(row, ffmpeg_build_metadata=[])],
                                      [dict(row, license_conclusion="GPL-2.0-or-later")])):
                review.write_text(json.dumps({"schema": 1, "release_ready": False, "packages": rows}))
                path = root / f"{i}.zip"
                ev.build.write_source_bundle(path, entries, ev.binding(bom, native))
                if i == 0:
                    self.assertEqual(ev.verify(path, bom, native)["packages"], [row])
                else:
                    with self.assertRaises(ValueError):
                        ev.verify(path, bom, native)
            native.write_text('{"changed": true}')
            with self.assertRaises(ValueError):
                ev.verify(root / "0.zip", bom, native)

if __name__ == "__main__":
    unittest.main()
