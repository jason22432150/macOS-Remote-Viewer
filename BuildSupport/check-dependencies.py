#!/usr/bin/env python3
"""Check the active Homebrew keg against the direct dependency lock; never mutate Homebrew."""
import argparse
import json
import platform
import subprocess
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def capture(*args):
    return subprocess.check_output(args, text=True).strip()

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--strict", action="store_true")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    with (ROOT / "BuildSupport/lockfile.toml").open("rb") as handle:
        lock = tomllib.load(handle)
    entries = {}
    mismatches = []
    for key in ("spice_gtk", "glib", "gstreamer"):
        item = lock[key]
        formula = item["formula"]
        active = Path(capture("brew", "--prefix", formula)).resolve()
        actual = active.name
        expected = item["version"]
        entries[formula] = {"expected": expected, "active": actual, "keg": str(active)}
        if actual != expected or not active.is_dir():
            mismatches.append(f"{formula}: expected {expected}, active {actual}")
    manifest = {
        "architecture": platform.machine(),
        "macos": platform.mac_ver()[0],
        "xcode": capture("xcodebuild", "-version"),
        "sdk": capture("xcrun", "--sdk", "macosx", "--show-sdk-version"),
        "cocoaspice_revision": lock["cocoaspice"]["revision"],
        "direct_dependencies": entries,
        "installed_formulae": capture("brew", "list", "--formula", "--versions").splitlines(),
        "mismatches": mismatches,
    }
    result = json.dumps(manifest, indent=2, ensure_ascii=False) + "\n"
    print(result, end="")
    if args.output:
        args.output.write_text(result, encoding="utf-8")
    if mismatches:
        print("Native dependency version drift detected", file=sys.stderr)
    return 1 if args.strict and mismatches else 0

if __name__ == "__main__":
    sys.exit(main())
