#!/usr/bin/env python3
"""Mount the exact artifact read-only, verify its contents and optionally smoke-test a copy."""
import argparse
import hashlib
import importlib.util
import json
import os
import plistlib
import subprocess
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("validate_sbom", HERE / "validate-sbom.py")
validator = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(validator)

APP_NAME = "Mac Remote Viewer.app"


def run(*args, timeout=120):
    subprocess.run(args, check=True, timeout=timeout)


def sha256(path):
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def verify_mounted(mount, bom_path):
    app = mount / APP_NAME
    if not app.is_dir() or app.is_symlink():
        raise ValueError("missing or invalid app bundle")
    link = mount / "Applications"
    if not link.is_symlink() or os.readlink(link) != "/Applications":
        raise ValueError("invalid Applications shortcut")
    if not (mount / "如何開啟.txt").is_file() or not (mount / "NOTICE.md").is_file():
        raise ValueError("missing installation instructions or notices")
    if sha256(mount / "bom.json") != sha256(bom_path):
        raise ValueError("embedded SBOM differs from published SBOM")
    bom = json.loads(bom_path.read_text())
    with (app / "Contents" / "Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    if info["CFBundleShortVersionString"] != bom["metadata"]["component"]["version"]:
        raise ValueError("app version differs from SBOM")
    validator.verify_inventory(bom, app)
    config = app / "Contents" / "Resources" / "mrv-openssl.cnf"
    modules = app / "Contents" / "Resources" / "ossl-modules"
    if (config.is_symlink() or not config.is_file()
            or config.read_bytes() != b"# Mac Remote Viewer portable OpenSSL configuration\n"
            or modules.is_symlink() or not modules.is_dir()):
        raise ValueError("missing or unexpected portable OpenSSL runtime")
    run("codesign", "--verify", "--deep", "--strict", str(app))
    return app


def smoke_test(app, temp):
    # Run a copied app, not the original mounted image or an existing installed app.
    copied = temp / APP_NAME
    run("ditto", str(app), str(copied))
    run("codesign", "--verify", "--deep", "--strict", str(copied))
    executable = copied / "Contents" / "MacOS" / "Mac Remote Viewer"
    env = os.environ.copy()
    for key in list(env):
        if key.startswith(("DYLD_", "GST_", "OPENSSL_")):
            del env[key]
    env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    env["GST_REGISTRY"] = str(temp / "gst-registry.bin")
    env.pop("MRV_ENABLE_INTEGRATION_PROBES", None)
    # Test the actual packaged executable, not a mocked launch policy.
    for arguments, opted_in in [
        (["--startup-smoke-test"], False),
        (["--loopback-spice-auth-probe", "not-read.vv"], False),
        (["--startup-smoke-test", "extra"], True),
        (["--startup-smoke-test", "--scanout-runtime-probe"], True),
        (["--loopback-tls-probe"], True),
    ]:
        denied_env = dict(env)
        if opted_in:
            denied_env["MRV_ENABLE_INTEGRATION_PROBES"] = "1"
        denied = subprocess.run([str(executable), *arguments], cwd=temp, env=denied_env,
                                capture_output=True, text=True, timeout=15)
        markers = [line for line in denied.stdout.splitlines() if line.startswith("MRV_")]
        if denied.returncode != 2 or markers != ["MRV_PROBE_LAUNCH_DENIED"]:
            raise ValueError(f"probe launch was not rejected: exit={denied.returncode}, markers={markers}")
    print("MRV_PROBE_LAUNCH_GATE_OK")
    env["MRV_ENABLE_INTEGRATION_PROBES"] = "1"
    def startup_smoke(test_env):
        completed = subprocess.run([str(executable), "--startup-smoke-test"],
                                   cwd=temp, env=test_env, capture_output=True, text=True, timeout=40)
        lines = completed.stdout.splitlines()
        if (completed.returncode != 0 or lines.count("MRV_STARTUP_SMOKE_OK") != 1
                or lines.count("MRV_GST_REGISTRY_OK") != 1
                or "MRV_GST_REGISTRY_FAILED" in lines):
            print(completed.stdout[-4000:])
            print(completed.stderr[-4000:])
            raise ValueError(f"startup/registry smoke failed: exit {completed.returncode}")

    startup_smoke(env)
    print("AppKit/Metal/worker startup smoke passed.")

    # A second launch deliberately supplies external paths and a scanner trap.
    # The trap is a harmless local test executable; it must never run.
    poison = temp / "external-gst"
    poison.mkdir()
    scanner = poison / "scanner"
    scanner.write_text('#!/bin/sh\nprintf invoked > "$MRV_TEST_SCANNER_SENTINEL"\nexit 1\n')
    scanner.chmod(0o700)
    sentinel = poison / "scanner-invoked"
    registry = poison / "registry.bin"
    registry.write_bytes(b"synthetic external cache")
    poisoned_env = dict(env, MRV_TEST_SCANNER_SENTINEL=str(sentinel))
    for key in ("GST_PLUGIN_PATH", "GST_PLUGIN_PATH_1_0",
                "GST_PLUGIN_SYSTEM_PATH", "GST_PLUGIN_SYSTEM_PATH_1_0"):
        poisoned_env[key] = str(poison)
    for key in ("GST_PLUGIN_SCANNER", "GST_PLUGIN_SCANNER_1_0"):
        poisoned_env[key] = str(scanner)
    for key in ("GST_REGISTRY", "GST_REGISTRY_1_0"):
        poisoned_env[key] = str(registry)
    poisoned_env.update(GST_REGISTRY_MODE="0666", GST_REGISTRY_UPDATE="no")
    startup_smoke(poisoned_env)
    if sentinel.exists() or registry.read_bytes() != b"synthetic external cache":
        raise ValueError("external scanner or registry was used")
    print("MRV_GST_ENV_ISOLATION_OK")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("dmg", type=Path)
    parser.add_argument("--bom", required=True, type=Path)
    parser.add_argument("--smoke", action="store_true")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="mrv-dmg-") as raw:
        temp = Path(raw)
        mount = temp / "mounted"
        mount.mkdir()
        attached = False
        try:
            run("hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen",
                "-mountpoint", str(mount), str(args.dmg.resolve()))
            attached = True
            app = verify_mounted(mount, args.bom.resolve())
            print("Mounted DMG contents, code signature and SBOM verified.")
            if args.smoke:
                smoke_test(app, temp)
        finally:
            if attached:
                run("hdiutil", "detach", str(mount))


if __name__ == "__main__":
    main()
