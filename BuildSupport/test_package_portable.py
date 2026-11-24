"""Regression tests for portable Mach-O edits; no app or Homebrew required."""
import importlib.util
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "package_portable", Path(__file__).with_name("package-portable.py"))
pack = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(pack)


class PortablePackagingTests(unittest.TestCase):
    def test_rewrite_batches_all_commands_without_stripping_signature(self):
        binary = Path("/tmp/App With Spaces")
        with patch.object(pack, "parse_macho", return_value=(
            "/opt/homebrew/lib/a.dylib",
            ["/opt/homebrew/lib/b.dylib", "/usr/lib/libSystem.B.dylib"],
            ["/opt/homebrew/lib", "@loader_path"],
        )), patch.object(pack, "run") as run:
            pack.rewrite_load_commands(binary, id_path="@rpath/a.dylib",
                                       extra_rpath="@loader_path/../Frameworks")
            run.assert_called_once_with([
                "xcrun", "install_name_tool", "-id", "@rpath/a.dylib",
                "-change", "/opt/homebrew/lib/b.dylib", "@rpath/b.dylib",
                "-delete_rpath", "/opt/homebrew/lib",
                "-add_rpath", "@loader_path/../Frameworks", str(binary),
            ])

    def test_copy_keeps_signature_bytes(self):
        with tempfile.TemporaryDirectory() as raw:
            source = Path(raw) / "source"
            destination = Path(raw) / "copy"
            source.write_bytes(b"binary and signature bytes")
            with patch.object(pack, "run") as run:
                pack.copy_binary(source, destination)
                run.assert_not_called()
            self.assertEqual(destination.read_bytes(), source.read_bytes())

    @unittest.skipUnless(shutil.which("xcrun"), "requires macOS Xcode tools")
    def test_real_arm64_macho_rewrite_then_sign(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            source = root / "test.c"
            source.write_text("int main(void) { return 0; }\n")
            binary = root / "Executable With Spaces"
            pack.run(["xcrun", "clang", "-arch", "arm64",
                      "-Wl,-headerpad_max_install_names", "-Wl,-rpath,/opt/homebrew/lib",
                      str(source), "-o", str(binary)])
            pack.adhoc_sign(binary)
            pack.rewrite_load_commands(binary, id_path=None, extra_rpath="@loader_path")
            _, _, rpaths = pack.parse_macho(binary)
            self.assertIn("@loader_path", rpaths)
            self.assertNotIn("/opt/homebrew/lib", rpaths)
            pack.adhoc_sign(binary)
            pack.run(["codesign", "--verify", "--strict", str(binary)])


if __name__ == "__main__":
    unittest.main()
