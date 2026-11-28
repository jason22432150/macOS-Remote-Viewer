"""Static installed formula evidence tests; no network required."""
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("upstream", Path(__file__).with_name("homebrew-upstream-evidence.py"))
up = importlib.util.module_from_spec(spec)
spec.loader.exec_module(up)

class UpstreamEvidenceTests(unittest.TestCase):
    def test_literal_pairs_and_unresolved_declarations(self):
        text = '\n'.join([
            '  url "https://ffmpeg.org/a.tar.xz"',
            '  # comment',
            '  sha256 "' + "a"*64 + '"',
            '  license "GPL-2.0-or-later"',
            '  patch do',
            '    url "https://github.com/a/b.diff"',
            '    sha256 "' + "b"*64 + '"',
            '  end',
            '  resource "dynamic" do',
            '    url "https://example.com/#{version}.tar.gz"',
            '    sha256 "' + "c"*64 + '"',
            '  end',
            '  url "https://example.com/git", revision: "abc"',
            '  license all_of: ["MIT", "GPL-2.0-only"]'])
        result = up.plan(text)
        self.assertEqual(result["literal_license_candidates"], ["GPL-2.0-or-later"])
        self.assertEqual([p["kind"] for p in result["literal_source_candidates"]],
                         ["primary-candidate", "nested-candidate"])
        self.assertEqual([p["line"] for p in result["unresolved_declarations"]], [5, 9, 10, 13, 14])

    def test_literal_mirror_and_version_between_url_and_sha(self):
        sha = "a" * 64
        text = '\n'.join([
            '  url "https://www.sqlite.org/source.tar.gz"',
            '  mirror "https://example.org/source.tar.gz"',
            '  version "3.54.1"',
            '  sha256 "' + sha + '"'])
        result = up.plan(text)
        self.assertEqual(result["literal_source_candidates"], [
            {"line": 1, "url": "https://www.sqlite.org/source.tar.gz",
             "sha256": sha, "kind": "primary-candidate"}])
        self.assertEqual(result["unresolved_declarations"], [])
        for intervening in ('  version version_from_network', '  end',
                            '    mirror "https://example.org/source.tar.gz"',
                            '  mirror "https://example.org/#{version}"'):
            # Interpolation in mirror is not used for a download; it must
            # nevertheless not be treated as literal metadata.
            candidate = '\n'.join([text.splitlines()[0], intervening, text.splitlines()[-1]])
            self.assertEqual(up.plan(candidate)["literal_source_candidates"], [])

    def test_host_allowlist(self):
        self.assertTrue(up.approved("https://ffmpeg.org/releases/ffmpeg.tar.xz"))
        for url in ("http://ffmpeg.org/a", "https://ffmpeg.org.evil.test/a",
                    "https://x@ffmpeg.org/a", "https://ffmpeg.org:8443/a",
                    "https://127.0.0.1/a", "https://ffmpeg.org/a#x"):
            self.assertFalse(up.approved(url))
        with self.assertRaises(ValueError):
            up.RestrictedRedirect().redirect_request(None, None, 302, "", {}, "https://127.0.0.1/a")

    def test_download_hash_and_limit_are_enforced(self):
        class Response(io.BytesIO):
            def geturl(self):
                return "https://ffmpeg.org/source"
        class Opener:
            def open(self, *args, **kwargs):
                return Response(b"source")
        with tempfile.TemporaryDirectory() as raw, patch.object(up.urllib.request, "build_opener", return_value=Opener()):
            target = Path(raw) / "source"
            sha = up.hashlib.sha256(b"source").hexdigest()
            self.assertEqual(up.fetch("https://ffmpeg.org/source", sha, target, 10), 6)
            target.unlink()
            with self.assertRaisesRegex(ValueError, "checksum"):
                up.fetch("https://ffmpeg.org/source", "0"*64, target, 10)
            self.assertFalse(target.exists())
            with self.assertRaises(up.LimitError):
                up.fetch("https://ffmpeg.org/source", sha, target, 1)
            self.assertFalse(target.exists())

    def test_archive_binds_literal_plan_and_bytes(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            bom, native, recipe, review, source = [root / n for n in ("bom", "native", "recipe", "review", "source")]
            for p in (bom, native, recipe):
                p.write_text(p.name)
            source.write_bytes(b"source")
            sha = up.recipes.digest(source)
            plan = up.plan('  url "https://ffmpeg.org/source"\n  sha256 "' + sha + '"')
            key = ("ffmpeg", "1")
            member = "ffmpeg/1/source-1"
            row = {"formula": key[0], "version": key[1], "plan": plan,
                   "downloads": [{"line": 1, "status": "collected", "member": member, "size": 6}]}
            with patch.object(up, "recipe_plans", return_value={key: plan}):
                for i, rows in enumerate(([row], [], [dict(row, downloads=[])])):
                    review.write_text(json.dumps({"schema": 1, "release_ready": False, "packages": rows}))
                    path = root / f"{i}.zip"
                    up.build.write_source_bundle(path, {"review.json": review, member: source},
                                                 up.binding(bom, native, recipe))
                    if i == 0:
                        self.assertEqual(up.verify(path, bom, native, recipe)["packages"], [row])
                    else:
                        with self.assertRaises(ValueError):
                            up.verify(path, bom, native, recipe)

if __name__ == "__main__":
    unittest.main()
