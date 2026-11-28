"""Offline inline patch extraction and exact archive binding tests."""
import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("inline", Path(__file__).with_name("homebrew-inline-patch-evidence.py"))
ev = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ev)

class InlineTests(unittest.TestCase):
    def test_exact_bytes(self):
        payload = b"diff --git a/a b/a\r\n+data\n"
        meta, body = ev.inline_patch(b"class F < Formula\n  patch :DATA\nend\n__END__\n" + payload)
        self.assertEqual(body, payload)
        self.assertEqual(meta["declaration_line"], 2)
        self.assertEqual(meta["data_line"], 4)
        self.assertIsNone(ev.inline_patch(b"# patch :DATA\n"))
        for data in (b"  patch :DATA\n", b"  patch :DATA\n__END__\n",
                     b"  patch :DATA\n  patch :DATA\n__END__\nx\n"):
            with self.assertRaises(ValueError):
                ev.inline_patch(data)

    def test_archive_rejects_changed_payload(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            bom, native, recipe = [root / n for n in ("bom", "native", "recipe")]
            for p in (bom, native, recipe):
                p.write_text(p.name)
            rows = [{"formula": "test", "version": "1", "inline_patch": {"member": "test/1/data.patch"}}]
            with patch.object(ev, "expected", return_value=(rows, {"test/1/data.patch": b"patch"})):
                out = root / "good.zip"
                ev.collect(bom, native, recipe, out)
                self.assertEqual(ev.verify(out, bom, native, recipe)["packages"], rows)
            with patch.object(ev, "expected", return_value=(rows, {"test/1/data.patch": b"changed"})):
                with self.assertRaisesRegex(ValueError, "bytes mismatch"):
                    ev.verify(out, bom, native, recipe)

if __name__ == "__main__":
    unittest.main()
