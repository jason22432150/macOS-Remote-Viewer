#!/usr/bin/env python3
"""Isolated no-libav feasibility experiment, not an LGPL or release candidate."""
import argparse
import json
import os
import shlex
import subprocess
import tempfile
from pathlib import Path
import importlib.util

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("linkage", HERE / "ffmpeg-linkage-evidence.py")
linkage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(linkage)
pack = linkage.package
digest = linkage.inventory.digest
LIBAV = linkage.PLUGIN_PREFIX + "libgstlibav.dylib"
FACTORIES = ("jpegdec", "vp8dec", "vp9dec", "vtdec", "vtdec_hw",
             "h264parse", "h265parse", "avdec_h264", "avdec_h265",
             "avdec_vp8", "avdec_vp9", "avdec_mjpeg")

def removal_plan(evidence):
    nodes = evidence["nodes"]
    summary = linkage.summarize(nodes)
    if (evidence["scope"] != "candidate-test-only" or evidence["release_ready"] is not False
            or evidence["summary"] != summary):
        raise ValueError("unexpected linkage evidence")
    if summary["direct_non_ffmpeg_consumers"] != [LIBAV]:
        raise ValueError("unexpected FFmpeg consumer; do not prune")
    remove = set(summary["ffmpeg_libraries"]) | {LIBAV}
    for name, node in nodes.items():
        if name not in remove and any(e["target"] in remove for e in node["loads"]):
            raise ValueError("retained node depends on removed file")
    # Keep all other dependencies, including potentially GPL x264/x265.
    # Orphan analysis is informational, not proof of runtime non-use.
    return sorted(remove)

def verify_original(app, evidence):
    actual = {p.relative_to(app).as_posix() for p in pack.iter_macho_files(app)}
    if actual != set(evidence["nodes"]):
        raise ValueError("original Mach-O inventory changed")
    for name, node in evidence["nodes"].items():
        path = app / name
        if path.is_symlink() or not path.resolve().is_relative_to(app.resolve()) or digest(path) != node["signed_sha256"]:
            raise ValueError("original signed file changed: " + name)

def factory_probe(app, work):
    frameworks = app / "Contents/Frameworks"
    gst = list(frameworks.glob("libgstreamer-1.0.0.dylib"))
    if len(gst) != 1:
        raise ValueError("bundled GStreamer core absent")
    work.mkdir()
    exe = work / "gst-factory-probe"
    flags = shlex.split(subprocess.check_output(["pkg-config", "--cflags", "gstreamer-1.0"], text=True, timeout=15))
    subprocess.run(["clang", *flags, str(HERE / "gst-factory-probe.c"), str(gst[0]),
                    "-Wl,-rpath," + str(frameworks), "-o", str(exe)], check=True, timeout=60)
    plugin_dir = app / linkage.PLUGIN_PREFIX
    env = {k: v for k, v in os.environ.items() if not k.startswith(("DYLD_", "GST_", "OPENSSL_"))}
    env.update(GST_PLUGIN_PATH_1_0=str(plugin_dir), GST_PLUGIN_SYSTEM_PATH_1_0="",
               GST_PLUGIN_PATH="", GST_PLUGIN_SYSTEM_PATH="",
               GST_PLUGIN_SCANNER=str(app / linkage.SCANNER),
               GST_PLUGIN_SCANNER_1_0=str(app / linkage.SCANNER),
               GST_REGISTRY=str(work / "registry.bin"), DYLD_PRINT_LIBRARIES="1",
               PATH="/usr/bin:/bin:/usr/sbin:/sbin")
    result = subprocess.run([str(exe), *FACTORIES], env=env, cwd=work,
                            capture_output=True, text=True, timeout=90, check=True)
    # The probe must load the actual bundled core; reject Homebrew fallback.
    trace = result.stderr.splitlines()
    if not any(line.rstrip().endswith(str(gst[0].resolve())) for line in trace):
        raise ValueError("bundled GStreamer core load not established")
    if any("/opt/homebrew/" in line or "/usr/local/" in line for line in trace
           if line.startswith("dyld[") and ": <" in line):
        raise ValueError("external Homebrew dylib loaded")
    rows = {}
    for line in result.stdout.splitlines():
        if not line.startswith("MRV_FACTORY\t"):
            continue
        _, name, state, filename = line.split("\t")
        if name not in FACTORIES or name in rows or state not in ("missing", "create-failed", "created"):
            raise ValueError("invalid factory probe row")
        if state == "created" and not Path(filename).resolve().is_relative_to(plugin_dir.resolve()):
            raise ValueError("factory loaded outside bundled plugin directory")
        rows[name] = {"status": state, "plugin": Path(filename).name if filename else None}
    if set(rows) != set(FACTORIES):
        raise ValueError("factory probe coverage mismatch")
    return rows

def startup(app, work):
    env = {k: v for k, v in os.environ.items() if not k.startswith(("DYLD_", "GST_", "OPENSSL_"))}
    env.update(PATH="/usr/bin:/bin:/usr/sbin:/sbin", MRV_ENABLE_INTEGRATION_PROBES="1",
               GST_REGISTRY=str(work / "startup-registry.bin"), DYLD_PRINT_LIBRARIES="1")
    result = subprocess.run([str(app / linkage.MAIN), "--startup-smoke-test"],
                            cwd=work, env=env, capture_output=True, text=True, timeout=60)
    lines = result.stdout.splitlines()
    required = ("MRV_STARTUP_SMOKE_OK", "MRV_GST_REGISTRY_OK", "MRV_CORE_DUMP_LIMIT_OK",
                "MRV_WORKER_LIFECYCLE_OK rounds=3 drained=384")
    if result.returncode or any(lines.count(marker) != 1 for marker in required):
        raise ValueError("isolated no-libav startup smoke failed")
    if any("libgstlibav.dylib" in line or any(name in line for name in (
            "libavcodec.", "libavutil.", "libavformat.", "libavfilter.", "libswresample.", "libswscale."))
           for line in result.stderr.splitlines() if line.startswith("dyld[") and ": <" in line):
        raise ValueError("unexpected FFmpeg runtime load")

def run_experiment(app, bom, evidence_path, output):
    app = app.resolve()
    evidence = json.loads(evidence_path.read_text())
    if evidence["candidate_sbom_sha256"] != digest(bom):
        raise ValueError("linkage SBOM digest mismatch")
    # Re-inspect actual signed input rather than trust a transferred graph.
    if linkage.inspect(app, bom) != evidence:
        raise ValueError("linkage evidence changed")
    remove = removal_plan(evidence)
    output.mkdir(exist_ok=False)
    clone = output / "Mac Remote Viewer.app"
    subprocess.run(["ditto", str(app), str(clone)], check=True, timeout=120)
    verify_original(clone, evidence)
    try:
        for name in remove:
            (clone / name).unlink()
        expected = set(evidence["nodes"]) - set(remove)
        if {p.relative_to(clone).as_posix() for p in pack.iter_macho_files(clone)} != expected:
            raise ValueError("unexpected experiment inventory")
        pack.verify_no_host_paths(clone)
        pack.verify_bundle_dependencies(clone)
        pack.sign_app(clone)
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(clone)], check=True, timeout=60)
        baseline = factory_probe(app, output / "baseline-probe")
        reduced = factory_probe(clone, output / "no-libav-probe")
        if any(reduced[name]["status"] != "missing" for name in FACTORIES if name.startswith("avdec_")):
            raise ValueError("libav decoder still registered")
        startup(clone, output)
        report = {"schema": 1, "scope": "isolated-no-libav-test-only", "release_ready": False,
                  "candidate_sbom_sha256": digest(bom), "linkage_evidence_sha256": digest(evidence_path),
                  "removed": remove, "retained_signed_macho_count": len(expected),
                  "baseline_factories": baseline, "no_libav_factories": reduced,
                  "startup_smoke": "passed",
                  "limitations": ["Factory creation is not a successful compressed-stream decode.",
                                  "Other dependencies including GPL libraries remain.",
                                  "No real SPICE compressed-stream, performance or LGPL compliance claim."]}
        (output / "no-libav-evidence.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        print("MRV_NO_LIBAV_EXPERIMENT_OK " + json.dumps({
            "removed": remove, "retained_signed_macho_count": len(expected),
            "baseline_created": sorted(n for n, row in baseline.items() if row["status"] == "created"),
            "no_libav_created": sorted(n for n, row in reduced.items() if row["status"] == "created"),
            "release_ready": False}, sort_keys=True))
    finally:
        verify_original(app, evidence)

def main():
    parser = argparse.ArgumentParser()
    for name in ("app", "bom", "linkage", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    args = parser.parse_args()
    run_experiment(args.app, args.bom, args.linkage, args.output)

if __name__ == "__main__":
    main()
