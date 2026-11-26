#!/usr/bin/env python3
"""Test-only authenticated wire receive policy against a local SPICE fixture."""
import argparse
import concurrent.futures
import hashlib
import importlib.util
import json
import os
import select
import socket
import ssl
import struct
import subprocess
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, HERE / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


auth = load("auth_fixture", "test-spice-auth.py")
link = load("link_fixture", "test-spice-receive-link.py")
LINK = link.LINK
MARKER = "MRV_NATIVE_WIRE_LIMIT_REJECTED"


def word(data, offset):
    if not 0 <= offset <= len(data) - 4:
        raise ValueError("invalid capability offset")
    return struct.unpack_from("<I", data, offset)[0]


def capability(body, count_offset, caps_offset, bit):
    count, offset = word(body, count_offset), word(body, caps_offset)
    if count > 32 or offset > len(body) or count * 4 > len(body) - offset:
        raise ValueError("invalid fixture capabilities")
    return bit // 32 < count and bool(word(body, offset + 4 * (bit // 32)) & (1 << (bit % 32)))


def relay_link(source, destination):
    header = link.read_exact(source, LINK.size)
    magic, _, _, size = LINK.unpack(header)
    if magic != b"REDQ" or not 0 < size <= 65536:
        raise ValueError("invalid local fixture link")
    body = link.read_exact(source, size)
    destination.sendall(header + body)
    return body


def forward_auth(client, server):
    # Forward the small real ticket exchange without interpreting the ticket
    # or assuming a particular RSA ciphertext length. Only the four-byte
    # server authentication result is consumed here, before any frame.
    deadline = time.monotonic() + 5
    forwarded = 0
    while time.monotonic() < deadline:
        if server.pending() or select.select([server], [], [], 0)[0]:
            result = link.read_exact(server, 4)
            if word(result, 0) != 0 or not forwarded:
                raise AssertionError("local fixture authentication failed")
            client.sendall(result)
            return
        if client.pending() or select.select([client], [], [], 0.05)[0]:
            data = client.recv(4096)
            if not data:
                raise AssertionError("client closed during ticket exchange")
            forwarded += len(data)
            if forwarded > 4096:
                raise ValueError("unexpected local ticket exchange length")
            server.sendall(data)
    raise TimeoutError("local ticket exchange did not finish")


def observe(listener, client_context, server_context, backend_port, layout, declared, reject):
    listener.settimeout(8)
    raw, address = listener.accept()
    with raw:
        if address[0] != "127.0.0.1":
            raise ValueError("non-loopback client")
        raw.settimeout(5)
        with client_context.wrap_socket(raw, server_side=True) as client:
            with socket.create_connection(("127.0.0.1", backend_port), timeout=5) as upstream:
                with server_context.wrap_socket(upstream, server_hostname="mrv-ci.test") as server:
                    (link_size, client_count, client_offset, server_count, server_offset,
                     mini_size, mini_offset, full_size, full_offset, mini_bit, _) = layout
                    if link_size != LINK.size:
                        raise ValueError("unexpected installed link layout")
                    request = relay_link(client, server)
                    reply = relay_link(server, client)
                    if word(reply, 0) != 0:
                        raise AssertionError("local link rejected")
                    mini = (capability(request, client_count, client_offset, mini_bit) and
                            capability(reply, server_count, server_offset, mini_bit))
                    forward_auth(client, server)
                    size, offset = (mini_size, mini_offset) if mini else (full_size, full_offset)
                    header = bytearray(link.read_exact(server, size))
                    original = word(header, offset)
                    if not 0 < original <= 65536:
                        raise ValueError("unexpected initial server frame size")
                    struct.pack_into("<I", header, offset, declared)
                    client.sendall(header)
                    # Never forward the large declared body. Permit ordinary
                    # client control frames already queued after auth.
                    start = time.monotonic()
                    deadline = start + (4 if reject else 0.75)
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
                            if not reject:
                                raise AssertionError("accepted boundary closed before body")
                            return {"mini_header": mini, "closed": True,
                                    "close_seconds": round(time.monotonic() - start, 3)}
                        consumed += len(data)
                        if consumed > 65536:
                            raise ValueError("unexpected client control traffic")
                    if reject:
                        raise AssertionError("wire limit did not close before body")
                    return {"mini_header": mini, "closed": False, "waited_for_body": True}


def test_case(root, fixture, probe, context, upstream_context, layout, name, declared, reject):
    with socket.socket() as reserved:
        reserved.bind(("127.0.0.1", 0))
        backend_port = reserved.getsockname()[1]
    log = root / (name + ".log")
    with log.open("wb") as output, socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        server = subprocess.Popen([str(fixture), str(backend_port), str(root / "trusted.pem"),
                                   str(root / "server.pem"), str(root / "server.key"),
                                   auth.tls.TICKET], stdout=output, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 10
            while "READY" not in log.read_text(errors="replace").splitlines():
                if server.poll() is not None or time.monotonic() >= deadline:
                    raise RuntimeError("local server not ready")
                time.sleep(0.05)
            env = {k: v for k, v in os.environ.items()
                   if not k.startswith(("DYLD_", "GST_", "OPENSSL_")) and
                   k.lower() not in ("http_proxy", "https_proxy", "all_proxy", "no_proxy", "spice_proxy")}
            env.update(PATH="/usr/bin:/bin:/usr/sbin:/sbin", NO_PROXY="127.0.0.1",
                       MRV_ENABLE_INTEGRATION_PROBES="1", MRV_RECEIVE_TEST_TRACE="1")
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                future = pool.submit(observe, listener, context, upstream_context, backend_port,
                                     layout, declared, reject)
                result = subprocess.run([str(probe), str(root / "trusted.pem"),
                                         str(listener.getsockname()[1]), "reject" if reject else "control"],
                                        cwd=root, env=env, capture_output=True, text=True, timeout=20)
                try:
                    outcome = future.result(timeout=10)
                except Exception:
                    print(f"native probe exit={result.returncode}", flush=True)
                    print(result.stdout[-4000:])
                    print(result.stderr[-4000:])
                    raise
            count = result.stderr.splitlines().count(MARKER)
            print(f"{name}: {outcome}, native_markers={count}", flush=True)
            print(result.stdout[-4000:])
            if result.returncode or "MRV_NATIVE_WIRE_TERMINAL_OK" not in result.stdout.splitlines() or count != int(reject):
                print(result.stderr[-4000:])
                raise AssertionError("native wire result did not match policy")
            if "MAIN_INITIALIZED tls=1" not in log.read_text(errors="replace").splitlines():
                raise AssertionError("backend did not authenticate TLS main channel")
        finally:
            if server.poll() is None:
                server.terminate()
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait(timeout=5)
            print(log.read_text(errors="replace")[-4000:])
        if server.returncode:
            raise AssertionError("local server exited abnormally")


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
    with tempfile.TemporaryDirectory(prefix="mrv-wire-limit-") as raw:
        root = Path(raw)
        fixture, probe = root / "server", root / "probe"
        auth.tls.create_certificates(root)
        auth.compile_fixture(fixture)
        auth.compile_native_probe(app, probe, source="spice-native-receive.c")
        layout = tuple(map(int, subprocess.check_output([str(probe), "--layout"], text=True, timeout=10).split()))
        if len(layout) != 11:
            raise ValueError("unexpected protocol layout evidence")
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(root / "server.pem", root / "server.key")
        upstream_context = auth.tls.strict_client_context(root / "trusted.pem")
        test_case(root, fixture, probe, context, upstream_context, layout,
                  "wire-at-limit", maximum, False)
        test_case(root, fixture, probe, context, upstream_context, layout,
                  "wire-over-limit", maximum + 1, True)
    print("MRV_SPICE_CANDIDATE_WIRE_RECEIVE_BOUNDARY_OK", flush=True)


if __name__ == "__main__":
    main()
