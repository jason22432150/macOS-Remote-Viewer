#!/usr/bin/env python3
"""Archive installed-keg recipe evidence, not a license or source conclusion."""
import argparse
import ctypes
import hashlib
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

audit = load("audit_dependencies", "audit-dependencies.py")
build = load("build_spice_candidate", "build-spice-candidate.py")
ARCHIVE = "homebrew-recipe-evidence.zip"
MAX_RECIPE = 2 * 1024 * 1024
LIB = re.compile(r"lib(avcodec|avdevice|avfilter|avformat|avutil|swresample|swscale|postproc)(?:\.[0-9]+)*\.dylib")

def digest(path):
    return audit.sha256(path)

def regular(root, relative):
    path = root / relative
    if (path.is_symlink() or not path.is_file()
            or not path.resolve().is_relative_to(root.resolve())
            or path.stat().st_size > MAX_RECIPE):
        raise ValueError("invalid installed recipe evidence path")
    return path

def recipe(root, name):
    formula = regular(root, ".brew/" + name + ".rb")
    receipt = regular(root, "INSTALL_RECEIPT.json")
    metadata = json.loads(receipt.read_text())
    if metadata.get("source", {}).get("tap") != "homebrew/core":
        raise ValueError("unverified installed formula tap")
    if not formula.read_bytes().strip():
        raise ValueError("empty installed formula")
    return formula, receipt

def ffmpeg_probe(path, symbol):
    """Child mode: call the public configuration/license functions of this dylib."""
    match = LIB.fullmatch(path.name)
    if not match or symbol != match.group(1):
        raise ValueError("unexpected FFmpeg library identity")
    lib = ctypes.CDLL(str(path))
    result = {}
    for kind in ("configuration", "license"):
        func = getattr(lib, symbol + "_" + kind)
        func.argtypes = []
        func.restype = ctypes.c_char_p
        raw = func()
        if not raw or len(raw) > 65536:
            raise ValueError("invalid FFmpeg build metadata")
        result[kind] = raw.decode("utf-8", errors="strict")
    return result

def ffmpeg_rows(package, root):
    rows = []
    seen = set()
    env = {k: v for k, v in os.environ.items() if not k.startswith("DYLD_")}
    for binary in package["components"]:
        props = {p["name"]: p["value"] for p in binary["properties"]}
        relative = Path(props["mrv:keg-path"])
        path = (root / relative).resolve()
        match = LIB.fullmatch(path.name)
        if not match:
            continue
        symbol = match.group(1)
        if symbol in seen or not path.is_relative_to(root.resolve()):
            raise ValueError("ambiguous FFmpeg library")
        seen.add(symbol)
        sha = digest(path)
        if sha != props["mrv:source-sha256"]:
            raise ValueError("FFmpeg source binary mismatch")
        raw = subprocess.check_output([sys.executable, str(Path(__file__).resolve()),
                                       "--probe", str(path), symbol], env=env, timeout=30)
        if len(raw) > 256 * 1024:
            raise ValueError("FFmpeg probe output too large")
        data = json.loads(raw)
        if digest(path) != sha:
            raise ValueError("FFmpeg source binary changed")
        rows.append({"bundle_path": binary["name"], "source_sha256": sha,
                     "symbol": symbol, **data})
    if not rows:
        raise ValueError("FFmpeg keg present without recognized bundled libraries")
    return sorted(rows, key=lambda row: row["bundle_path"])

def binding(bom, manifest):
    return {"baseline_sbom_sha256": digest(bom), "native_manifest_sha256": digest(manifest)}

def expected_packages(bom):
    packages = {}
    for p in audit.package_components(bom):
        name, version = p["name"], p["version"]
        if not audit.NAME.fullmatch(name) or not audit.NAME.fullmatch(version):
            raise ValueError("invalid package identity")
        key = (name, version)
        if key in packages:
            raise ValueError("duplicate package")
        packages[key] = p
    if not packages:
        raise ValueError("empty package set")
    return packages

def verify(path, bom_path, native_manifest):
    manifest = build.verify_source_bundle(path, binding(bom_path, native_manifest))
    expected = expected_packages(json.loads(bom_path.read_text()))
    members = {"review.json"}
    with zipfile.ZipFile(path) as archive:
        if archive.getinfo("review.json").file_size > MAX_RECIPE:
            raise ValueError("recipe review too large")
        report = json.loads(archive.read("review.json"))
        if report["schema"] != 1 or report["release_ready"] is not False:
            raise ValueError("unexpected recipe review scope")
        seen = set()
        for row in report["packages"]:
            key = (row["formula"], row["version"])
            if key not in expected or key in seen or row["license_conclusion"] is not None:
                raise ValueError("invalid recipe coverage")
            seen.add(key)
            prefix = "/".join(key) + "/"
            formula, receipt = prefix + "formula.rb", prefix + "INSTALL_RECEIPT.json"
            for field, member in (("formula_sha256", formula), ("receipt_sha256", receipt)):
                if member not in manifest["members"] or manifest["members"][member]["size"] > MAX_RECIPE:
                    raise ValueError("missing recipe member")
                if row[field] != manifest["members"][member]["sha256"]:
                    raise ValueError("recipe digest mismatch")
                members.add(member)
            metadata = json.loads(archive.read(receipt))
            if metadata.get("source", {}).get("tap") != "homebrew/core":
                raise ValueError("invalid archived receipt tap")
            if not archive.read(formula).strip():
                raise ValueError("empty archived formula")
            probes = row["ffmpeg_build_metadata"]
            want = {}
            if key[0] == "ffmpeg":
                for item in expected[key]["components"]:
                    props = {p["name"]: p["value"] for p in item["properties"]}
                    match = LIB.fullmatch(Path(props["mrv:keg-path"]).name)
                    if match:
                        want[item["name"]] = (props["mrv:source-sha256"], match.group(1))
                if not want:
                    raise ValueError("missing expected FFmpeg libraries")
            got = {}
            for probe in probes:
                name = probe["bundle_path"]
                if name in got or any(not isinstance(probe[k], str) or not probe[k]
                                      or len(probe[k]) > 65536 for k in ("configuration", "license")):
                    raise ValueError("invalid FFmpeg metadata")
                got[name] = (probe["source_sha256"], probe["symbol"])
            if got != want:
                raise ValueError("FFmpeg metadata coverage mismatch")
        if seen != set(expected) or set(manifest["members"]) != members:
            raise ValueError("recipe archive coverage mismatch")
    return report

def collect(bom_path, native_manifest, output):
    bom = json.loads(bom_path.read_text())
    packages = expected_packages(bom)
    cellar = Path(subprocess.check_output(["brew", "--cellar"], text=True).strip()).resolve()
    kegs = audit.verify_kegs(list(packages.values()), json.loads(native_manifest.read_text()), cellar)
    rows, entries = [], {}
    with tempfile.TemporaryDirectory(prefix="mrv-recipe-") as raw:
        report_path = Path(raw) / "review.json"
        for name, version, root, tap in kegs:
            if tap != "homebrew/core":
                raise ValueError("unsupported installed keg tap")
            formula, receipt = recipe(root, name)
            prefix = name + "/" + version + "/"
            entries[prefix + "formula.rb"] = formula
            entries[prefix + "INSTALL_RECEIPT.json"] = receipt
            rows.append({"formula": name, "version": version,
                         "formula_sha256": digest(formula), "receipt_sha256": digest(receipt),
                         "license_conclusion": None,
                         "ffmpeg_build_metadata": ffmpeg_rows(packages[(name, version)], root)
                         if name == "ffmpeg" else []})
        report_path.write_text(json.dumps({"schema": 1, "release_ready": False,
            "packages": rows, "limitations": "Installed recipes and receipts are evidence only; upstream resources, downstream patch bytes, static dependencies and corresponding source remain to be reviewed."},
            sort_keys=True, indent=2) + "\n")
        entries["review.json"] = report_path
        build.write_source_bundle(output, entries, binding(bom_path, native_manifest))
    report = verify(output, bom_path, native_manifest)
    print("MRV_HOMEBREW_RECIPE_EVIDENCE_OK " + json.dumps({
        "kegs": len(report["packages"]),
        "ffmpeg_libraries": sum(len(row["ffmpeg_build_metadata"]) for row in report["packages"]),
        "release_ready": False}, sort_keys=True))

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--probe", nargs=2)
    parser.add_argument("--bom", type=Path)
    parser.add_argument("--native-manifest", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.probe:
        print(json.dumps(ffmpeg_probe(Path(args.probe[0]), args.probe[1])))
        return
    if not all((args.bom, args.native_manifest, args.output)):
        parser.error("collection requires bom, native-manifest and output")
    collect(args.bom, args.native_manifest, args.output)

if __name__ == "__main__":
    main()
