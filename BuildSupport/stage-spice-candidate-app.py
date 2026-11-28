#!/usr/bin/env python3
"""Prepare a test-only copy of the baseline app with the verified native candidate."""
import argparse
import hashlib
import importlib.util
import json
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


pack = load("package_portable", "package-portable.py")
dmg = load("verify_dmg", "verify-dmg.py")
build = load("build_spice_candidate", "build-spice-candidate.py")
LIBRARY = build.SPICE_CLIENT_DYLIB
APP = "Mac Remote Viewer.app"


def only(root, pattern):
    paths = list(root.rglob(pattern))
    if len(paths) != 1 or not paths[0].is_file() or paths[0].is_symlink():
        raise ValueError(f"expected exactly one regular {pattern}")
    return paths[0]


def digest(path):
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def run(*args, timeout=120):
    subprocess.run(list(map(str, args)), check=True, timeout=timeout)


def source_properties(bom, relative):
    matches = [item for item in dmg.validator.components(bom["components"])
               if item["type"] == "file" and item["name"] == relative]
    if len(matches) != 1:
        raise ValueError(f"missing or duplicate baseline SBOM file: {relative}")
    return {entry["name"]: entry["value"] for entry in matches[0]["properties"]}


def candidate_origins(baseline_bom, report):
    """Preserve observed origins except the replaced bottle; never mislabel it."""
    target = "Contents/Frameworks/" + LIBRARY
    origins = {}
    seen = set()
    for item in dmg.validator.components(baseline_bom["components"]):
        if item["type"] != "file":
            continue
        relative = item["name"]
        if relative in seen:
            raise ValueError("duplicate baseline origin")
        seen.add(relative)
        props = {p["name"]: p["value"] for p in item["properties"]}
        if relative == target:
            if props.get("mrv:source-sha256") != report["baseline_sha256"]:
                raise ValueError("candidate baseline origin mismatch")
            continue
        origin = {}
        for key in ("source-sha256", "source-name", "formula", "version", "keg-path"):
            if "mrv:" + key in props:
                origin[key.replace("-", "_")] = props["mrv:" + key]
        if origin:
            origins[relative] = origin
    if target not in seen:
        raise ValueError("missing baseline candidate origin")
    for key in ("upstream_sha256", "downstream_sha256", "candidate_patch_sha256",
                "candidate_dylib_sha256", "baseline_sha256"):
        if not re.fullmatch(r"[0-9a-f]{64}", report[key]):
            raise ValueError("invalid candidate provenance digest")
    origins[target] = {
        "source_sha256": report["candidate_dylib_sha256"],
        "source_name": LIBRARY,
        "upstream_sha256": report["upstream_sha256"],
        "downstream_patch_sha256": report["downstream_sha256"],
        "candidate_patch_sha256": report["candidate_patch_sha256"],
        "baseline_source_sha256": report["baseline_sha256"],
        "build_origin": "locally-built-modified-spice-gtk",
    }
    return origins


def candidate_sbom(app, baseline_bom, report, final_hash):
    origins = candidate_origins(baseline_bom, report)
    bom = pack.build_sbom(app, origins, version=pack.app_version(app))
    target = "Contents/Frameworks/" + LIBRARY
    matches = [item for item in bom["components"] if item["type"] == "file" and item["name"] == target]
    if len(matches) != 1 or matches[0]["hashes"] != [{"alg": "SHA-256", "content": final_hash}]:
        raise ValueError("candidate signed file inventory mismatch")
    file = matches[0]
    bom["components"].remove(file)
    bom["components"].append({
        "type": "library", "bom-ref": "modified:spice-gtk@0.43",
        "name": "spice-gtk (locally modified)", "version": "0.43",
        "externalReferences": [{"type": "website", "url": "https://www.spice-space.org/"}],
        "components": [file],
    })
    bom["metadata"]["properties"].append({
        "name": "mrv:distribution-scope", "value": "candidate-test-only; distribution review incomplete"
    })
    return bom


def package_candidate(app, baseline_bom, report, final_hash, output):
    """Build a separate verification image; test only the copy from that image."""
    dist = output / "candidate-package"
    dist.mkdir(exist_ok=False)
    bom = candidate_sbom(app, baseline_bom, report, final_hash)
    stem = f"MacRemoteViewer-{pack.app_version(app)}-arm64-candidate-test-only"
    bom_path = dist / (stem + ".bom.json")
    bom_path.write_text(json.dumps(bom, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    bom_path.with_suffix(".json.sha256").write_text(f"{digest(bom_path)}  {bom_path.name}\n")
    dmg.validator.verify_inventory(bom, app)
    image = pack.make_dmg(app, dist, bom_path, candidate_test_only=True)
    run("hdiutil", "verify", image)
    if image.with_suffix(".dmg.sha256").read_text().split() != [digest(image), image.name]:
        raise ValueError("candidate DMG checksum mismatch")
    copied = output / "mounted-copy" / APP
    copied.parent.mkdir(exist_ok=False)
    with tempfile.TemporaryDirectory(prefix="mrv-candidate-package-") as directory:
        mount = Path(directory) / "mount"
        mount.mkdir()
        run("hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount, image)
        try:
            mounted = dmg.verify_mounted(mount, bom_path)
            run("ditto", mounted, copied)
        finally:
            run("hdiutil", "detach", mount)
    run("codesign", "--verify", "--deep", "--strict", copied)
    dmg.validator.verify_inventory(bom, copied)
    if digest(copied / "Contents" / "Frameworks" / LIBRARY) != final_hash:
        raise ValueError("candidate image copy library mismatch")
    print("MRV_SPICE_CANDIDATE_DMG_INVENTORY_OK", flush=True)
    return {"dmg_sha256": digest(image), "sbom_sha256": digest(bom_path),
            "signed_library_sha256": final_hash,
            "runtime_input": "mounted-copy/" + APP,
            "distribution_scope": "candidate-test-only"}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    baseline, candidate, output = (p.resolve() for p in (args.baseline, args.candidate, args.output))
    output.mkdir(parents=True, exist_ok=False)
    image = only(baseline, "*.dmg")
    bom = only(baseline, "*.bom.json")
    # Verify both transported checksums before mounting the baseline.
    for artifact in (image, bom):
        checksum = only(baseline, artifact.name + ".sha256")
        fields = checksum.read_text().split()
        if fields != [digest(artifact), artifact.name]:
            raise ValueError("baseline artifact checksum mismatch")
    raw_library = only(candidate, LIBRARY)
    report = json.loads(only(candidate, "native-build-report.json").read_text())
    if digest(raw_library) != report["candidate_dylib_sha256"]:
        raise ValueError("candidate transfer checksum mismatch")
    if report["baseline_exports"] != report["candidate_exports"] or report["extra_exports"]:
        raise ValueError("candidate export mismatch")
    app = output / APP
    with tempfile.TemporaryDirectory(prefix="mrv-candidate-mount-") as directory:
        mount = Path(directory) / "mount"
        mount.mkdir()
        run("hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen",
            "-mountpoint", mount, image)
        try:
            verified = dmg.verify_mounted(mount, bom)
            run("ditto", verified, app)
        finally:
            run("hdiutil", "detach", mount)
    run("codesign", "--verify", "--deep", "--strict", app)
    target = app / "Contents" / "Frameworks" / LIBRARY
    if not target.is_file() or target.is_symlink():
        raise ValueError("baseline library is not a regular bundled file")
    baseline_hash = digest(target)
    if baseline_hash == digest(raw_library):
        raise ValueError("unexpected identical baseline and candidate binary")
    old_id, old_deps, _ = pack.parse_macho(target)
    if old_id != "@rpath/" + LIBRARY:
        raise ValueError("unexpected baseline library install name")
    baseline_bom = json.loads(bom.read_text())
    props = source_properties(baseline_bom, "Contents/Frameworks/" + LIBRARY)
    if props["mrv:source-sha256"] != report["baseline_sha256"]:
        raise ValueError("candidate built against a different baseline spice client")
    old_tls = {kind: Path(value).name for kind, value in build.tls_load_names(old_deps).items()}
    _, raw_deps, _ = pack.parse_macho(raw_library)
    new_tls = {kind: Path(value).name for kind, value in build.tls_load_names(raw_deps).items()}
    if old_tls != new_tls or set(report["tls_dependencies"]) != set(old_tls):
        raise ValueError("candidate TLS ABI differs from packaged baseline")
    for kind, name in old_tls.items():
        expected = report["tls_dependencies"][kind]
        props = source_properties(baseline_bom, "Contents/Frameworks/" + name)
        if (name != expected["name"] or props["mrv:source-sha256"] != expected["sha256"]
                or props["mrv:formula"] != expected["formula"]
                or props["mrv:version"] != expected["version"]):
            raise ValueError("candidate TLS source provenance differs from baseline SBOM")
    (output / "staging-report.json").write_text(json.dumps({
        "scope": "test-only candidate app; TLS and baseline source provenance preflight",
        "baseline_dmg_sha256": digest(image),
        "baseline_bundled_dylib_sha256": baseline_hash,
        "candidate_raw_sha256": report["candidate_dylib_sha256"],
        "tls_dependencies": report["tls_dependencies"],
    }, indent=2) + "\n")
    print("MRV_SPICE_CANDIDATE_APP_TLS_PROVENANCE_OK", flush=True)
    pack.chmod_writable(target)
    shutil.copyfile(raw_library, target)
    pack.chmod_writable(target)
    if digest(target) != report["candidate_dylib_sha256"]:
        raise ValueError("staged raw candidate hash mismatch")
    pack.rewrite_load_commands(target, id_path=old_id, extra_rpath=pack.RPATH_LOADER)
    ident, deps, rpaths = pack.parse_macho(target)
    if ident != old_id:
        raise ValueError("candidate install name rewrite failed")
    if any(not (pack.is_system_library(dep) or dep.startswith("@rpath/"))
           for dep in deps):
        raise ValueError("candidate retains nonportable dependency")
    if any(not path.startswith(("@loader_path", "@executable_path")) for path in rpaths):
        raise ValueError("candidate retains external rpath")
    pack.verify_no_host_paths(app)
    minimum = pack.verify_bundle_dependencies(app)
    pack.sign_app(app)
    run("codesign", "--verify", "--deep", "--strict", app)
    final_hash = digest(target)
    if final_hash == baseline_hash:
        raise ValueError("candidate staging unexpectedly reverted to baseline")
    executable = app / "Contents" / "MacOS" / "Mac Remote Viewer"
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(("DYLD_", "GST_", "OPENSSL_"))}
    env.update(PATH="/usr/bin:/bin:/usr/sbin:/sbin",
               MRV_ENABLE_INTEGRATION_PROBES="1", DYLD_PRINT_LIBRARIES="1")
    result = subprocess.run([str(executable), "--startup-smoke-test"], env=env,
                            cwd=output, capture_output=True, text=True, timeout=45)
    (output / "startup.stdout.txt").write_text(result.stdout)
    (output / "startup.stderr.txt").write_text(result.stderr)
    lines = result.stdout.splitlines()
    if (result.returncode != 0 or lines.count("MRV_STARTUP_SMOKE_OK") != 1
            or lines.count("MRV_GST_REGISTRY_OK") != 1
            or lines.count("MRV_CORE_DUMP_LIMIT_OK") != 1
            or lines.count("MRV_WORKER_LIFECYCLE_OK rounds=3 drained=384") != 1):
        raise ValueError("candidate app startup failed")
    # dyld may report /private/var instead of /var. Require a matching real
    # path in the loader's diagnostics; merely checking linkage is insufficient.
    load_lines = [line for line in result.stderr.splitlines() if LIBRARY in line]
    expected = str(target.resolve())
    if not load_lines or not all(line.rstrip().endswith(expected) or
                                 line.rstrip().endswith(str(target)) for line in load_lines):
        raise ValueError(f"candidate library runtime load not established: {load_lines}")
    if digest(target) != final_hash:
        raise ValueError("candidate changed during startup")
    (output / "staging-report.json").write_text(json.dumps({
        "scope": "test-only candidate app; original preview unchanged",
        "baseline_dmg_sha256": digest(image),
        "baseline_bundled_dylib_sha256": baseline_hash,
        "candidate_raw_sha256": report["candidate_dylib_sha256"],
        "candidate_signed_sha256": final_hash,
        "candidate_patch_sha256": report["candidate_patch_sha256"],
        "tls_dependencies": report["tls_dependencies"],
        "minimum_macos": minimum,
        "dyld_image_lines": load_lines,
    }, indent=2) + "\n")
    print("MRV_SPICE_CANDIDATE_APP_STAGED_OK", flush=True)
    print("MRV_SPICE_CANDIDATE_APP_DYLD_OK", flush=True)
    package = package_candidate(app, baseline_bom, report, final_hash, output)
    staging_path = output / "staging-report.json"
    staging = json.loads(staging_path.read_text())
    staging["candidate_package"] = package
    staging_path.write_text(json.dumps(staging, indent=2) + "\n")


if __name__ == "__main__":
    main()
