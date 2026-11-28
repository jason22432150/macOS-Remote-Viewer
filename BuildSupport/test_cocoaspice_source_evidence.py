"""CocoaSpice source evidence path and mutation tests."""
import importlib.util
import io
import tarfile
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("cs", Path(__file__).with_name("cocoaspice-source-evidence.py"))
cs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cs)

class SourceEvidenceTests(unittest.TestCase):
    def fixture(self, root):
        (root / "Sources/CocoaSpice/include").mkdir(parents=True)
        (root / "Sources/CocoaSpiceRenderer").mkdir()
        (root / "Sources/CocoaSpice/include/CSRenderer.h").write_text("header")
        (root / "Sources/CocoaSpiceNoUsb").symlink_to("CocoaSpice")
        (root / "Sources/CocoaSpiceRenderer/CSRenderer.h").symlink_to("../CocoaSpice/include/CSRenderer.h")
        (root / "LICENSE").write_text("license")
        (root / ".git").mkdir()

    def test_snapshot_checks_generated_files_and_links(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            self.fixture(root)
            before = cs.snapshot(root)
            self.assertEqual(set(before["links"]), cs.LINKS)
            self.assertEqual(len(before["files"]), 2)
            (root / ".git/ignore").write_text("not source")
            self.assertEqual(cs.snapshot(root), before)
            (root / "generated").write_text("new source")
            self.assertIn("generated", cs.changes(before, cs.snapshot(root))["added"])
            (root / "escape").symlink_to("/tmp")
            with self.assertRaises(ValueError):
                cs.snapshot(root)

    def test_link_traversal_and_tar_rejection(self):
        with self.assertRaises(ValueError):
            cs.link_record("Sources/CocoaSpiceNoUsb", "../../escape")
        with self.assertRaises(ValueError):
            cs.link_record("unknown", "file")
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode="w") as archive:
            entry = tarfile.TarInfo("../escape")
            entry.size = 1
            archive.addfile(entry, io.BytesIO(b"x"))
        with self.assertRaises(ValueError):
            cs.parse_upstream(stream.getvalue())

    def test_parse_locked_archive_preserves_regular_bytes_and_link_targets(self):
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode="w") as archive:
            entry = tarfile.TarInfo("LICENSE")
            entry.size = 7
            archive.addfile(entry, io.BytesIO(b"license"))
            for name, target in (("Sources/CocoaSpiceNoUsb", "CocoaSpice"),
                ("Sources/CocoaSpiceRenderer/CSRenderer.h", "../CocoaSpice/include/CSRenderer.h")):
                entry = tarfile.TarInfo(name)
                entry.type = tarfile.SYMTYPE
                entry.linkname = target
                archive.addfile(entry)
        result, blobs = cs.parse_upstream(stream.getvalue())
        self.assertEqual(result["files"]["LICENSE"], cs.record(b"license", 0o644))
        self.assertEqual(set(result["links"]), cs.LINKS)
        self.assertEqual(blobs["Sources/CocoaSpiceNoUsb"][0], "120000")

if __name__ == "__main__":
    unittest.main()
