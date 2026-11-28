#!/usr/bin/env python3
"""Compare real compressed fixture decode; no production package changes."""
import argparse
import hashlib
import importlib.util
import json
import os
import re
import shlex
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("experiment", HERE / "ffmpeg-no-libav-experiment.py")
ev = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ev)
# The runner FFmpeg is used only to generate synthetic fixtures, never to decode.
CASES = {
    "mjpeg": ("mjpeg", "mjpeg", "image/jpeg,framerate=10/1", "jpegparse", "avdec_mjpeg", "jpegdec"),
    "vp8": ("libvpx", "ivf", "video/x-vp8,width=64,height=48,framerate=10/1", "-", "avdec_vp8", "vp8dec"),
    "vp9": ("libvpx-vp9", "ivf", "video/x-vp9,width=64,height=48,framerate=10/1", "-", "avdec_vp9", "vp9dec"),
    "h264": ("libx264", "h264", "video/x-h264,stream-format=byte-stream,framerate=10/1", "h264parse", "avdec_h264", "vtdec"),
    "h265": ("libx265", "hevc", "video/x-h265,stream-format=byte-stream,framerate=10/1", "h265parse", "avdec_h265", "vtdec"),
}
MARKER = re.compile(r"MRV_DECODE_OK frames=6 width=64 height=48 red_pixels=18432 elapsed_us=(\d+)")

def fixture(codec, output):
    encoder, fmt, *_ = CASES[codec]
    cmd = ["ffmpeg", "-nostdin", "-v", "error", "-f", "lavfi", "-i",
           "color=c=red:s=64x48:r=10", "-frames:v", "6", "-an", "-threads", "1",
           "-pix_fmt", "yuvj420p" if codec == "mjpeg" else "yuv420p", "-c:v", encoder]
    if codec == "h264":
        cmd += ["-preset", "ultrafast", "-tune", "zerolatency"]
    elif codec == "h265":
        cmd += ["-preset", "ultrafast", "-x265-params", "pools=none:frame-threads=1:log-level=error"]
    elif codec in ("vp8", "vp9"):
        cmd += ["-deadline", "realtime", "-lag-in-frames", "0"]
    subprocess.run([*cmd, "-f", fmt, str(output)], check=True, timeout=45)
    if not 0 < output.stat().st_size <= 1024 * 1024:
        raise ValueError("unexpected fixture size")

def compile_probe(app, out):
    libraries = ev.probe_libraries(app) + [app / "Contents/Frameworks/libgstapp-1.0.0.dylib"]
    for lib in libraries:
        if lib.is_symlink() or not lib.is_file() or not lib.resolve().is_relative_to(app.resolve()):
            raise ValueError("unsafe bundled decoder probe library")
    flags = shlex.split(subprocess.check_output(["pkg-config", "--cflags", "gstreamer-app-1.0"],
                                               text=True, timeout=15))
    subprocess.run(["clang", "-arch", "arm64", *flags, str(HERE / "gst-decode-probe.c"),
                    *map(str, libraries), "-Wl,-rpath," + str(libraries[0].parent),
                    "-o", str(out)], check=True, timeout=60)
    _, deps, rpaths = ev.pack.parse_macho(out)
    for dep in deps:
        if ev.pack.is_system_library(dep):
            continue
        resolved = ev.pack.expand_load_path(dep, loader=out, executable=out, rpaths=rpaths)
        if resolved is None or not resolved.is_relative_to(libraries[0].parent.resolve()):
            raise ValueError("external probe link")
    return libraries

def decode(app, exe, libraries, path, codec, decoder, work, reduced):
    _, _, caps, parser, *_ = CASES[codec]
    work.mkdir()
    plugins = app / ev.linkage.PLUGIN_PREFIX
    env = {k: v for k, v in os.environ.items() if not k.startswith(("DYLD_", "GST_", "OPENSSL_"))}
    env.update(GST_PLUGIN_PATH_1_0=str(plugins), GST_PLUGIN_SYSTEM_PATH_1_0="",
               GST_PLUGIN_PATH="", GST_PLUGIN_SYSTEM_PATH="",
               GST_PLUGIN_SCANNER=str(app / ev.linkage.SCANNER),
               GST_PLUGIN_SCANNER_1_0=str(app / ev.linkage.SCANNER),
               GST_REGISTRY=str(work / "registry.bin"), DYLD_PRINT_LIBRARIES="1",
               PATH="/usr/bin:/bin:/usr/sbin:/sbin")
    result = subprocess.run([str(exe), str(path), caps, parser, decoder], env=env, cwd=work,
                            capture_output=True, text=True, timeout=75)
    trace = result.stderr.splitlines()
    for lib in libraries:
        if not any(line.rstrip().endswith(str(lib.resolve())) for line in trace):
            raise ValueError("missing bundled runtime library: " + lib.name)
    if any("/opt/homebrew/" in line or "/usr/local/" in line for line in trace
           if line.startswith("dyld[") and ": <" in line):
        raise ValueError("external Homebrew library loaded")
    if reduced and any(any(name in line for name in ("libgstlibav.dylib", "libavcodec.",
            "libavutil.", "libavformat.", "libavfilter.", "libswresample.", "libswscale."))
            for line in trace if line.startswith("dyld[") and ": <" in line):
        raise ValueError("FFmpeg runtime load in reduced probe")
    matches = [MARKER.fullmatch(line) for line in result.stdout.splitlines()]
    matches = [m for m in matches if m]
    passed = result.returncode == 0 and len(matches) == 1
    errors = [line[:300] for line in trace if line.startswith("decoder pipeline error:")]
    return {"decoder": decoder, "status": "decoded" if passed else "decode-failed",
            "exit_code": result.returncode, "elapsed_us": int(matches[0][1]) if passed else None,
            "pipeline_errors": errors[:3]}

def main():
    parser = argparse.ArgumentParser()
    for name in ("baseline", "reduced", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    args = parser.parse_args()
    root = args.output.resolve()
    root.mkdir()
    fixtures = {}
    for codec in CASES:
        path = root / (codec + ".fixture")
        fixture(codec, path)
        fixtures[codec] = {"path": path, "sha256": ev.digest(path)}
    rows = []
    for label, app in (("baseline", args.baseline.resolve()), ("no-libav", args.reduced.resolve())):
        exe = root / (label + "-decode-probe")
        libraries = compile_probe(app, exe)
        for codec, data in fixtures.items():
            decoder = CASES[codec][4 if label == "baseline" else 5]
            result = decode(app, exe, libraries, data["path"], codec, decoder,
                            root / (label + "-" + codec), label == "no-libav")
            if ev.digest(data["path"]) != data["sha256"]:
                raise ValueError("fixture changed")
            rows.append({"variant": label, "codec": codec, "fixture_sha256": data["sha256"], **result})
    report = {"schema": 1, "scope": "synthetic-compressed-decode-test-only",
              "release_ready": False, "results": rows,
              "limitations": ["Tiny solid-red synthetic video, not real SPICE stream or benchmark.",
                              "vtdec may use software or hardware; no hardware proof.",
                              "No LGPL compliance or codec coverage beyond these fixtures."]}
    (root / "decode-evidence.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print("MRV_COMPRESSED_DECODE_EVIDENCE " + json.dumps(rows, sort_keys=True))
    # Baseline and software native paths are hard gates. VideoToolbox failures
    # are explicit experimental evidence, not approval or a successful decode.
    if any(r["status"] != "decoded" for r in rows
           if r["variant"] == "baseline" or r["codec"] in ("mjpeg", "vp8", "vp9")):
        raise ValueError("required compressed decode failed")

if __name__ == "__main__":
    main()
