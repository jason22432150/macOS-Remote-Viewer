#!/usr/bin/env python3
"""Candidate-only Agent receive regression via the existing authenticated loopback fixture."""
import argparse
import functools
import hashlib
import importlib.util
import json
import select
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
DIRECT = "MRV_NATIVE_AGENT_DIRECT_LIMIT_REJECTED"
FRAGMENT = "MRV_NATIVE_AGENT_FRAGMENT_LIMIT_REJECTED"
REASSEMBLED = "MRV_NATIVE_AGENT_REASSEMBLED"
DELIVERED = "MRV_NATIVE_AGENT_DIRECT_DELIVERED"


def read_mini_frame(peer, mini_size, type_offset, size_offset, frame_index):
    if (mini_size, type_offset, size_offset) != (6, 0, 2):
        raise ValueError("unexpected installed packed mini-header layout")
    header = bytearray(wire.link.read_exact(peer, mini_size))
    kind = struct.unpack_from("<H", header, type_offset)[0]
    size = wire.word(header, size_offset)
    if frame_index <= 32:
        print(f"agent relay frame={frame_index} type={kind} size={size}", flush=True)
    if not kind or size > 65536:
        raise ValueError(f"invalid local agent fixture framing at frame {frame_index}: type={kind}, size={size}")
    return header, kind, wire.link.read_exact(peer, size)


def agent_frame(client, server, mini, layout, declared, reject, agent_layout, split):
    msg_type, agent_size, agent_offset, type_offset, mini_size = agent_layout
    if not mini or mini_size != layout[5]:
        raise ValueError("agent fixture requires negotiated mini-header")
    size_offset = layout[6]
    deadline = time.monotonic() + 8
    transferred = 0
    frame_index = 0
    while time.monotonic() < deadline:
        # Forward ordinary authenticated main-channel traffic in both directions.
        if client.pending() or select.select([client], [], [], 0)[0]:
            data = client.recv(4096)
            if not data:
                raise AssertionError("client closed before agent message")
            server.sendall(data)
            transferred += len(data)
        if not server.pending() and not select.select([server], [], [], 0.05)[0]:
            continue
        frame_index += 1
        header, kind, body = read_mini_frame(server, mini_size, type_offset, size_offset, frame_index)
        transferred += len(body) + mini_size
        if transferred > 1024 * 1024 or frame_index > 256:
            raise ValueError("unexpected local fixture traffic")
        if kind != msg_type:
            client.sendall(header + body)
            continue
        if len(body) <= agent_size or wire.word(body, agent_offset) != len(body) - agent_size:
            raise ValueError("expected complete synthetic agent capability message")
        if reject:
            body = bytearray(body[:agent_size])
            struct.pack_into("<I", body, agent_offset, declared)
        parts = [body[:agent_size // 2], body[agent_size // 2:]] if split else [body]
        for part in parts:
            struct.pack_into("<I", header, size_offset, len(part))
            client.sendall(header + part)
        break
    else:
        raise TimeoutError("local fixture did not deliver agent data")

    start = time.monotonic()
    deadline = start + (4 if reject else 0.75)
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
                raise AssertionError("legal agent reassembly closed early")
            return {"split": split, "closed": True,
                    "close_seconds": round(time.monotonic() - start, 3)}
        transferred += len(data)
        if transferred > 1024 * 1024:
            raise ValueError("unexpected local fixture traffic")
    if reject:
        raise AssertionError("agent limit did not close before body")
    return {"split": split, "closed": False, "waited": True}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True, type=Path)
    args = parser.parse_args()
    app = args.app.resolve()
    report = json.loads((app.parent / "staging-report.json").read_text())
    library = app / "Contents/Frameworks/libspice-client-glib-2.0.8.dylib"
    if hashlib.sha256(library.read_bytes()).hexdigest() != report["candidate_signed_sha256"] or not report["dyld_image_lines"]:
        raise ValueError("candidate identity not verified")
    policy = (HERE / "spice-receive-limits.h").read_text()
    if "#define MRV_AGENT_MAX ((guint32)(16u * 1024u * 1024u + 64u * 1024u))" not in policy:
        raise ValueError("agent policy changed")
    maximum = 16 * 1024 * 1024 + 64 * 1024
    with tempfile.TemporaryDirectory(prefix="mrv-agent-limit-") as raw:
        root = Path(raw)
        fixture, probe = root / "server", root / "probe"
        wire.auth.tls.create_certificates(root)
        wire.auth.compile_fixture(fixture)
        wire.auth.compile_native_probe(app, probe, source="spice-native-receive.c")
        layout = tuple(map(int, subprocess.check_output([str(probe), "--layout"], text=True, timeout=10).split()))
        agent_layout = tuple(map(int, subprocess.check_output([str(probe), "--agent-layout"], text=True, timeout=10).split()))
        if len(layout) != 11 or len(agent_layout) != 5:
            raise ValueError("unexpected installed protocol layout")
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(root / "server.pem", root / "server.key")
        upstream = wire.auth.tls.strict_client_context(root / "trusted.pem")
        print(f"wire layout={layout}; agent layout={agent_layout}", flush=True)
        for name, split, reject, marker in (
            ("agent-valid-direct", False, False, DELIVERED),
            ("agent-valid-fragment", True, False, REASSEMBLED),
            ("agent-direct-reject", False, True, DIRECT),
            ("agent-fragment-reject", True, True, FRAGMENT),
        ):
            observer = functools.partial(wire.observe, handler=functools.partial(
                agent_frame, agent_layout=agent_layout, split=split))
            wire.test_case(root, fixture, probe, context, upstream, layout, name,
                           maximum + 1, reject, observe_fn=observer,
                           fixture_args=("agent-full",), marker=marker, expected_count=1,
                           forbidden_markers=tuple(m for m in (DIRECT, FRAGMENT, REASSEMBLED, DELIVERED) if m != marker),
                           required_server_markers=("AGENT_CLIENT_CAPS", "AGENT_CAPS_DELIVERED"))
    print("MRV_SPICE_CANDIDATE_AGENT_RECEIVE_BOUNDARY_OK", flush=True)


if __name__ == "__main__":
    main()
