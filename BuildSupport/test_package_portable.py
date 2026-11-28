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


SPICE_SOURCE_SPEC = importlib.util.spec_from_file_location(
    "audit_spice_source", Path(__file__).with_name("audit-spice-source.py"))
spice_source = importlib.util.module_from_spec(SPICE_SOURCE_SPEC)
SPICE_SOURCE_SPEC.loader.exec_module(spice_source)


BUILD_SPICE_SPEC = importlib.util.spec_from_file_location(
    "build_spice_candidate", Path(__file__).with_name("build-spice-candidate.py"))
build_spice = importlib.util.module_from_spec(BUILD_SPICE_SPEC)
BUILD_SPICE_SPEC.loader.exec_module(build_spice)


TLS_SPEC = importlib.util.spec_from_file_location(
    "tls_fixture", Path(__file__).with_name("test-loopback-tls.py"))
tls_fixture = importlib.util.module_from_spec(TLS_SPEC)
TLS_SPEC.loader.exec_module(tls_fixture)


AGENT_SPEC = importlib.util.spec_from_file_location(
    "agent_fixture", Path(__file__).with_name("test-spice-receive-agent.py"))
agent_fixture = importlib.util.module_from_spec(AGENT_SPEC)
AGENT_SPEC.loader.exec_module(agent_fixture)


STAGE_SPEC = importlib.util.spec_from_file_location(
    "stage_spice_candidate", Path(__file__).with_name("stage-spice-candidate-app.py"))
stage = importlib.util.module_from_spec(STAGE_SPEC)
STAGE_SPEC.loader.exec_module(stage)


class PortablePackagingTests(unittest.TestCase):
    def test_source_evidence_archive_binds_bytes_modes_and_build(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            source = root / "source"
            source.mkdir()
            license = source / "COPYING"
            license.write_bytes(b"test license")
            tool = source / "build.sh"
            tool.write_bytes(b"#!/bin/sh\n")
            tool.chmod(0o755)
            inventory = build_spice.source_tree(source)
            self.assertEqual(inventory["build.sh"]["mode"], 0o755)
            entries = {"source/" + name: source / name for name in inventory}
            binding = {"candidate_dylib_sha256": "a" * 64}
            bundle = root / "source.zip"
            manifest = build_spice.write_source_bundle(bundle, entries, binding)
            self.assertEqual(manifest["members"]["source/build.sh"], inventory["build.sh"])
            self.assertEqual(build_spice.verify_source_bundle(bundle, binding), manifest)
            with self.assertRaises(ValueError):
                build_spice.verify_source_bundle(bundle, {"candidate_dylib_sha256": "b" * 64})
            with self.assertRaises(ValueError):
                build_spice.write_source_bundle(root / "unsafe.zip", {"../COPYING": license}, binding)
            # Repack altered bytes with the unchanged manifest, valid ZIP CRC.
            corrupt = root / "corrupt.zip"
            with zipfile.ZipFile(bundle) as old, zipfile.ZipFile(corrupt, "w") as new:
                for item in old.infolist():
                    new.writestr(item, b"altered" if item.filename == "source/COPYING" else old.read(item))
            with self.assertRaises(ValueError):
                build_spice.verify_source_bundle(corrupt, binding)

    def test_mounted_candidate_report_binds_runtime_copy(self):
        with tempfile.TemporaryDirectory() as raw:
            output = Path(raw)
            app = output / "mounted-copy" / stage.APP
            library = app / "Contents" / "Frameworks" / stage.LIBRARY
            library.parent.mkdir(parents=True)
            library.write_bytes(b"signed candidate")
            digest = stage.digest(library)
            report = {
                "candidate_signed_sha256": digest,
                "candidate_package": {"signed_library_sha256": digest,
                                      "runtime_input": "mounted-copy/" + stage.APP},
                "dyld_image_lines": ["dyld: loaded " + str(library.resolve())],
            }
            sidecar = app.parent / "staging-report.json"
            with self.assertRaises(ValueError):
                stage.publish_mounted_report(output, dict(report, dyld_image_lines=[]))
            with self.assertRaises(ValueError):
                stage.publish_mounted_report(output, dict(report, dyld_image_lines=[
                    "dyld: loaded " + str(output / stage.APP / "Contents/Frameworks" / stage.LIBRARY)]))
            with self.assertRaises(ValueError):
                stage.publish_mounted_report(output, dict(report, candidate_signed_sha256="0" * 64))
            self.assertFalse(sidecar.exists())
            stage.publish_mounted_report(output, report)
            self.assertEqual(json.loads(sidecar.read_text()), report)
            self.assertEqual(sidecar.read_bytes(), (output / "staging-report.json").read_bytes())
            with self.assertRaises(FileExistsError):
                stage.publish_mounted_report(output, report)

    def test_candidate_sbom_does_not_inherit_bottle_provenance(self):
        target = "Contents/Frameworks/" + stage.LIBRARY
        other = "Contents/Frameworks/libother.dylib"
        report = {key: str(i) * 64 for i, key in enumerate((
            "upstream_sha256", "downstream_sha256", "candidate_patch_sha256",
            "candidate_dylib_sha256", "baseline_sha256", "source_evidence_sha256"), 1)}
        def file(name, formula, digest):
            return {"type": "file", "name": name, "properties": [
                {"name": "mrv:source-sha256", "value": digest},
                {"name": "mrv:formula", "value": formula},
                {"name": "mrv:version", "value": "0.43_1"},
                {"name": "mrv:keg-path", "value": "lib/" + Path(name).name}]}
        baseline = {"components": [{"type": "library", "components": [
            file(target, "spice-gtk", report["baseline_sha256"]),
            file(other, "other", "a" * 64)]}]}
        origins = stage.candidate_origins(baseline, report)
        self.assertNotIn("formula", origins[target])
        self.assertNotIn("keg_path", origins[target])
        self.assertEqual(origins[target]["source_sha256"], report["candidate_dylib_sha256"])
        self.assertEqual(origins[target]["source_evidence_sha256"], report["source_evidence_sha256"])
        self.assertEqual(origins[other]["formula"], "other")
        with tempfile.TemporaryDirectory() as raw:
            app = Path(raw)
            binaries = [app / target, app / other]
            for binary in binaries:
                binary.parent.mkdir(parents=True, exist_ok=True)
                binary.write_bytes(binary.name.encode())
            final = stage.digest(binaries[0])
            with patch.object(stage.pack, "iter_macho_files", return_value=binaries), \
                 patch.object(stage.pack, "parse_macho", return_value=(None, [], [])), \
                 patch.object(stage.pack, "capture", return_value="arm64"), \
                 patch.object(stage.pack, "app_version", return_value="1.0.0"):
                bom = stage.candidate_sbom(app, baseline, report, final)
                candidate = next(p for p in bom["components"] if p["bom-ref"] == "modified:spice-gtk@0.43")
                self.assertEqual(candidate["components"][0]["hashes"][0]["content"], final)
                self.assertFalse(any(p["bom-ref"].startswith("homebrew:spice-gtk") for p in bom["components"]))
                self.assertTrue(any(p["bom-ref"].startswith("homebrew:other") for p in bom["components"]))
                with self.assertRaises(ValueError):
                    stage.candidate_sbom(app, baseline, report, "f" * 64)
        with self.assertRaises(ValueError):
            stage.candidate_origins(baseline, dict(report, baseline_sha256="f" * 64))
        with self.assertRaises(ValueError):
            stage.candidate_origins(baseline, dict(report, candidate_patch_sha256="bad"))

    def test_proxy_certificate_rejection_requires_established_tunnel_and_tls_evidence(self):
        def stats(**overrides):
            return {"decoy": {"connections": 0},
                    "explicit": dict(dict(connections=1, tunnels=1, errors=0, relay_resets=1), **overrides)}

        observed = dict(connections=1, handshakes=0, tls_started=1,
                        certificate_alerts=1, plaintext=False,
                        application_data=False, link_header=False)
        generic = {"MRV_TLS_PROBE_TERMINAL"}
        typed = {"MRV_TLS_PROBE_REJECTED_TLS"}
        tls_fixture.assert_observations("wrong-ca", observed, False)
        tls_fixture.assert_proxy_observations("wrong-ca", stats(), observed, False, generic)
        no_alert = dict(observed, certificate_alerts=0)
        tls_fixture.assert_proxy_observations("wrong-ca", stats(), no_alert, False, typed)
        for bad_stats, bad_observed, markers in (
            (stats(tunnels=0), observed, typed),
            (stats(errors=1), observed, typed),
            (stats(), dict(observed, tls_started=0), typed),
            (stats(), dict(observed, connections=2), typed),
            (stats(), no_alert, generic),
            (dict(stats(), decoy={"connections": 1}), observed, typed),
        ):
            with self.assertRaises(AssertionError):
                tls_fixture.assert_proxy_observations("wrong-ca", bad_stats, bad_observed, False, markers)
        with self.assertRaises(AssertionError):
            tls_fixture.assert_observations("wrong-ca", dict(observed, application_data=True), False)
        trusted = dict(observed, handshakes=1, certificate_alerts=0,
                       application_data=True, link_header=True)
        tls_fixture.assert_observations("trusted", trusted, True)
        tls_fixture.assert_proxy_observations("trusted", stats(relay_resets=0), trusted, True, generic)
        with self.assertRaises(AssertionError):
            tls_fixture.assert_proxy_observations("trusted", stats(), trusted, True, generic)

    def test_agent_relay_mini_frame_stream_boundaries(self):
        import struct

        class FragmentedStream:
            def __init__(self, payload):
                self.payload = bytearray(payload)

            def recv(self, count):
                count = min(count, 2, len(self.payload))
                data = bytes(self.payload[:count])
                del self.payload[:count]
                return data

        stream = FragmentedStream(struct.pack("<HI", 3, 0) +
                                  struct.pack("<HI", 4, 3) + b"abc")
        self.assertEqual(agent_fixture.read_mini_frame(stream, 6, 0, 2, 1, 4)[1:], (3, b""))
        self.assertEqual(agent_fixture.read_mini_frame(stream, 6, 0, 2, 2, 4)[1:], (4, b"abc"))
        self.assertFalse(stream.payload)
        with self.assertRaises(ValueError):
            agent_fixture.read_mini_frame(FragmentedStream(struct.pack("<HI", 109, 65537)), 6, 0, 2, 1, 4)
        with self.assertRaises(ValueError):
            agent_fixture.read_mini_frame(FragmentedStream(b""), 8, 0, 2, 1, 4)
        # Real CI bandwidth probe size; allow only the PING type, retaining
        # the smaller non-PING cap. Use BytesIO to avoid quadratic short reads.
        class BufferedStream:
            def __init__(self, payload):
                self.stream = io.BytesIO(payload)

            def recv(self, count):
                return self.stream.read(count)

        padded = b"\0" * 256012
        stream = BufferedStream(struct.pack("<HI", 4, len(padded)) + padded +
                                struct.pack("<HI", 109, 3) + b"abc")
        self.assertEqual(agent_fixture.read_mini_frame(stream, 6, 0, 2, 1, 4)[1:], (4, padded))
        self.assertEqual(agent_fixture.read_mini_frame(stream, 6, 0, 2, 2, 4)[1:], (109, b"abc"))
        with self.assertRaises(ValueError):
            agent_fixture.read_mini_frame(BufferedStream(struct.pack("<HI", 4, 512 * 1024 + 1)), 6, 0, 2, 1, 4)
        with self.assertRaises(ValueError):
            agent_fixture.read_mini_frame(BufferedStream(struct.pack("<HI", 109, len(padded))), 6, 0, 2, 1, 4)

    def test_fixture_certificates_pass_strict_tls_and_reject_wrong_identity(self):
        import ssl
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            tls_fixture.create_certificates(root)
            server_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            server_context.load_cert_chain(root / "server.pem", root / "server.key")

            def handshake(ca, hostname):
                # In-memory TLS, no network listener or system trust store changes.
                ci, co, si, so = (ssl.MemoryBIO() for _ in range(4))
                client = tls_fixture.strict_client_context(ca).wrap_bio(
                    ci, co, server_hostname=hostname)
                server = server_context.wrap_bio(si, so, server_side=True)
                done = [False, False]
                for _ in range(40):
                    for index, peer in enumerate((client, server)):
                        if not done[index]:
                            try:
                                peer.do_handshake()
                                done[index] = True
                            except ssl.SSLWantReadError:
                                pass
                    if co.pending:
                        si.write(co.read())
                    if so.pending:
                        ci.write(so.read())
                    if all(done):
                        return
                self.fail("strict TLS fixture handshake did not complete")

            handshake(root / "trusted.pem", "mrv-ci.test")
            handshake(root / "trusted.pem", "127.0.0.1")
            with self.assertRaises(ssl.SSLCertVerificationError):
                handshake(root / "untrusted.pem", "mrv-ci.test")
            with self.assertRaises(ssl.SSLCertVerificationError):
                handshake(root / "trusted.pem", "wrong.test")

    def test_candidate_library_path_is_fixed_and_confined(self):
        with tempfile.TemporaryDirectory() as raw:
            prefix = Path(raw) / "prefix"
            lib = prefix / "lib"
            lib.mkdir(parents=True)
            (lib / "gstreamer").write_bytes(b"not spice")
            with self.assertRaises(FileNotFoundError):
                build_spice.spice_client_library(prefix)
            expected = lib / "libspice-client-glib-2.0.8.dylib"
            expected.write_bytes(b"candidate")
            self.assertEqual(build_spice.spice_client_library(prefix), expected.resolve())
            expected.unlink()
            outside = Path(raw) / "outside.dylib"
            outside.write_bytes(b"outside")
            expected.symlink_to(outside)
            with self.assertRaises(ValueError):
                build_spice.spice_client_library(prefix)

    def test_candidate_tls_abi_pair_requires_single_matching_major(self):
        for abi in ("3", "4"):
            ssl = f"/opt/homebrew/opt/openssl@{abi}/lib/libssl.{abi}.dylib"
            crypto = f"/opt/homebrew/opt/openssl@{abi}/lib/libcrypto.{abi}.dylib"
            self.assertEqual(build_spice.tls_load_names(
                [ssl, crypto, "/usr/lib/libSystem.B.dylib"]),
                {"ssl": ssl, "crypto": crypto})
        for deps in ([], ["libssl.3.dylib"],
                     ["libssl.3.dylib", "libcrypto.4.dylib"],
                     ["libssl.3.dylib", "libssl.4.dylib", "libcrypto.3.dylib"]):
            with self.assertRaises(ValueError):
                build_spice.tls_load_names(deps)


    def test_spice_source_archive_selects_exact_regular_members(self):
        def archive(entries):
            stream = io.BytesIO()
            with tarfile.open(fileobj=stream, mode="w:xz") as tar:
                for name, body in entries:
                    info = tarfile.TarInfo(name)
                    if body is None:
                        info.type = tarfile.SYMTYPE
                        info.linkname = "/tmp/elsewhere"
                        tar.addfile(info)
                    else:
                        info.size = len(body)
                        tar.addfile(info, io.BytesIO(body))
            return stream.getvalue()
        main = ("spice-gtk-0.43/src/channel-main.c", b"static void main_handle_agent_data(void) {}")
        channel = ("spice-gtk-0.43/src/spice-channel.c", b"void *p = g_malloc(size);")
        private = ("spice-gtk-0.43/src/spice-channel-priv.h", b"struct _SpiceMsgIn { int refcount; };")
        session = ("spice-gtk-0.43/src/spice-session.c", b"g_free(s->password);")
        uri = ("spice-gtk-0.43/src/spice-uri.c", b"g_free(self->password);")
        entries_ok = [main, channel, private, session, uri]
        data = archive(entries_ok + [("spice-gtk-0.43/src/unrelated.c", b"ignored")])
        self.assertEqual(set(spice_source.read_source_files(data, "0.43")),
                         set(spice_source.FILES))
        for entries in ([main], entries_ok[:-1], entries_ok + [main],
                        [main, (channel[0], None), private, session, uri],
                        [main, channel, (private[0], None), session, uri],
                        entries_ok + [("../escape", b"x")]):
            with self.assertRaises(ValueError):
                spice_source.read_source_files(archive(entries), "0.43")
        with self.assertRaises(ValueError):
            spice_source.verify_digest(data, "0" * 64)
        with self.assertRaises(ValueError):
            spice_source.check_url("https://example.com/spice.tar.xz")
        self.assertTrue(spice_source.review_lines(main[1].decode(), "src/channel-main.c"))
        self.assertTrue(spice_source.review_lines(private[1].decode(), "src/spice-channel-priv.h"))
        self.assertTrue(spice_source.review_lines(session[1].decode(), "src/spice-session.c"))
        self.assertTrue(spice_source.review_lines(uri[1].decode(), "src/spice-uri.c"))


    def test_openssl_modules_follow_linked_crypto_keg(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            lib = root / "openssl@3" / "3.5.9" / "lib"
            lib.mkdir(parents=True)
            crypto = lib / "libcrypto.3.dylib"
            crypto.touch()
            modules = lib / "ossl-modules"
            unrelated = root / "openssl@4" / "lib" / "ossl-modules"
            unrelated.mkdir(parents=True)
            linked = {"libcrypto.3.dylib": crypto}
            self.assertIsNone(pack.find_openssl_modules(linked))
            modules.symlink_to(unrelated, target_is_directory=True)
            with self.assertRaisesRegex(pack.BundleError, "escapes"):
                pack.find_openssl_modules(linked)
            modules.unlink()
            modules.mkdir()
            # macOS /var is a symlink to /private/var; the production
            # function deliberately returns the physical libcrypto keg path.
            self.assertEqual(pack.find_openssl_modules(linked), modules.resolve())
            alias = root / "opt-crypto"
            alias.symlink_to(lib, target_is_directory=True)
            self.assertEqual(pack.find_openssl_modules({"libcrypto.3.dylib": alias / crypto.name}),
                             modules.resolve())
            with self.assertRaisesRegex(pack.BundleError, "exactly one"):
                pack.find_openssl_modules({})
            with self.assertRaisesRegex(pack.BundleError, "exactly one"):
                pack.find_openssl_modules({**linked, "libcrypto.4.dylib":
                                           unrelated.parent / "libcrypto.4.dylib"})

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
