"""Ensure the vendored downstream patch matches the lock, fail closed on changes."""
import importlib.util
import tempfile
import tomllib
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("build_spice_candidate", ROOT / "build-spice-candidate.py")
candidate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(candidate)


class CandidatePatchTests(unittest.TestCase):
    def test_vendored_patch_matches_lock(self):
        with (ROOT / "lockfile.toml").open("rb") as handle:
            lock = tomllib.load(handle)["spice_gtk"]
        data = candidate.read_locked_patch(ROOT / "patches" / "homebrew-macos-drm.patch",
                                           lock["macos_patch_sha256"])
        self.assertEqual(candidate.sha(data), lock["macos_patch_sha256"])

    def test_modified_missing_or_oversized_patch_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "patch"
            digest = candidate.sha(b"original")
            with self.assertRaises(FileNotFoundError):
                candidate.read_locked_patch(path, digest)
            path.write_bytes(b"modified")
            with self.assertRaises(ValueError):
                candidate.read_locked_patch(path, digest)
            data = b"x" * (2 * 1024 * 1024 + 1)
            path.write_bytes(data)
            with self.assertRaises(ValueError):
                candidate.read_locked_patch(path, candidate.sha(data))
