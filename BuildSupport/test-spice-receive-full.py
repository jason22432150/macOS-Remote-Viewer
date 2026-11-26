#!/usr/bin/env python3
"""Candidate-only full-header local TLS receive and ownership regression."""
import argparse
import functools
import hashlib
import importlib.util
import json
import socket
import ssl
import struct
import subprocess
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("wire_fixture", HERE / "test-spice-receive-wire.py")
wire = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(wire)
RETAIN = "MRV_NATIVE_WIRE_CHILD_RETAINED"
RELEASE = "MRV_NATIVE_WIRE_CHILD_RELEASED"
PARENT = "MRV_NATIVE_WIRE_PARENT_RELEASED"
BAD_LIST = "MRV_NATIVE_WIRE_SUBLIST_REJECTED"
BAD_CHILD = "MRV_NATIVE_WIRE_CHILD_PARSE_REJECTED"


def submessage_frame(client, server, mini, layout, declared, reject, sub_layout, mode):
    if mini:
        raise AssertionError("expected negotiated full header")
    (list_type, ping_type, header_size, type_off, serial_off, size_off,
     list_off, list_prefix, count_size, child_size, child_type_off, child_size_off) = sub_layout
    if (header_size, type_off, serial_off, size_off, list_off,
            list_prefix, count_size, child_size, child_type_off, child_size_off) != (18, 8, 0, 10, 14, 2, 2, 6, 0, 2):
        raise ValueError("unexpected installed full-header/submessage layout")
    if layout[7:9] != (header_size, size_off):
        raise ValueError("full-header layout disagreement")
    # Preserve genuine initial main message; replace only first actual PING.
    for index in range(8):
        header = bytearray(wire.link.read_exact(server, header_size))
        size = wire.word(header, size_off)
        kind = struct.unpack_from("<H", header, type_off)[0]
        if size > 512 * 1024 or wire.word(header, list_off):
            raise ValueError("unexpected local full-header fixture frame")
        body = wire.link.read_exact(server, size)
        if kind == ping_type:
            break
        client.sendall(header + body)
    else:
        raise AssertionError("fixture did not send initial PING")
    if len(body) != 12:
        raise ValueError("expected small initial PING")
    # Synthetic message list only uses locally generated protocol data.
    if mode == "bad-list":
        payload = struct.pack("<H", 1)  # missing offset table
    else:
        child_body = body if mode == "valid" else b""
        payload = struct.pack("<HIHI", 1, 6, ping_type, len(child_body)) + child_body
    struct.pack_into("<H", header, type_off, list_type)
    struct.pack_into("<I", header, size_off, len(payload))
    struct.pack_into("<I", header, list_off, 0)
    client.sendall(header + payload)
    deadline = time.monotonic() + (4 if reject else 0.75)
    consumed = 0
    while time.monotonic() < deadline:
        client.settimeout(max(0.01, deadline - time.monotonic()))
        try:
            data = client.recv(4096)
        except socket.timeout:
            break
        except (ssl.SSLEOFError, ConnectionResetError):
            data = b""
        if not data:
            if reject:
                return {"mode": mode, "closed": True}
            raise AssertionError("valid submessage list closed prematurely")
        consumed += len(data)
        if consumed > 65536:
            raise ValueError("unexpected local control traffic")
    if reject:
        raise AssertionError("invalid submessage did not close")
    return {"mode": mode, "closed": False}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True, type=Path)
    args = parser.parse_args()
    app = args.app.resolve()
    report = json.loads((app.parent / "staging-report.json").read_text())
    library = app / "Contents/Frameworks/libspice-client-glib-2.0.8.dylib"
    if hashlib.sha256(library.read_bytes()).hexdigest() != report["candidate_signed_sha256"] or not report["dyld_image_lines"]:
        raise ValueError("candidate identity not verified")
    if "#define MRV_WIRE_MAX ((guint32)(128u * 1024u * 1024u))" not in (HERE / "spice-receive-limits.h").read_text():
        raise ValueError("wire policy changed")
    maximum = 128 * 1024 * 1024
    with tempfile.TemporaryDirectory(prefix="mrv-full-header-") as raw:
        root = Path(raw)
        fixture, probe = root / "server", root / "probe"
        wire.auth.tls.create_certificates(root)
        wire.auth.compile_fixture(fixture)
        wire.auth.compile_native_probe(app, probe, source="spice-native-receive.c")
        layout = tuple(map(int, subprocess.check_output([str(probe), "--layout"], text=True, timeout=10).split()))
        sub_layout = tuple(map(int, subprocess.check_output([str(probe), "--sub-layout"], text=True, timeout=10).split()))
        if len(layout) != 11 or len(sub_layout) != 12:
            raise ValueError("unexpected installed protocol layout")
        print(f"full header layout={sub_layout}", flush=True)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(root / "server.pem", root / "server.key")
        upstream = wire.auth.tls.strict_client_context(root / "trusted.pem")
        observer = functools.partial(wire.observe, force_full=True)
        wire.test_case(root, fixture, probe, context, upstream, layout,
                       "full-at-limit", maximum, False, observe_fn=observer)
        wire.test_case(root, fixture, probe, context, upstream, layout,
                       "full-over-limit", maximum + 1, True, observe_fn=observer)
        for mode, reject, marker, counts, forbidden in (
            ("valid", False, PARENT, ((RETAIN, 1), (RELEASE, 1)), (BAD_LIST, BAD_CHILD)),
            ("bad-list", True, BAD_LIST, (), (RETAIN, RELEASE, PARENT, BAD_CHILD)),
            ("bad-child", True, BAD_CHILD, ((RETAIN, 1), (RELEASE, 1), (PARENT, 1)), (BAD_LIST,)),
        ):
            observer = functools.partial(wire.observe, force_full=True,
                handler=functools.partial(submessage_frame, sub_layout=sub_layout, mode=mode))
            wire.test_case(root, fixture, probe, context, upstream, layout,
                           "full-" + mode, 0, reject, observe_fn=observer,
                           marker=marker, expected_count=1,
                           required_native_counts=counts, forbidden_markers=forbidden)
    print("MRV_SPICE_CANDIDATE_FULL_HEADER_OWNERSHIP_OK", flush=True)


if __name__ == "__main__":
    main()
