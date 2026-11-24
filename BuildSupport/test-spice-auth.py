#!/usr/bin/env python3
"""Real libspice-server ticket authentication, reconnect and TLS-only main channel."""
import argparse
from contextlib import ExitStack
import importlib.util
import os
import re
import shlex
import socket
import subprocess
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("tls_fixture", HERE / "test-loopback-tls.py")
tls = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(tls)


def compile_fixture(destination):
    flags = shlex.split(subprocess.check_output(
        ["pkg-config", "--cflags", "--libs", "spice-server", "glib-2.0"], text=True))
    subprocess.run(["xcrun", "clang", "-std=c11", str(HERE / "spice-auth-fixture.c"),
                    "-o", str(destination), *flags], check=True, timeout=60)


def test_case(app, root, fixture, name, server_ticket, success, display=False):
    with socket.socket() as reserved:
        reserved.bind(("127.0.0.1", 0))
        port = reserved.getsockname()[1]
    # Bind on loopback only. A port collision is an explicit fixture failure.
    profile = root / f"{name}.vv"
    profile.write_text(tls.fixture_profile(port, root / "trusted.pem", tls.SUBJECT))
    log = root / f"{name}.log"
    with log.open("wb") as output:
        command = [str(fixture), str(port), str(root / "trusted.pem"),
                   str(root / "server.pem"), str(root / "server.key"), server_ticket]
        if display:
            command.append("display")
        server = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                if server.poll() is not None:
                    raise RuntimeError(f"{name}: fixture exited before test")
                if "READY" in log.read_text(errors="replace").splitlines():
                    break
                time.sleep(0.05)
            else:
                raise RuntimeError(f"{name}: fixture not ready")
            env = {k: v for k, v in os.environ.items() if not k.startswith(("DYLD_", "GST_", "OPENSSL_"))}
            for key in list(env):
                if key.lower() in ("http_proxy", "https_proxy", "all_proxy", "no_proxy", "spice_proxy"):
                    env.pop(key)
            env["NO_PROXY"] = "127.0.0.1"
            env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
            env["GST_REGISTRY"] = str(root / "gst-registry.bin")
            exe = app / "Contents" / "MacOS" / "Mac Remote Viewer"
            mode = "--loopback-spice-display-probe" if display else "--loopback-spice-auth-probe"
            result = subprocess.run([str(exe), mode, str(profile)],
                                    cwd=root, env=env, capture_output=True, text=True, timeout=45)
            lines = result.stdout.splitlines()
            expected = "MRV_SPICE_DISPLAY_OK" if display else ("MRV_SPICE_AUTH_OK" if success else "MRV_SPICE_AUTH_REJECTED")
            if result.returncode != 0 or expected not in lines:
                print(result.stdout[-6000:])
                print(result.stderr[-6000:])
                raise AssertionError(f"{name}: missing expected auth result")
            if display:
                rounds = [line for line in lines if line.startswith("MRV_SPICE_DISPLAY_ROUND_OK ")]
                if len(rounds) != 2 or any(not line.startswith(f"MRV_SPICE_DISPLAY_ROUND_OK {i} 640x480 first-frame-ms=")
                                           or not line.endswith(" pixels=red,green")
                                           for i, line in enumerate(rounds, 1)):
                    raise AssertionError("did not complete both actual display rounds")
                for line in rounds:
                    print(line)
            if success and not display and [line for line in lines if line.startswith("MRV_SPICE_AUTH_ROUND_OK ")] != [
                    f"MRV_SPICE_AUTH_ROUND_OK {i}" for i in range(1, 4)]:
                raise AssertionError("did not complete all three reconnect rounds")
        finally:
            if server.poll() is None:
                server.terminate()
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait(timeout=5)
            # Always emit bounded fixture logs, including on client assertion/timeout.
            print(f"{name}: fixture exit={server.returncode}")
            print(log.read_text(errors="replace")[-6000:])
        lines = log.read_text(errors="replace").splitlines()
        if server.returncode != 0:
            raise AssertionError(f"{name}: fixture exited abnormally")
        initialized = [line for line in lines if line.startswith("MAIN_INITIALIZED ")]
        if display:
            display_channels = [line for line in lines if line.startswith("DISPLAY_INITIALIZED ")]
            if (display_channels != ["DISPLAY_INITIALIZED tls=1"] * 2
                    or "PRIMARY_CREATED 640x480" not in lines or "VM_STARTED" not in lines):
                raise AssertionError(f"unexpected display channels or lifecycle: {display_channels}")
            counts = [re.fullmatch(r"DRAW_COUNTS submitted=(\d+) consumed=(\d+) released=(\d+)", line)
                      for line in lines if line.startswith("DRAW_COUNTS ")]
            if len(counts) != 1 or counts[0] is None:
                raise AssertionError("missing QXL worker counters")
            submitted, consumed, released = map(int, counts[0].groups())
            if not 0 < consumed <= submitted or not 0 <= released <= consumed:
                raise AssertionError(f"invalid QXL worker counters: {submitted}/{consumed}/{released}")
        if success and initialized != ["MAIN_INITIALIZED tls=1"] * (2 if display else 3):
            raise AssertionError(f"{name}: unexpected TLS main-channel initializations: {initialized}")
        if not success and initialized:
            raise AssertionError(f"{name}: rejected ticket initialized a channel")
        print(f"{name}: authenticated TLS main channels={len(initialized)}")


def test_multi(app, root, fixture):
    """Four simultaneous servers with non-overlapping color pairs."""
    servers = []
    profiles = []
    logs = []
    with ExitStack() as stack:
        # Keep four port reservations until all distinct ports have been chosen.
        reservations = [stack.enter_context(socket.socket()) for _ in range(4)]
        for sock in reservations:
            sock.bind(("127.0.0.1", 0))
        ports = [sock.getsockname()[1] for sock in reservations]
        for sock in reservations:
            sock.close()
        try:
            for i, port in enumerate(ports):
                profile = root / f"multi-{i}.vv"
                profile.write_text(tls.fixture_profile(port, root / "trusted.pem", tls.SUBJECT))
                profiles.append(profile)
                log = root / f"multi-{i}.log"
                logs.append(log)
                output = stack.enter_context(log.open("wb"))
                server = subprocess.Popen([
                    str(fixture), str(port), str(root / "trusted.pem"),
                    str(root / "server.pem"), str(root / "server.key"), tls.TICKET,
                    "display", str(i),
                ], stdout=output, stderr=subprocess.STDOUT)
                servers.append(server)
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                if any(server.poll() is not None for server in servers):
                    raise RuntimeError("multi: fixture exited before ready")
                if all("READY" in log.read_text(errors="replace").splitlines() for log in logs):
                    break
                time.sleep(0.05)
            else:
                raise RuntimeError("multi: fixtures not ready")
            env = {k: v for k, v in os.environ.items() if not k.startswith(("DYLD_", "GST_", "OPENSSL_"))}
            for key in list(env):
                if key.lower() in ("http_proxy", "https_proxy", "all_proxy", "no_proxy", "spice_proxy"):
                    env.pop(key)
            env["NO_PROXY"] = "127.0.0.1"
            env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
            env["GST_REGISTRY"] = str(root / "gst-registry.bin")
            exe = app / "Contents" / "MacOS" / "Mac Remote Viewer"
            env["MRV_GLIB_TRACE"] = "1"
            library = app / "Contents" / "Frameworks" / "libspice-client-glib-2.0.8.dylib"
            if library.is_file():
                symbols = subprocess.run(["/usr/bin/nm", "-u", str(library)],
                                         capture_output=True, text=True, timeout=15, check=True)
                candidates = [line for line in symbols.stdout.splitlines()
                              if any(term in line for term in ("context", "longjmp", "setjmp", "g_thread_new"))]
                print("MRV_COROUTINE_IMPORTS")
                print("\n".join(candidates)[:6000])
            result = subprocess.run([str(exe), "--loopback-spice-multi-probe",
                                     *map(str, profiles)], cwd=root, env=env,
                                    capture_output=True, text=True, timeout=75)
            print(result.stdout[-12000:])
            if result.stderr:
                print(result.stderr[-16000:])
            if result.returncode:
                raise AssertionError(f"multi: client failed (exit={result.returncode})")
            if "MRV_GLIB_CRITICAL" in result.stderr or "CRITICAL GLib" in result.stdout:
                raise AssertionError("multi: GLib critical during concurrent sessions")
            lines = result.stdout.splitlines()
            phases = [line for line in lines if line.startswith("MRV_MULTI_PHASE_OK ")]
            if phases != [f"MRV_MULTI_PHASE_OK active={i} live=4 targets=60,15" for i in range(4)]:
                raise AssertionError("multi: missing foreground/background phases")
            if "MRV_MULTI_CLOSE_OK live=3" not in lines or "MRV_MULTI_OK" not in lines:
                raise AssertionError("multi: missing close/isolation success")
        finally:
            # Give the peer disconnects a bounded interval to drain on each
            # fixture's GLib loop before requesting orderly VM shutdown.
            time.sleep(0.5)
            for server in servers:
                if server.poll() is None:
                    server.terminate()
            for server, log in zip(servers, logs):
                try:
                    server.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait(timeout=5)
                print(f"{log.stem}: exit={server.returncode}")
                print(log.read_text(errors="replace")[-4000:])
        for server, log in zip(servers, logs):
            lines = log.read_text(errors="replace").splitlines()
            if server.returncode != 0:
                raise AssertionError(f"{log.stem}: abnormal exit")
            for channel in ("MAIN", "DISPLAY"):
                initialized = [line for line in lines if line.startswith(f"{channel}_INITIALIZED ")]
                if initialized != [f"{channel}_INITIALIZED tls=1"]:
                    raise AssertionError(f"{log.stem}: unexpected channels: {initialized}")
            counts = [re.fullmatch(r"DRAW_COUNTS submitted=(\d+) consumed=(\d+) released=(\d+)", line)
                      for line in lines if line.startswith("DRAW_COUNTS ")]
            if len(counts) != 1 or counts[0] is None:
                raise AssertionError(f"{log.stem}: missing counters")
            submitted, consumed, released = map(int, counts[0].groups())
            if not 0 < consumed <= submitted or not 0 <= released <= consumed:
                raise AssertionError(f"{log.stem}: invalid draw lifecycle")
    print("Real four-session display isolation checks passed.")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="mrv-spice-auth-") as raw:
        root = Path(raw)
        tls.create_certificates(root)
        fixture = root / "spice-auth-fixture"
        compile_fixture(fixture)
        test_case(args.app.resolve(), root, fixture, "valid-ticket", tls.TICKET, True)
        test_case(args.app.resolve(), root, fixture, "wrong-ticket", "mrv-ci-other-ticket", False)
        test_case(args.app.resolve(), root, fixture, "display", tls.TICKET, True, display=True)
        test_multi(args.app.resolve(), root, fixture)
    print("Real SPICE ticket authentication and reconnect checks passed.")


if __name__ == "__main__":
    main()
