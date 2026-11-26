#!/usr/bin/env python3
"""Candidate-only real concurrent Agent and wire buffer budget recovery regression."""
import argparse
import concurrent.futures
from contextlib import ExitStack
import functools
import hashlib
import importlib.util
import json
import os
import socket
import ssl
import struct
import subprocess
import tempfile
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("agent_fixture", HERE / "test-spice-receive-agent.py")
agent = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(agent)
wire = agent.wire
RESERVED = "MRV_NATIVE_RECEIVE_LARGE_RESERVED"
RELEASED = "MRV_NATIVE_RECEIVE_LARGE_RELEASED"
EXHAUSTED = "MRV_NATIVE_RECEIVE_BUDGET_EXHAUSTED"
ALLOC_FAILED = "MRV_NATIVE_RECEIVE_ALLOC_FAILED"
FAULT_INJECTED = "MRV_TEST_ALLOC_FAULT_INJECTED"
AGENT_REJECT = "MRV_NATIVE_AGENT_BUDGET_OR_ALLOC_REJECTED"
WIRE_REJECT = "MRV_NATIVE_WIRE_BUDGET_OR_ALLOC_REJECTED"


def wire_frame(client, server, mini, layout, declared, reject, release):
    # Same authenticated initial-frame control as the single-session wire
    # boundary gate. Keep the real allocation pending without sending a body.
    size, offset = (layout[5], layout[6]) if mini else (layout[7], layout[8])
    header = bytearray(wire.link.read_exact(server, size))
    original = wire.word(header, offset)
    if not 0 < original <= 65536:
        raise ValueError("unexpected initial local server frame size")
    struct.pack_into("<I", header, offset, declared)
    client.sendall(header)
    return hold(client, reject, release)


def hold(client, reject, release):
    deadline = time.monotonic() + (4 if reject else 75)
    consumed = 0
    while time.monotonic() < deadline:
        if not reject and release.is_set():
            return "released-by-test"
        client.settimeout(0.1)
        try:
            data = client.recv(4096)
        except socket.timeout:
            continue
        except (ssl.SSLEOFError, ConnectionResetError):
            data = b""
        if not data:
            if reject:
                return "budget-rejected"
            raise AssertionError("admitted session closed before test released it")
        consumed += len(data)
        if consumed > 1024 * 1024:
            raise ValueError("unexpected local control traffic while holding reservation")
    raise TimeoutError("budget peer did not reach expected closure")


def stop(process):
    if process.poll() is None:
        process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


def test(root, fixture, probe, layout, agent_layout, context, upstream, kind, fault_library=None):
    if kind == "agent":
        maximum = 16 * 1024 * 1024 + 64 * 1024
        expected_reject, other_reject = AGENT_REJECT, WIRE_REJECT
        fixture_args = ("agent-full",)
        server_markers = {"MAIN_INITIALIZED tls=1", "AGENT_CLIENT_CAPS", "AGENT_CAPS_DELIVERED"}
    elif kind == "wire":
        maximum = 128 * 1024 * 1024
        expected_reject, other_reject = WIRE_REJECT, AGENT_REJECT
        fixture_args = ()
        server_markers = {"MAIN_INITIALIZED tls=1"}
    else:
        raise ValueError("unknown budget test kind")
    # For fault tests leave exactly one target allocation of budget free.
    # The seventh peer retries before any admitted peer is released, so a
    # leaked reservation after the injected failure would prevent recovery.
    fault = fault_library is not None
    if fault:
        maximum = maximum if kind == "agent" else 120 * 1024 * 1024
        total = (96 if kind == "agent" else 640) * 1024 * 1024
        fault_size = total - 5 * maximum
        if not 0 < fault_size <= maximum or fault_size == maximum:
            raise AssertionError("invalid distinct allocation-fault size")
    print(f"starting candidate {kind} {'allocation fault' if fault else 'budget'} recovery", flush=True)
    events = [threading.Event() for _ in range(7)]
    futures = {}
    servers = {}
    with ExitStack() as stack:
        pool = stack.enter_context(concurrent.futures.ThreadPoolExecutor(max_workers=7))
        # Release all held relays before joining executor on any error.
        stack.callback(lambda: [event.set() for event in events])
        listeners = [stack.enter_context(socket.socket()) for _ in events]
        for listener in listeners:
            listener.bind(("127.0.0.1", 0))
            listener.listen(1)
        out_path, err_path = root / "probe.stdout", root / "probe.stderr"
        out, err = stack.enter_context(out_path.open("wb")), stack.enter_context(err_path.open("wb"))
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(("DYLD_", "GST_", "OPENSSL_")) and
               k.lower() not in ("http_proxy", "https_proxy", "all_proxy", "no_proxy", "spice_proxy")}
        env.update(PATH="/usr/bin:/bin:/usr/sbin:/sbin", NO_PROXY="127.0.0.1",
                   MRV_ENABLE_INTEGRATION_PROBES="1", MRV_RECEIVE_TEST_TRACE="1")
        env.pop("MRV_TEST_ALLOC_KIND", None)
        if fault:
            # Only the independent unsigned native probe receives the test dylib.
            env.update(DYLD_INSERT_LIBRARIES=str(fault_library), MRV_TEST_ALLOC_KIND=kind)
        native = subprocess.Popen([str(probe), str(root / "trusted.pem"), str(root),
                                   *[str(s.getsockname()[1]) for s in listeners]],
                                  cwd=root, env=env, stdout=out, stderr=err)
        stack.callback(stop, native)

        def lines(path):
            return path.read_text(errors="replace").splitlines()

        def wait_for(predicate, description, seconds=12):
            deadline = time.monotonic() + seconds
            while time.monotonic() < deadline:
                for future in futures.values():
                    if future.done():
                        future.result()
                if predicate():
                    return
                if native.poll() is not None:
                    raise AssertionError("native probe exited early")
                time.sleep(0.025)
            raise AssertionError("timed out: " + description)

        def count(marker):
            return lines(err_path).count(marker)

        def start(index, reject=False):
            with socket.socket() as reserved:
                reserved.bind(("127.0.0.1", 0))
                port = reserved.getsockname()[1]
            log = root / f"server-{index}.log"
            with log.open("wb") as output:
                server = subprocess.Popen([str(fixture), str(port), str(root / "trusted.pem"),
                                           str(root / "server.pem"), str(root / "server.key"),
                                           wire.auth.tls.TICKET, *fixture_args],
                                          stdout=output, stderr=subprocess.STDOUT)
            servers[index] = server, log
            stack.callback(stop, server)
            wait_for(lambda: "READY" in lines(log), "backend ready")
            if kind == "agent":
                handler = functools.partial(agent.agent_frame, agent_layout=agent_layout,
                                            split=True, incomplete=True,
                                            hold=functools.partial(hold, release=events[index]))
            else:
                handler = functools.partial(wire_frame, release=events[index])
            declared = fault_size if fault and index in (5, 6) else maximum
            futures[index] = pool.submit(wire.observe, listeners[index], context, upstream,
                                         port, layout, declared, reject, handler)
            (root / f"start-{index}").touch()
            wait_for(lambda: f"MRV_BUDGET_OPENED peer={index}" in lines(out_path), "native opened")

        def terminal(index):
            return any(line.startswith(f"MRV_BUDGET_TERMINAL peer={index} ") for line in lines(out_path))

        try:
            for index in range(5):
                start(index)
                wait_for(lambda: count(RESERVED) == index + 1, "large reservation")
            if count(RELEASED) or count(EXHAUSTED) or any(f.done() for f in futures.values()):
                raise AssertionError("five admitted reservations were not retained")
            start(5, reject=True)
            if futures[5].result(timeout=6) != "budget-rejected":
                raise AssertionError("sixth session was not rejected")
            wait_for(lambda: "MRV_BUDGET_TERMINAL peer=5 io=1" in lines(out_path), "budget IO error")
            if (count(EXHAUSTED) != int(not fault) or count(expected_reject) != 1 or
                    count(other_reject) or count(ALLOC_FAILED) != int(fault) or
                    count(FAULT_INJECTED) != int(fault) or count(wire.MARKER) or
                    count(agent.DIRECT) or count(agent.FRAGMENT)):
                raise AssertionError("expected matching allocation failure or aggregate denial")
            if count(RESERVED) != 5 or count(RELEASED) or any(futures[i].done() for i in range(5)):
                raise AssertionError("rejection affected admitted sessions")
            if not fault:
                events[0].set()
                if futures[0].result(timeout=5) != "released-by-test":
                    raise AssertionError("first relay not released")
                wait_for(lambda: terminal(0) and count(RELEASED) == 1, "first budget release")
            start(6)
            wait_for(lambda: count(RESERVED) == 6, "recovery reservation")
            retained = (0, 1, 2, 3, 4, 6) if fault else (1, 2, 3, 4, 6)
            if any(futures[i].done() for i in retained):
                raise AssertionError("recovered session or retained session closed early")
            if fault and count(RELEASED):
                raise AssertionError("fault retry did not precede all admitted releases")
            for i in retained:
                events[i].set()
            for i in retained:
                if futures[i].result(timeout=5) != "released-by-test":
                    raise AssertionError("relay cleanup failed")
            wait_for(lambda: all(terminal(i) for i in range(7)) and count(RELEASED) == 6,
                     "all reservations released")
            (root / "finish-0").touch()
            native.wait(timeout=5)
            if native.returncode or "MRV_NATIVE_BUDGET_SESSIONS_OK" not in lines(out_path):
                raise AssertionError("native session lifecycle failed")
            if (count(RESERVED) != 6 or count(RELEASED) != 6 or
                    count(EXHAUSTED) != int(not fault) or count(expected_reject) != 1 or
                    count(other_reject) or count(ALLOC_FAILED) != int(fault) or
                    count(FAULT_INJECTED) != int(fault) or count(wire.MARKER) or
                    count(agent.DIRECT) or count(agent.FRAGMENT)):
                raise AssertionError("final accounting markers mismatch")
            for _, log in servers.values():
                if not server_markers.issubset(lines(log)):
                    raise AssertionError("backend did not complete required handshake")
            suffix = "ALLOC_FAULT_RUNTIME_OK" if fault else "AGGREGATE_RUNTIME_OK"
            print(f"MRV_SPICE_CANDIDATE_{kind.upper()}_{suffix}", flush=True)
        finally:
            print(out_path.read_text(errors="replace")[-6000:])
            print(err_path.read_text(errors="replace")[-6000:])
            for index, (_, log) in servers.items():
                print(f"backend {index}: {log.read_text(errors='replace')[-1500:]}")


def compile_fault_library(app, destination):
    import shlex
    frameworks = app / "Contents/Frameworks"
    glib = frameworks / "libglib-2.0.0.dylib"
    flags = shlex.split(subprocess.check_output(
        ["pkg-config", "--cflags", "glib-2.0"], text=True))
    subprocess.run(["xcrun", "clang", "-std=c11", "-dynamiclib", *flags,
                    str(HERE / "spice-alloc-fault.c"), "-o", str(destination),
                    str(glib), "-Wl,-rpath," + str(frameworks)],
                   check=True, timeout=60)
    linked = subprocess.check_output(["/usr/bin/otool", "-L", str(destination)], text=True)
    print(linked, flush=True)
    if "@rpath/libglib-2.0.0.dylib" not in linked or "/opt/homebrew/" in linked or "/usr/local/" in linked:
        raise AssertionError("fault library must use packaged GLib")
    return destination


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--kind", choices=("agent", "wire"), default="agent")
    parser.add_argument("--alloc-fault", action="store_true")
    args = parser.parse_args()
    app = args.app.resolve()
    report = json.loads((app.parent / "staging-report.json").read_text())
    library = app / "Contents/Frameworks/libspice-client-glib-2.0.8.dylib"
    if hashlib.sha256(library.read_bytes()).hexdigest() != report["candidate_signed_sha256"] or not report["dyld_image_lines"]:
        raise ValueError("candidate identity not verified")
    policy = (HERE / "spice-receive-limits.h").read_text()
    if ("#define MRV_AGENT_TOTAL_MAX ((gsize)(96u * 1024u * 1024u))" not in policy or
            "#define MRV_AGENT_MAX ((guint32)(16u * 1024u * 1024u + 64u * 1024u))" not in policy or
            "#define MRV_WIRE_TOTAL_MAX ((gsize)(640u * 1024u * 1024u))" not in policy or
            "#define MRV_WIRE_MAX ((guint32)(128u * 1024u * 1024u))" not in policy):
        raise ValueError("receive budget policy changed")
    with tempfile.TemporaryDirectory(prefix=f"mrv-{args.kind}-budget-") as raw:
        root = Path(raw)
        fixture, probe, layout_probe = root / "server", root / "probe", root / "layout"
        wire.auth.tls.create_certificates(root)
        wire.auth.compile_fixture(fixture)
        wire.auth.compile_native_probe(app, probe, source="spice-native-budget.c")
        wire.auth.compile_native_probe(app, layout_probe, source="spice-native-receive.c")
        layout = tuple(map(int, subprocess.check_output([str(layout_probe), "--layout"], text=True, timeout=10).split()))
        agent_layout = tuple(map(int, subprocess.check_output([str(layout_probe), "--agent-layout"], text=True, timeout=10).split()))
        if len(layout) != 11 or len(agent_layout) != 6:
            raise ValueError("unexpected installed protocol layout")
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(root / "server.pem", root / "server.key")
        upstream = wire.auth.tls.strict_client_context(root / "trusted.pem")
        fault_library = compile_fault_library(app, root / "alloc-fault.dylib") if args.alloc_fault else None
        test(root, fixture, probe, layout, agent_layout, context, upstream, args.kind, fault_library)


if __name__ == "__main__":
    main()
