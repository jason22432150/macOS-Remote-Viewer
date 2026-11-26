#!/usr/bin/env python3
"""Candidate-only TLS loopback regression for the native link reply size policy."""
import argparse
import concurrent.futures
import importlib.util
import os
import re
import socket
import ssl
import struct
import subprocess
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("tls_fixture", HERE / "test-loopback-tls.py")
tls = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(tls)
LINK = struct.Struct("<4sIII")


def limit():
    # Intentionally fail if policy syntax changes rather than silently using
    # an obsolete limit in the runtime boundary regression.
    source = (HERE / "spice-receive-limits.h").read_text()
    if "#define MRV_LINK_MAX ((guint32)(1024u * 1024u))" not in source:
        raise ValueError("link policy changed; update boundary fixture")
    return 1024 * 1024


def read_exact(peer, size):
    result = bytearray()
    while len(result) < size:
        chunk = peer.recv(size - len(result))
        if not chunk:
            raise ValueError("incomplete client link")
        result.extend(chunk)
    return bytes(result)


def serve(listener, context, declared, reject):
    listener.settimeout(8)
    peer, address = listener.accept()
    if address[0] != "127.0.0.1":
        peer.close()
        raise ValueError("non-loopback fixture peer")
    with peer:
        peer.settimeout(5)
        with context.wrap_socket(peer, server_side=True) as channel:
            magic, major, minor, size = LINK.unpack(read_exact(channel, LINK.size))
            if magic != b"REDQ" or not 0 < size <= 65536:
                raise ValueError("unexpected client link request")
            read_exact(channel, size)
            channel.sendall(LINK.pack(magic, major, minor, declared))
            # No reply body is sent in either case. The accepted-limit
            # control must wait for the body; rejection must close first.
            start = time.monotonic()
            channel.settimeout(4 if reject else 0.75)
            try:
                data = channel.recv(1)
            except socket.timeout:
                if reject:
                    raise AssertionError("oversized link was not rejected before body")
                return {"waited_for_body": True, "closed": False}
            except (ssl.SSLEOFError, ConnectionResetError):
                data = b""
            if data:
                raise AssertionError("unexpected client application bytes after link header")
            if not reject:
                raise AssertionError("accepted-limit control closed before body")
            return {"waited_for_body": False, "closed": True,
                    "close_seconds": round(time.monotonic() - start, 3)}


def test_case(app, root, context, name, declared, reject, trace=True):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        profile = root / (name + ".vv")
        profile.write_text(tls.fixture_profile(listener.getsockname()[1],
                                               root / "trusted.pem", tls.SUBJECT))
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(("DYLD_", "GST_", "OPENSSL_"))}
        for key in list(env):
            if key.lower() in ("http_proxy", "https_proxy", "all_proxy", "no_proxy", "spice_proxy"):
                env.pop(key)
        env.update(NO_PROXY="127.0.0.1", PATH="/usr/bin:/bin:/usr/sbin:/sbin",
                   MRV_ENABLE_INTEGRATION_PROBES="1")
        env.pop("G_DEBUG", None)
        env.pop("MRV_RECEIVE_TEST_TRACE", None)
        if trace:
            env["MRV_RECEIVE_TEST_TRACE"] = "1"
        executable = app / "Contents" / "MacOS" / "Mac Remote Viewer"
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
            observed = pool.submit(serve, listener, context, declared, reject)
            result = subprocess.run([str(executable), "--loopback-tls-probe", str(profile)],
                                    cwd=root, env=env, capture_output=True, text=True, timeout=25)
            outcome = observed.result(timeout=10)
        diagnostic = "MRV_NATIVE_LINK_LIMIT_REJECTED"
        expected_count = int(reject and trace)
        marker_count = result.stderr.splitlines().count(diagnostic)
        print(f"{name}: {outcome}, native_limit_markers={marker_count}", flush=True)
        if result.returncode != 0 or "MRV_TLS_PROBE_TERMINAL" not in result.stdout.splitlines():
            print(result.stdout[-4000:])
            print(result.stderr[-4000:])
            raise AssertionError(f"{name}: expected terminal client state")
        if marker_count != expected_count:
            print(result.stdout[-4000:])
            print(result.stderr[-4000:])
            raise AssertionError(f"{name}: expected {expected_count} native receive-limit markers, got {marker_count}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True, type=Path)
    args = parser.parse_args()
    app = args.app.resolve()
    # Refuse execution against a baseline app: staging evidence is required.
    import json
    report = json.loads((app.parent / "staging-report.json").read_text())
    import hashlib
    library = app / "Contents/Frameworks/libspice-client-glib-2.0.8.dylib"
    with library.open("rb") as handle:
        actual = hashlib.file_digest(handle, "sha256").hexdigest()
    if actual != report["candidate_signed_sha256"] or not report["dyld_image_lines"]:
        raise ValueError("candidate staging identity not verified")
    maximum = limit()
    with tempfile.TemporaryDirectory(prefix="mrv-native-link-limit-") as raw:
        root = Path(raw)
        tls.create_certificates(root)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(root / "server.pem", root / "server.key")
        test_case(app, root, context, "link-at-limit", maximum, False)
        test_case(app, root, context, "link-over-limit", maximum + 1, True)
        test_case(app, root, context, "link-over-limit-no-trace", maximum + 1, True, trace=False)
        test_case(app, root, context, "link-at-limit-after-rejection", maximum, False)
    print("MRV_SPICE_CANDIDATE_LINK_RECEIVE_BOUNDARY_OK", flush=True)


if __name__ == "__main__":
    main()
