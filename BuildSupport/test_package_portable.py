"""Regression tests for portable Mach-O edits; no app or Homebrew required."""
import importlib.util
import io
import tarfile
import json
import zipfile
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


AUDIT_SPEC = importlib.util.spec_from_file_location(
    "audit_dependencies", Path(__file__).with_name("audit-dependencies.py"))
audit = importlib.util.module_from_spec(AUDIT_SPEC)
AUDIT_SPEC.loader.exec_module(audit)


DMG_SPEC = importlib.util.spec_from_file_location(
    "verify_dmg", Path(__file__).with_name("verify-dmg.py"))
dmg = importlib.util.module_from_spec(DMG_SPEC)
DMG_SPEC.loader.exec_module(dmg)


class PortablePackagingTests(unittest.TestCase):
    def test_mounted_dmg_rejects_bad_install_shortcut_and_changed_bom(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            (root / dmg.APP_NAME).mkdir()
            bom = root / "external.bom.json"
            bom.write_text("{}")
            link = root / "Applications"
            link.symlink_to("/tmp")
            with self.assertRaisesRegex(ValueError, "Applications shortcut"):
                dmg.verify_mounted(root, bom)
            link.unlink()
            link.symlink_to("/Applications")
            (root / "如何開啟.txt").write_text("instructions")
            (root / "NOTICE.md").write_text("notices")
            (root / "bom.json").write_text('{"changed": true}')
            with self.assertRaisesRegex(ValueError, "embedded SBOM differs"):
                dmg.verify_mounted(root, bom)

    def test_osv_pagination_and_query_failure_are_explicit(self):
        kegs = [("example", "1.2_3", Path("/tmp"), "homebrew/core")]
        with patch.object(audit, "query_batch", side_effect=[
            [{"vulns": [{"id": "TEST-1"}], "next_page_token": "next"}],
            [{"vulns": [{"id": "TEST-2"}]}],
        ]) as query:
            report = audit.scan(kegs)[0]
            self.assertEqual(report["advisory_ids"], ["TEST-1", "TEST-2"])
            self.assertEqual(report["status"], "matches")
            self.assertEqual(query.call_args.args[0][0]["page_token"], "next")
            self.assertEqual(query.call_args.args[0][0]["version"], "1.2_3")
        with patch.object(audit, "query_batch", side_effect=OSError("offline")):
            self.assertEqual(audit.scan(kegs)[0]["status"], "query-error")
        with patch.object(audit, "query_batch", return_value=[{}]):
            self.assertEqual(audit.scan(kegs)[0]["status"], "no-known-matches")

    def test_source_notice_fallback_is_version_checked_and_bounded(self):
        formula = {"name": "glib", "tap": "homebrew/core", "revision": 0,
                   "versions": {"stable": "2.90.1"},
                   "urls": {"stable": {"url": "https://download.gnome.org/sources/glib/example.tar.xz",
                                       "checksum": "a" * 64}}}
        with patch.object(audit.subprocess, "check_output", return_value=json.dumps({"formulae": [formula]})):
            metadata = audit.source_metadata("glib", "2.90.1")
            self.assertEqual(metadata["sha256"], "a" * 64)
            with self.assertRaisesRegex(ValueError, "version mismatch"):
                audit.source_metadata("glib", "2.90.2")
        with self.assertRaisesRegex(ValueError, "outside approved"):
            audit.check_source_url("https://example.com/source.tar.gz", {"download.gnome.org"})
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode="w:gz") as archive:
            for name, body in [("glib/COPYING", b"synthetic license"), ("../LICENSE", b"escape"),
                               ("sqlite/sqlite3.c", b"public domain\n" + b" " * 5000)]:
                info = tarfile.TarInfo(name)
                info.size = len(body)
                archive.addfile(info, io.BytesIO(body))
            link = tarfile.TarInfo("glib/LICENSE")
            link.type = tarfile.SYMTYPE
            link.linkname = "/etc/passwd"
            archive.addfile(link)
        candidates = audit.source_notice_candidates("glib", stream.getvalue())
        self.assertEqual(candidates, {"glib/COPYING": b"synthetic license"})
        sqlite = audit.source_notice_candidates("sqlite", stream.getvalue())
        self.assertEqual(len(sqlite["sqlite/sqlite3.c.header.txt"]), 4096)
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            keg = root / "keg"
            keg.mkdir()
            with patch.object(audit, "recover_source_notices", return_value=(candidates, metadata)):
                entries = audit.collect_notices([("glib", "2.90.1", keg, "homebrew/core")], root / "notices.zip")
            self.assertEqual(entries[0]["status"], "candidates-collected")
            self.assertEqual(entries[0]["source_fallback"], metadata)
            with zipfile.ZipFile(root / "notices.zip") as archive:
                self.assertEqual(archive.read("glib/2.90.1/upstream-source/glib/COPYING"), b"synthetic license")
            with patch.object(audit, "recover_source_notices", side_effect=ValueError("bad checksum")):
                entries = audit.collect_notices([("glib", "2.90.1", keg, "homebrew/core")], root / "failed.zip")
            self.assertEqual(entries[0]["status"], "missing-review-required")
            self.assertEqual(entries[0]["source_fallback_error"], "ValueError")

    def test_source_notice_recognizes_reuse_license_directory(self):
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode="w:gz") as archive:
            for name, body in [
                ("json-glib-1.10.8/LICENSES/LGPL-2.1-or-later.txt", b"synthetic LGPL"),
                ("json-glib-1.10.8/LICENSES/MIT.txt", b"synthetic MIT"),
                ("json-glib-1.10.8/src/MIT.txt", b"not a notice"),
                ("json-glib-1.10.8/LICENSES/../../outside.txt", b"escape"),
            ]:
                info = tarfile.TarInfo(name)
                info.size = len(body)
                archive.addfile(info, io.BytesIO(body))
            link = tarfile.TarInfo("json-glib-1.10.8/LICENSES/CC0-1.0.txt")
            link.type = tarfile.SYMTYPE
            link.linkname = "/etc/passwd"
            archive.addfile(link)
        self.assertEqual(audit.source_notice_candidates("json-glib", stream.getvalue()), {
            "json-glib-1.10.8/LICENSES/LGPL-2.1-or-later.txt": b"synthetic LGPL",
            "json-glib-1.10.8/LICENSES/MIT.txt": b"synthetic MIT",
        })

    def test_audit_report_cross_checks_keg_set_status_and_notice_bytes(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            bom = root / "app.bom.json"
            report = root / "audit.json"
            notices = root / "notices.zip"
            bom.write_text(json.dumps({"components": [
                {"bom-ref": "homebrew:example@1.2", "name": "example", "version": "1.2"},
                {"bom-ref": "homebrew:other@2.0", "name": "other", "version": "2.0"},
            ]}))
            license_path = root / "LICENSE"
            license_path.write_text("synthetic notice")
            notice_entries = [
                {"formula": "example", "version": "1.2", "status": "candidates-collected",
                 "files": [{"path": "example/1.2/LICENSE", "sha256": audit.sha256(license_path)}]},
                {"formula": "other", "version": "2.0", "status": "missing-review-required", "files": []},
            ]
            def make_archive(changed=False):
                with zipfile.ZipFile(notices, "w") as archive:
                    archive.writestr("example/1.2/LICENSE", "changed" if changed else "synthetic notice")
                    archive.writestr("notice-inventory.json", json.dumps(notice_entries))
            make_archive()
            payload = {
                "sbom_sha256": audit.sha256(bom), "notice_archive_sha256": audit.sha256(notices),
                "osv_endpoint": audit.OSV_URL, "release_review_required": True,
                "scan_complete_for_observed_kegs": True, "notices": notice_entries,
                "packages": [
                    {"formula": "example", "version": "1.2", "tap": "homebrew/core",
                     "status": "matches", "advisory_ids": ["TEST-1"]},
                    {"formula": "other", "version": "2.0", "tap": "homebrew/core",
                     "status": "no-known-matches", "advisory_ids": []},
                ],
            }
            def verify(require=True):
                report.write_text(json.dumps(payload))
                with patch("builtins.print"):
                    return audit.verify_report(bom, report, notices, require_complete=require)
            self.assertTrue(verify())
            other = payload["packages"].pop()
            with self.assertRaisesRegex(ValueError, "advisory keg coverage mismatch"):
                verify()
            payload["packages"].append(other)
            other["status"] = "query-error"
            with self.assertRaisesRegex(ValueError, "inconsistent scan completeness"):
                verify()
            payload["scan_complete_for_observed_kegs"] = False
            self.assertFalse(verify(require=False))
            with self.assertRaisesRegex(ValueError, "incomplete observed-keg"):
                verify()
            other["status"] = "no-known-matches"
            other["advisory_ids"] = ["TEST-2"]
            with self.assertRaisesRegex(ValueError, "inconsistent scan status"):
                verify()
            other["advisory_ids"] = []
            payload["scan_complete_for_observed_kegs"] = True
            make_archive(changed=True)
            payload["notice_archive_sha256"] = audit.sha256(notices)
            with self.assertRaisesRegex(ValueError, "notice member hash mismatch"):
                verify()

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
