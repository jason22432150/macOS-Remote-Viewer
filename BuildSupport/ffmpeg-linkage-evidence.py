#!/usr/bin/env python3
"""Read-only ARM64 Mach-O linkage evidence for FFmpeg substitution planning."""
import argparse
import hashlib
import importlib.util
import json
import re
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

inventory = load("distribution_inventory", "distribution-inventory.py")
package = load("package_portable", "package-portable.py")
MAIN = "Contents/MacOS/Mac Remote Viewer"
SCANNER = "Contents/MacOS/gst-plugin-scanner"
PLUGIN_PREFIX = "Contents/Resources/gstreamer-1.0/"
LOADS = {"LC_LOAD_DYLIB", "LC_LOAD_WEAK_DYLIB", "LC_REEXPORT_DYLIB",
         "LC_LOAD_UPWARD_DYLIB", "LC_LAZY_LOAD_DYLIB"}

def parse_commands(text):
    """Keep load-command kind, raw install name and per-image rpaths."""
    loads, rpaths = [], []
    for block in re.split(r"(?m)^Load command \d+\s*$", text)[1:]:
        command = re.search(r"(?m)^\s*cmd\s+(LC_\w+)\s*$", block)
        if not command:
            raise ValueError("missing Mach-O load command")
        kind = command[1]
        if kind in LOADS or kind == "LC_RPATH":
            field = "path" if kind == "LC_RPATH" else "name"
            match = re.search(r"(?m)^\s*" + field + r"\s+(.+?)\s+\(offset \d+\)\s*$", block)
            if not match:
                raise ValueError("malformed Mach-O load path")
            if kind == "LC_RPATH":
                rpaths.append(match[1])
            else:
                loads.append({"kind": kind, "install_name": match[1]})
    if not re.search(r"(?m)^Load command \d+\s*$", text):
        raise ValueError("no ARM64 Mach-O load commands")
    return loads, rpaths

def reach(graph, seeds):
    seen, pending = set(), list(seeds)
    while pending:
        current = pending.pop()
        if current not in graph:
            raise ValueError("missing linkage node")
        if current not in seen:
            seen.add(current)
            pending.extend(graph[current])
    return seen

def summarize(nodes):
    graph = {n: {edge["target"] for edge in row["loads"] if edge["target"] is not None}
             for n, row in nodes.items()}
    if not {MAIN, SCANNER} <= graph.keys():
        raise ValueError("missing app or scanner linkage root")
    ffmpeg = {n for n, row in nodes.items() if row["component"].startswith("homebrew:ffmpeg@")}
    if not ffmpeg:
        raise ValueError("expected baseline FFmpeg libraries absent")
    plugins = sorted(n for n in graph if n.startswith(PLUGIN_PREFIX))
    roots = [MAIN, SCANNER, *plugins]
    root_rows = []
    for root in roots:
        closure = reach(graph, [root])
        root_rows.append({"root": root, "ffmpeg_libraries": sorted(closure & ffmpeg)})
    direct = sorted(n for n, edges in graph.items() if n not in ffmpeg and edges & ffmpeg)
    affected = sorted(n for n in graph if reach(graph, [n]) & ffmpeg)
    return {"ffmpeg_libraries": sorted(ffmpeg), "direct_non_ffmpeg_consumers": direct,
            "all_reaching_ffmpeg": affected, "root_closures": root_rows,
            "ffmpeg_dependencies_outside_ffmpeg": sorted(reach(graph, ffmpeg) - ffmpeg)}

def inspect(app, bom_path):
    app = app.resolve()
    raw = json.loads(bom_path.read_text())
    _, files = inventory.inventory(raw)
    actual = {p.relative_to(app).as_posix() for p in package.iter_macho_files(app)}
    if actual != set(files):
        raise ValueError("linkage inventory does not match signed SBOM")
    commands = {}
    for name, item in sorted(files.items()):
        path = app / name
        if path.is_symlink() or not path.resolve().is_relative_to(app):
            raise ValueError("unexpected linkage file path")
        if inventory.digest(path) != item["signed_sha256"]:
            raise ValueError("signed linkage file hash mismatch")
        text = subprocess.check_output(["otool", "-arch", "arm64", "-l", str(path)],
                                       text=True, timeout=20)
        commands[name] = parse_commands(text)
    executable = app / MAIN
    main_rpaths = commands[MAIN][1]
    nodes = {}
    for name, item in sorted(files.items()):
        loads, rpaths = commands[name]
        resolved_edges = []
        for load in loads:
            dep = load["install_name"]
            target = None
            if not package.is_system_library(dep):
                resolved = package.expand_load_path(dep, loader=app / name, executable=executable,
                                                    rpaths=rpaths)
                if resolved is None and dep.startswith("@rpath/"):
                    resolved = package.expand_load_path(dep, loader=executable, executable=executable,
                                                        rpaths=main_rpaths)
                if resolved is None or not resolved.is_relative_to(app):
                    raise ValueError("unresolved or external Mach-O link: " + name + " -> " + dep)
                target = resolved.relative_to(app).as_posix()
                if target not in files:
                    raise ValueError("link target not covered by signed SBOM")
            resolved_edges.append({**load, "target": target})
        if inventory.digest(app / name) != item["signed_sha256"]:
            raise ValueError("linkage file changed during inspection")
        nodes[name] = {"component": item["group"], "signed_sha256": item["signed_sha256"],
                       "rpaths": rpaths, "loads": resolved_edges}
    return {"schema": 1, "scope": "candidate-test-only", "release_ready": False,
            "candidate_sbom_sha256": inventory.digest(bom_path),
            "architecture": "arm64", "nodes": nodes, "summary": summarize(nodes),
            "limitations": ["Static Mach-O load commands, not a runtime dyld trace.",
                            "Uses the existing portable bundle loader and main runpath model.",
                            "GStreamer plugins are potential dlopen roots, not proof of actual codec use.",
                            "Does not inventory static code, runtime-only dlopen, or establish LGPL compatibility."]}

def main():
    parser = argparse.ArgumentParser()
    for arg in ("app", "bom", "output"):
        parser.add_argument("--" + arg, type=Path, required=True)
    args = parser.parse_args()
    result = inspect(args.app, args.bom)
    with args.output.open("x", encoding="utf-8") as handle:
        json.dump(result, handle, indent=2, sort_keys=True)
        handle.write("\n")
    print("MRV_FFMPEG_LINKAGE_EVIDENCE_OK " + json.dumps({
        "signed_nodes": len(result["nodes"]),
        "ffmpeg_libraries": result["summary"]["ffmpeg_libraries"],
        "direct_non_ffmpeg_consumers": result["summary"]["direct_non_ffmpeg_consumers"],
        "roots_reaching_ffmpeg": [r["root"] for r in result["summary"]["root_closures"]
                                 if r["ffmpeg_libraries"]],
        "release_ready": False}, sort_keys=True))

if __name__ == "__main__":
    main()
