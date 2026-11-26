#!/usr/bin/env python3
"""Prepare a test-only copy of the baseline app with the verified native candidate."""
import argparse
import hashlib
import importlib.util
import json
import os
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
LIBRARY = "libspice-client-glib-2.0.8.dylib"
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
    old_id, _, _ = pack.parse_macho(target)
    if old_id != "@rpath/" + LIBRARY:
        raise ValueError("unexpected baseline library install name")
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
            or lines.count("MRV_GST_REGISTRY_OK") != 1):
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
        "minimum_macos": minimum,
        "dyld_image_lines": load_lines,
    }, indent=2) + "\n")
    print("MRV_SPICE_CANDIDATE_APP_STAGED_OK", flush=True)
    print("MRV_SPICE_CANDIDATE_APP_DYLD_OK", flush=True)


if __name__ == "__main__":
    main()
