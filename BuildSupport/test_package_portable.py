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


VALIDATOR_SPEC = importlib.util.spec_from_file_location(
    "validate_sbom", Path(__file__).with_name("validate-sbom.py"))
validator = importlib.util.module_from_spec(VALIDATOR_SPEC)
VALIDATOR_SPEC.loader.exec_module(validator)


class PortablePackagingTests(unittest.TestCase):
    def test_inventory_rejects_wrong_hash_and_missing_file(self):
        with tempfile.TemporaryDirectory() as raw:
            app = Path(raw)
            binary = app / "libtest.dylib"
            binary.write_bytes(b"binary")
            component = {"type": "file", "bom-ref": "file:libtest.dylib", "name": "libtest.dylib",
                         "hashes": [{"alg": "SHA-256", "content": pack.sha256_file(binary)}]}
            bom = {"components": [component]}
            with patch.object(validator.subprocess, "check_output", return_value="Mach-O"):
                validator.verify_inventory(bom, app)
                component["hashes"][0]["content"] = "0" * 64
                with self.assertRaisesRegex(ValueError, "hash mismatch"):
                    validator.verify_inventory(bom, app)
                with self.assertRaisesRegex(ValueError, "inventory mismatch"):
                    validator.verify_inventory({"components": []}, app)

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

    def test_sbom_records_final_bytes_and_observed_keg_origin(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            source = root / "Cellar" / "example" / "1.2_3" / "lib" / "libexample.dylib"
            source.parent.mkdir(parents=True)
            source.write_bytes(b"original bottle bytes")
            app = root / "Example.app"
            binary = app / "Contents" / "Frameworks" / "libexample.dylib"
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b"final signed bytes")
            relative = binary.relative_to(app).as_posix()
            origin = pack.source_provenance(source)
            self.assertEqual(origin["formula"], "example")
            self.assertEqual(origin["version"], "1.2_3")
            self.assertEqual(origin["source_sha256"], pack.sha256_file(source))
            with patch.object(pack, "iter_macho_files", return_value=[binary]), \
                 patch.object(pack, "parse_macho", return_value=(None, [], [])), \
                 patch.object(pack, "capture", return_value="arm64"):
                bom = pack.build_sbom(app, {relative: origin}, version="1.0.0")
            self.assertEqual(bom["bomFormat"], "CycloneDX")
            package = bom["components"][0]
            self.assertEqual(package["version"], "1.2_3")
            file = package["components"][0]
            self.assertEqual(file["name"], relative)
            self.assertEqual(file["hashes"][0]["content"], pack.sha256_file(binary))
            self.assertNotEqual(file["hashes"][0]["content"], origin["source_sha256"])

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
