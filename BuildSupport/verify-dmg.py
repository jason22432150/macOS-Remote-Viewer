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
    completed = subprocess.run([str(executable), "--startup-smoke-test"],
                               cwd=temp, env=env, capture_output=True, text=True, timeout=40)
    if completed.returncode != 0 or "MRV_STARTUP_SMOKE_OK" not in completed.stdout.splitlines():
        print(completed.stdout[-4000:])
        print(completed.stderr[-4000:])
        raise ValueError(f"startup smoke failed: exit {completed.returncode}")
    print("AppKit/Metal/worker startup smoke passed.")


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
