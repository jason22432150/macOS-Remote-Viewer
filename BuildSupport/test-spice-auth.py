#!/usr/bin/env python3
"""Real libspice-server ticket authentication, reconnect and TLS-only main channel."""
import argparse
import importlib.util
import os
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


def test_case(app, root, fixture, name, server_ticket, success):
    with socket.socket() as reserved:
        reserved.bind(("127.0.0.1", 0))
        port = reserved.getsockname()[1]
    # Bind on loopback only. A port collision is an explicit fixture failure.
    profile = root / f"{name}.vv"
    profile.write_text(tls.fixture_profile(port, root / "trusted.pem", tls.SUBJECT))
    log = root / f"{name}.log"
    with log.open("wb") as output:
        server = subprocess.Popen([str(fixture), str(port), str(root / "trusted.pem"),
                                   str(root / "server.pem"), str(root / "server.key"), server_ticket],
                                  stdout=output, stderr=subprocess.STDOUT)
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
            result = subprocess.run([str(exe), "--loopback-spice-auth-probe", str(profile)],
                                    cwd=root, env=env, capture_output=True, text=True, timeout=40)
            lines = result.stdout.splitlines()
            expected = "MRV_SPICE_AUTH_OK" if success else "MRV_SPICE_AUTH_REJECTED"
            if result.returncode != 0 or expected not in lines:
                print(result.stdout[-2000:])
                print(result.stderr[-2000:])
                raise AssertionError(f"{name}: missing expected auth result")
            if success and [line for line in lines if line.startswith("MRV_SPICE_AUTH_ROUND_OK ")] != [
                    f"MRV_SPICE_AUTH_ROUND_OK {i}" for i in range(1, 4)]:
                raise AssertionError("did not complete all three reconnect rounds")
        finally:
            server.terminate()
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait(timeout=5)
        lines = log.read_text(errors="replace").splitlines()
        initialized = [line for line in lines if line.startswith("MAIN_INITIALIZED ")]
        if success and initialized != ["MAIN_INITIALIZED tls=1"] * 3:
            raise AssertionError(f"{name}: expected three TLS main-channel initializations: {initialized}")
        if not success and initialized:
            raise AssertionError(f"{name}: rejected ticket initialized a channel")
        print(f"{name}: authenticated TLS main channels={len(initialized)}")


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
    print("Real SPICE ticket authentication and reconnect checks passed.")


if __name__ == "__main__":
    main()
