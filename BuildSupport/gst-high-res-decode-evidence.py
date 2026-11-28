#!/usr/bin/env python3
"""Bounded high-resolution decode comparison; measurements are process-local."""
import argparse
import importlib.util
import json
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("small", HERE / "gst-compressed-decode-evidence.py")
small = importlib.util.module_from_spec(spec)
spec.loader.exec_module(small)
PROFILES = {"1080p": (1920, 1080, 30), "1440p": (2560, 1440, 30), "4k": (3840, 2160, 30)}

def cases():
    return [(profile, codec) for profile in PROFILES
            for codec in (small.CASES if profile == "1080p" else ("h264", "h265"))]

def fixture(codec, profile, output):
    width, height, frames = profile
    encoder, fmt, *_ = small.CASES[codec]
    cmd = ["ffmpeg", "-nostdin", "-v", "error", "-f", "lavfi", "-i",
           f"color=c=red:s={width}x{height}:r=10", "-vf",
           f"drawbox=x={width//2}:y=0:w={width//2}:h={height}:color=blue:t=fill",
           "-frames:v", str(frames), "-an", "-threads", "2",
           "-pix_fmt", "yuvj420p" if codec == "mjpeg" else "yuv420p", "-c:v", encoder]
    if codec == "h264":
        cmd += ["-preset", "ultrafast", "-tune", "zerolatency"]
    elif codec == "h265":
        cmd += ["-preset", "ultrafast", "-x265-params", "pools=none:frame-threads=1:log-level=error"]
    elif codec in ("vp8", "vp9"):
        cmd += ["-deadline", "realtime", "-lag-in-frames", "0", "-cpu-used", "6"]
    subprocess.run([*cmd, "-f", fmt, str(output)], check=True, timeout=120)
    if not 0 < output.stat().st_size <= 32 * 1024 * 1024:
        raise ValueError("unexpected high-resolution fixture size")

def main():
    parser = argparse.ArgumentParser()
    for name in ("baseline", "reduced", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    args = parser.parse_args()
    root = args.output.resolve()
    root.mkdir()
    variants = {"baseline": args.baseline.resolve(), "no-libav": args.reduced.resolve()}
    probes = {}
    for label, app in variants.items():
        exe = root / (label + "-probe")
        probes[label] = (exe, small.compile_probe(app, exe))
    rows = []
    for name, codec in cases():
        profile = PROFILES[name]
        path = root / f"{name}-{codec}.fixture"
        fixture(codec, profile, path)
        sha = small.ev.digest(path)
        runs = [("baseline", small.CASES[codec][4]), ("no-libav", small.CASES[codec][5])]
        if codec in ("h264", "h265"):
            runs.append(("no-libav", "vtdec_hw"))
        for label, decoder in runs:
            exe, libraries = probes[label]
            result = small.decode(variants[label], exe, libraries, path, codec, decoder,
                                  root / f"{name}-{codec}-{label}-{decoder}", label == "no-libav", profile)
            if small.ev.digest(path) != sha:
                raise ValueError("fixture changed")
            rows.append({"profile": name, "codec": codec, "variant": label,
                         "fixture_sha256": sha, **result})
            print("MRV_HIGH_RES_DECODE " + json.dumps(rows[-1], sort_keys=True), flush=True)
        path.unlink()
    report = {"schema": 1, "scope": "high-resolution-synthetic-decode-test-only",
              "release_ready": False, "results": rows,
              "limitations": ["30 identical split-color frames per fixture; not real desktop motion or SPICE.",
                              "Wall time includes pipeline start, drain and pixel verification, not pure decode.",
                              "CPU time is process user+system delta; peak RSS is macOS process lifetime maximum.",
                              "vtdec_hw factory is a hardware-only candidate, not independent GPU utilization proof.",
                              "No GPU utilization, sustained FPS, license approval or distribution conclusion."]}
    (root / "high-res-decode-evidence.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    # Preserve all standard baseline/native decode gates. Hardware-only
    # failures remain explicit experimental results, never successful decodes.
    if any(r["status"] != "decoded" for r in rows if r["decoder"] != "vtdec_hw"):
        raise ValueError("required high-resolution decode failed")

if __name__ == "__main__":
    main()
