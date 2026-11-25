#!/usr/bin/env python3
"""Real libspice-server ticket authentication, reconnect and TLS-only main channel."""
import argparse
from contextlib import ExitStack
import importlib.util
import os
import re
import shlex
import socket
import subprocess
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("tls_fixture", HERE / "test-loopback-tls.py")
tls = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(tls)


def compile_fixture(destination):
    flags = shlex.split(subprocess.check_output(
        ["pkg-config", "--cflags", "--libs", "spice-server", "glib-2.0"], text=True))
    subprocess.run(["xcrun", "clang", "-std=c11", str(HERE / "spice-auth-fixture.c"),
                    "-o", str(destination), *flags], check=True, timeout=60)


def test_case(app, root, fixture, name, server_ticket, success, display=False, partial=False, agent=None):
    with socket.socket() as reserved:
        reserved.bind(("127.0.0.1", 0))
        port = reserved.getsockname()[1]
    # Bind on loopback only. A port collision is an explicit fixture failure.
    profile = root / f"{name}.vv"
    profile.write_text(tls.fixture_profile(port, root / "trusted.pem", tls.SUBJECT))
    log = root / f"{name}.log"
    with log.open("wb") as output:
        command = [str(fixture), str(port), str(root / "trusted.pem"),
                   str(root / "server.pem"), str(root / "server.key"), server_ticket]
        if agent is not None:
            command.append("agent-" + agent)
        elif display:
            command.append("partial" if partial else "display")
        server = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                if server.poll() is not None:
                    raise RuntimeError(f"{name}: fixture exited before test")
                if "READY" in log.read_text(errors="replace").splitlines():
                    break
                time.sleep(0.05)
            else:
                raise RuntimeError(f"{name}: fixture not ready")
            env = {k: v for k, v in os.environ.items() if not k.startswith(("DYLD_", "GST_", "OPENSSL_"))}
            for key in list(env):
                if key.lower() in ("http_proxy", "https_proxy", "all_proxy", "no_proxy", "spice_proxy"):
                    env.pop(key)
            env["NO_PROXY"] = "127.0.0.1"
            env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
            env["GST_REGISTRY"] = str(root / "gst-registry.bin")
            exe = app / "Contents" / "MacOS" / "Mac Remote Viewer"
            mode = ("--loopback-spice-partial-probe" if partial else
                    "--loopback-spice-display-probe" if display else "--loopback-spice-auth-probe")
            client = [str(exe), mode, str(profile)]
            if agent in ("clipboard-full", "clipboard-invalid-full"):
                mode = "--loopback-spice-clipboard-invalid-probe" if agent == "clipboard-invalid-full" else "--loopback-spice-clipboard-probe"
                client = [str(exe), mode, str(profile)]
            elif agent is not None:
                client = [str(exe), "--loopback-spice-agent-probe", str(profile), agent]
            result = subprocess.run(client, cwd=root, env=env, capture_output=True, text=True, timeout=45)
            lines = result.stdout.splitlines()
            expected = ("MRV_SPICE_PARTIAL_OK" if partial else "MRV_SPICE_DISPLAY_OK" if display else
                        ("MRV_SPICE_AUTH_OK" if success else "MRV_SPICE_AUTH_REJECTED"))
            if agent is not None:
                expected = "MRV_SPICE_CLIPBOARD_OK" if agent in ("clipboard-full", "clipboard-invalid-full") else "MRV_SPICE_AGENT_OK"
            if result.returncode != 0 or expected not in lines:
                print(result.stdout[-6000:])
                print(result.stderr[-6000:])
                raise AssertionError(f"{name}: missing expected auth result")
            if agent in ("clipboard-full", "clipboard-invalid-full"):
                markers = ["MRV_CLIP_HOST_READY", "MRV_CLIP_GUEST_UTF8_OK"]
                if agent == "clipboard-invalid-full":
                    markers.append("MRV_CLIP_INVALID_RECOVERY_OK")
                markers.append("MRV_SPICE_CLIPBOARD_OK")
                actual = [line for line in lines if line.startswith(("MRV_CLIP_", "MRV_SPICE_CLIPBOARD_OK"))]
                if actual != markers:
                    raise AssertionError(f"{name}: incomplete clipboard lifecycle {actual}")
                print("\n".join(actual))
            elif agent is not None:
                capability = int(agent.endswith("full"))
                markers = [f"MRV_AGENT_CAPS_OK monitors={capability} clipboard={capability}",
                           "MRV_AGENT_REMOVED_OK main=connected", "MRV_SPICE_AGENT_OK"]
                actual = [line for line in lines if line.startswith(("MRV_AGENT_CAPS_OK ", "MRV_AGENT_REMOVED_OK ", "MRV_SPICE_AGENT_OK"))]
                if actual != markers:
                    raise AssertionError(f"{name}: unexpected agent lifecycle {actual}")
                print("\n".join(actual))
                if agent.startswith("monitor-"):
                    expected_monitor = ["MRV_AGENT_MONITOR_TARGET 1024x768"]
                    if capability and agent != "monitor-resize-full":
                        expected_monitor.append("MRV_AGENT_MONITOR_UNAPPLIED_OK")
                    expected_monitor.append("MRV_AGENT_MONITOR_OFFLINE_OK")
                    actual_monitor = [line for line in lines if line.startswith("MRV_AGENT_MONITOR_")]
                    if actual_monitor != expected_monitor:
                        raise AssertionError(f"{name}: incorrect monitor request lifecycle: {actual_monitor}")
                    print("\n".join(actual_monitor))
                    if agent == "monitor-resize-full":
                        resize_markers = [line for line in lines if line.startswith("MRV_AGENT_RESIZE_")]
                        if resize_markers != ["MRV_AGENT_RESIZE_INITIAL_OK 640x480",
                                              "MRV_AGENT_RESIZE_APPLIED_OK 1024x768 pixels=cyan,magenta mapping=ok"]:
                            raise AssertionError(f"{name}: incomplete actual surface resize: {resize_markers}")
                        print("\n".join(resize_markers))
            elif partial:
                rounds = [line for line in lines if line.startswith("MRV_SPICE_PARTIAL_ROUND_OK ")]
                if rounds != [f"MRV_SPICE_PARTIAL_ROUND_OK {i} 640x480 center=red,green exterior=blue,blue,blue,blue" for i in (1, 2)]:
                    raise AssertionError("missing same-frame partial update results")
                if any(line.startswith("MRV_PARTIAL_MISMATCH") for line in lines):
                    raise AssertionError("partial update changed an exterior pixel")
                for line in rounds:
                    print(line)
            elif display:
                rounds = [line for line in lines if line.startswith("MRV_SPICE_DISPLAY_ROUND_OK ")]
                if len(rounds) != 2 or any(not line.startswith(f"MRV_SPICE_DISPLAY_ROUND_OK {i} 640x480 first-frame-ms=")
                                           or not line.endswith(" pixels=red,green")
                                           for i, line in enumerate(rounds, 1)):
                    raise AssertionError("did not complete both actual display rounds")
                for line in rounds:
                    print(line)
            if success and not display and agent is None and [line for line in lines if line.startswith("MRV_SPICE_AUTH_ROUND_OK ")] != [
                    f"MRV_SPICE_AUTH_ROUND_OK {i}" for i in range(1, 4)]:
                raise AssertionError("did not complete all three reconnect rounds")
        finally:
            if server.poll() is None:
                server.terminate()
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait(timeout=5)
            # Always emit bounded fixture logs, including on client assertion/timeout.
            print(f"{name}: fixture exit={server.returncode}")
            print(log.read_text(errors="replace")[-6000:])
        lines = log.read_text(errors="replace").splitlines()
        if server.returncode != 0:
            raise AssertionError(f"{name}: fixture exited abnormally")
        initialized = [line for line in lines if line.startswith("MAIN_INITIALIZED ")]
        if display:
            display_channels = [line for line in lines if line.startswith("DISPLAY_INITIALIZED ")]
            if (display_channels != ["DISPLAY_INITIALIZED tls=1"] * 2
                    or "PRIMARY_CREATED 640x480" not in lines or "VM_STARTED" not in lines):
                raise AssertionError(f"unexpected display channels or lifecycle: {display_channels}")
            counts = [re.fullmatch(r"DRAW_COUNTS submitted=(\d+) consumed=(\d+) released=(\d+)", line)
                      for line in lines if line.startswith("DRAW_COUNTS ")]
            if len(counts) != 1 or counts[0] is None:
                raise AssertionError("missing QXL worker counters")
            submitted, consumed, released = map(int, counts[0].groups())
            if not 0 < consumed <= submitted or not 0 <= released <= consumed:
                raise AssertionError(f"invalid QXL worker counters: {submitted}/{consumed}/{released}")
        if partial:
            patches = [re.fullmatch(r"PARTIAL_COUNTS submitted=(\d+) rect=240,180,160,120", line)
                       for line in lines if line.startswith("PARTIAL_COUNTS ")]
            if len(patches) != 1 or patches[0] is None or int(patches[0].group(1)) < 4:
                raise AssertionError("missing actual partial QXL draw commands")
        if agent is not None:
            capability = int(agent.endswith("full"))
            required = ["AGENT_CLIENT_CAPS", f"AGENT_CAPS_SENT monitors={capability} clipboard={capability}",
                        "AGENT_CAPS_DELIVERED", "AGENT_REMOVED", "AGENT_RESULT received=1 delivered=1 removed=1 error=0"]
            if any(lines.count(marker) != 1 for marker in required):
                raise AssertionError(f"{name}: incomplete synthetic guest-agent exchange")
            if agent in ("clipboard-full", "clipboard-invalid-full"):
                clip_markers = ["AGENT_CLIP_HOST_GRAB", "AGENT_CLIP_HOST_REQUEST", "AGENT_CLIP_HOST_UTF8_OK",
                                "AGENT_CLIP_GUEST_GRAB", "AGENT_CLIP_GUEST_REQUEST", "AGENT_CLIP_GUEST_UTF8_SENT"]
                if agent == "clipboard-invalid-full":
                    for stage in range(1, 4):
                        clip_markers.extend([f"AGENT_CLIP_INVALID_GRAB stage={stage}", f"AGENT_CLIP_INVALID_SENT stage={stage}"])
                clip_markers.append("AGENT_CLIP_RESULT host=1 guest-request=1 guest-sent=1")
                if agent == "clipboard-invalid-full":
                    clip_markers.append("AGENT_CLIP_INVALID_RESULT requests=3 sent=3")
                actual_clip = [line for line in lines if line.startswith("AGENT_CLIP_")]
                if actual_clip != clip_markers:
                    raise AssertionError(f"{name}: incomplete wire clipboard exchange {actual_clip}")
            if agent.startswith("monitor-"):
                if [line for line in lines if line.startswith("DISPLAY_INITIALIZED ")] != ["DISPLAY_INITIALIZED tls=1"]:
                    raise AssertionError(f"{name}: expected one TLS display channel")
                summaries = [re.fullmatch(r"AGENT_MONITOR_RESULT requests=(\d+) targets=(\d+)", line)
                             for line in lines if line.startswith("AGENT_MONITOR_RESULT ")]
                if len(summaries) != 1 or summaries[0] is None:
                    raise AssertionError(f"{name}: missing actual monitor wire counts")
                requests, targets = map(int, summaries[0].groups())
                target_lines = lines.count("AGENT_MONITOR_REQUEST width=1024 height=768")
                if capability:
                    if not 1 <= targets <= requests or target_lines < targets:
                        raise AssertionError(f"{name}: no matching monitor configuration on wire")
                elif targets or target_lines:
                    raise AssertionError(f"{name}: sent target to limited agent")
                counts = [re.fullmatch(r"DRAW_COUNTS submitted=(\d+) consumed=(\d+) released=(\d+)", line)
                          for line in lines if line.startswith("DRAW_COUNTS ")]
                if len(counts) != 1 or counts[0] is None:
                    raise AssertionError(f"{name}: missing display lifecycle counts")
                submitted, consumed, released = map(int, counts[0].groups())
                if not 0 < consumed <= submitted or not 0 <= released <= consumed:
                    raise AssertionError(f"{name}: invalid draw lifecycle")
                if agent == "monitor-resize-full" and lines.count("AGENT_PRIMARY_RESIZED 1024x768") != 1:
                    raise AssertionError(f"{name}: missing server primary surface resize")
                print(f"METRIC {name} wire-requests={requests} matching-targets={targets}")
        if success and initialized != ["MAIN_INITIALIZED tls=1"] * (1 if agent is not None else 2 if display else 3):
            raise AssertionError(f"{name}: unexpected TLS main-channel initializations: {initialized}")
        if not success and initialized:
            raise AssertionError(f"{name}: rejected ticket initialized a channel")
        print(f"{name}: authenticated TLS main channels={len(initialized)}")


def compile_native_probe(app, destination):
    frameworks = app / "Contents" / "Frameworks"
    names = ("libspice-client-glib-2.0.8.dylib", "libgio-2.0.0.dylib",
             "libgobject-2.0.0.dylib", "libglib-2.0.0.dylib")
    libraries = [frameworks / name for name in names]
    if not all(path.is_file() for path in libraries):
        raise RuntimeError("native probe: packaged dylibs missing")
    flags = shlex.split(subprocess.check_output(
        ["pkg-config", "--cflags", "spice-client-glib-2.0"], text=True))
    subprocess.run(["xcrun", "clang", "-std=c11", *flags,
                    str(HERE / "spice-native-multi.c"), "-o", str(destination),
                    *map(str, libraries), "-Wl,-rpath," + str(frameworks)],
                   check=True, timeout=60)
    # Check linkage before executing: probe must not link host copies.
    linked = subprocess.check_output(["/usr/bin/otool", "-L", str(destination)], text=True)
    print(linked)
    if "/opt/homebrew/" in linked or "/usr/local/" in linked:
        raise RuntimeError("native probe: unexpected host dylib dependency")
    for name in names:
        if "@rpath/" + name not in linked:
            raise RuntimeError(f"native probe: missing packaged dependency {name}")


def validate_multi_metrics(lines):
    """Require one sustained, measurable window per phase; no CI speed threshold."""
    expected = {(i, 4): set(range(4)) for i in range(4)}
    expected[(2, 3)] = {0, 2, 3}
    resources = {}
    samples = {}
    gpu = {}
    for line in lines:
        if line.startswith("MRV_MULTI_RESOURCES "):
            match = re.fullmatch(
                r"MRV_MULTI_RESOURCES active=(\d+) live=(\d+) elapsed-ms=(\d+) cpu-ms=(\d+) peak-rss-bytes=(\d+)", line)
            if not match:
                raise AssertionError("malformed resource metrics")
            active, live, elapsed, cpu, rss = map(int, match.groups())
            key = (active, live)
            if key not in expected or key in resources or elapsed < 3000 or rss <= 0:
                raise AssertionError(f"invalid resource metrics: {line}")
            resources[key] = elapsed
            print(f"METRIC phase={active}/{live} process-cpu-percent={100 * cpu / elapsed:.1f} peak-rss-MiB={rss / 1048576:.2f}")
        elif line.startswith("MRV_MULTI_SAMPLES "):
            match = re.fullmatch(
                r"MRV_MULTI_SAMPLES active=(\d+) live=(\d+) session=(\d+) count=(\d+) elapsed-ms=(\d+)", line)
            if not match:
                raise AssertionError("malformed sample metrics")
            active, live, session, count, elapsed = map(int, match.groups())
            key = (active, live)
            if (key not in expected or session not in expected[key] or
                    (key, session) in samples or count <= 0 or elapsed < 3000):
                raise AssertionError(f"invalid sample metrics: {line}")
            samples[(key, session)] = (elapsed, count)
            print(f"METRIC phase={active}/{live} session={session} gpu-readback-completions-per-second={1000 * count / elapsed:.2f}")
        elif line.startswith("MRV_MULTI_GPU "):
            match = re.fullmatch(
                r"MRV_MULTI_GPU active=(\d+) live=(\d+) session=(\d+) valid=(\d+) unavailable=(\d+) total-ns=(\d+) max-ns=(\d+)", line)
            if not match:
                raise AssertionError("malformed GPU metrics")
            active, live, session, valid, unavailable, total, maximum = map(int, match.groups())
            key = ((active, live), session)
            if key in gpu or valid + unavailable <= 0:
                raise AssertionError(f"invalid GPU metrics: {line}")
            if valid:
                if not 0 < maximum <= total <= valid * maximum + valid:
                    raise AssertionError(f"inconsistent GPU durations: {line}")
                print(f"METRIC phase={active}/{live} session={session} gpu-command-mean-ms={total / valid / 1e6:.3f} gpu-command-max-ms={maximum / 1e6:.3f} valid={valid} unavailable={unavailable}")
            else:
                if total or maximum:
                    raise AssertionError(f"duration without timestamps: {line}")
                print(f"METRIC phase={active}/{live} session={session} gpu-command-timing=unavailable samples={unavailable}")
            gpu[key] = valid + unavailable
    if set(resources) != set(expected) or set(samples) != {
            (key, session) for key, sessions in expected.items() for session in sessions}:
        raise AssertionError("incomplete multi-session metrics")
    if any(elapsed != resources[key] for (key, _), (elapsed, _) in samples.items()):
        raise AssertionError("inconsistent phase measurement window")
    if gpu != {key: count for key, (_, count) in samples.items()}:
        raise AssertionError("missing or inconsistent GPU timestamp sample counts")


def validate_workspace_soak(lines):
    samples = []
    pattern = re.compile(
        r"MRV_WORKSPACE_SOAK phase=(\d+) elapsed-ms=(\d+) rss-bytes=(\d+) "
        r"peak-rss-bytes=(\d+) cpu-ms=(\d+) live=(\d+)")
    for line in lines:
        if not line.startswith("MRV_WORKSPACE_SOAK "):
            continue
        match = pattern.fullmatch(line)
        if not match:
            raise AssertionError("malformed workspace soak measurement")
        phase, elapsed, rss, peak, cpu, live = map(int, match.groups())
        if phase != len(samples) or phase > 7 or rss <= 0 or peak <= 0:
            raise AssertionError(f"invalid workspace soak sample: {line}")
        if live != (0 if phase == 7 else 4):
            raise AssertionError(f"workspace soak session count: {line}")
        if phase and (elapsed <= samples[-1][0] or cpu < samples[-1][3] or peak < samples[-1][2]):
            raise AssertionError("non-monotonic elapsed/CPU/peak RSS")
        if 1 <= phase <= 6 and elapsed < phase * 10000:
            raise AssertionError("workspace soak interval too short")
        samples.append((elapsed, rss, peak, cpu))
    if len(samples) != 8:
        raise AssertionError("missing workspace soak/cleanup measurements")
    start, end, closed = samples[0], samples[6], samples[7]
    if end[0] - start[0] < 59900:
        raise AssertionError("workspace soak did not sustain four sessions for 60 seconds")
    print(f"METRIC workspace-soak duration-ms={end[0]-start[0]} "
          f"rss-start-MiB={start[1]/1048576:.2f} rss-end-MiB={end[1]/1048576:.2f} "
          f"rss-max-sampled-MiB={max(s[1] for s in samples[:7])/1048576:.2f} "
          f"rss-delta-MiB={(end[1]-start[1])/1048576:.2f} "
          f"rss-after-close-MiB={closed[1]/1048576:.2f} "
          f"cpu-percent={100*(end[3]-start[3])/(end[0]-start[0]):.2f}")


def validate_workspace_churn(lines):
    """Check actual reconnect cycles; weak-reference counts are diagnostic."""
    samples = []
    weak = []
    batches = {}
    unhost = []
    metric = re.compile(
        r"MRV_WORKSPACE_CHURN phase=(\d+) elapsed-ms=(\d+) rss-bytes=(\d+) "
        r"peak-rss-bytes=(\d+) cpu-ms=(\d+) live=(\d+)")
    weak_pattern = re.compile(r"MRV_WORKSPACE_WEAK round=(\d+) controllers=(\d+) canvases=(\d+)")
    batch_pattern = re.compile(r"MRV_WORKSPACE_WEAK_BATCH sample=(\d+) batch=(\d+) controllers=(\d+) canvases=(\d+)")
    unhost_pattern = re.compile(r"MRV_WORKSPACE_WEAK_UNHOST before=(\d+) controllers=(\d+) canvases=(\d+)")
    for line in lines:
        if line.startswith("MRV_WORKSPACE_WEAK_BATCH "):
            m = batch_pattern.fullmatch(line)
            if not m:
                raise AssertionError("invalid weak batch diagnostic")
            sample, batch, controllers, canvases = map(int, m.groups())
            if not 0 <= batch <= sample <= 3 or max(controllers, canvases) > 4 or (sample, batch) in batches:
                raise AssertionError(f"invalid weak batch: {line}")
            batches[(sample, batch)] = (controllers, canvases)
        elif line.startswith("MRV_WORKSPACE_WEAK_UNHOST "):
            m = unhost_pattern.fullmatch(line)
            if not m:
                raise AssertionError("invalid host teardown diagnostic")
            unhost.append(tuple(map(int, m.groups())))
        elif line.startswith("MRV_WORKSPACE_CHURN "):
            m = metric.fullmatch(line)
            if not m:
                raise AssertionError("invalid churn resource sample")
            phase, elapsed, rss, peak, cpu, live = map(int, m.groups())
            if phase != len(samples) or phase > 3 or not rss or not peak or live:
                raise AssertionError(f"invalid churn phase: {line}")
            if samples and (elapsed <= samples[-1][0] or peak < samples[-1][2] or cpu < samples[-1][3]):
                raise AssertionError("non-monotonic churn resource samples")
            samples.append((elapsed, rss, peak, cpu))
        elif line.startswith("MRV_WORKSPACE_WEAK "):
            m = weak_pattern.fullmatch(line)
            if not m:
                raise AssertionError("invalid churn weak-reference sample")
            phase, controllers, canvases = map(int, m.groups())
            if phase != len(weak) or phase > 3 or max(controllers, canvases) > 4 * (phase + 1):
                raise AssertionError(f"invalid survivor count: {line}")
            weak.append((controllers, canvases))
    if len(samples) != 4 or len(weak) != 4:
        raise AssertionError("incomplete churn metrics")
    if set(batches) != {(sample, batch) for sample in range(4) for batch in range(sample + 1)}:
        raise AssertionError("missing per-batch weak references")
    for sample, (controllers, canvases) in enumerate(weak):
        if (controllers, canvases) != tuple(sum(batches[(sample, batch)][i] for batch in range(sample + 1))
                                          for i in range(2)):
            raise AssertionError("weak-reference totals disagree with batch counts")
    if len(unhost) != 1 or max(unhost[0]) > 16:
        raise AssertionError("missing or invalid final host teardown diagnostic")
    before, after, canvases = unhost[0]
    print(f"METRIC workspace-unhost controllers-before={before} controllers-after={after} canvases-after={canvases}")
    expected = []
    for i in range(1, 4):
        expected.extend([f"MRV_WORKSPACE_CHURN_OPEN_OK round={i} live=4",
                         f"MRV_WORKSPACE_CHURN_CLOSE_OK round={i} live=0 views=0"])
    markers = [line for line in lines if line.startswith(("MRV_WORKSPACE_CHURN_OPEN_OK ", "MRV_WORKSPACE_CHURN_CLOSE_OK "))]
    if markers != expected or lines.count("MRV_WORKSPACE_CHURN_OK cycles=4 sessions=16") != 1:
        raise AssertionError("incomplete repeated workspace lifecycle")
    for i, ((elapsed, rss, peak, cpu), (controllers, canvases)) in enumerate(zip(samples, weak)):
        print(f"METRIC workspace-churn round={i} rss-MiB={rss/1048576:.2f} "
              f"rss-delta-MiB={(rss-samples[0][1])/1048576:.2f} "
              f"weak-controllers={controllers} weak-canvases={canvases}")


def test_multi(app, root, fixture, native_probe=None, wrapper_only=False, workspace=False):
    """Four simultaneous servers with non-overlapping color pairs."""
    servers = []
    profiles = []
    logs = []
    with ExitStack() as stack:
        # Keep four port reservations until all distinct ports have been chosen.
        reservations = [stack.enter_context(socket.socket()) for _ in range(4)]
        for sock in reservations:
            sock.bind(("127.0.0.1", 0))
        ports = [sock.getsockname()[1] for sock in reservations]
        for sock in reservations:
            sock.close()
        try:
            for i, port in enumerate(ports):
                prefix = ("native" if native_probe is not None else "wrapper" if wrapper_only
                          else "workspace" if workspace else "multi")
                profile = root / f"{prefix}-{i}.vv"
                profile.write_text(tls.fixture_profile(port, root / "trusted.pem", tls.SUBJECT))
                profiles.append(profile)
                log = root / f"{prefix}-{i}.log"
                logs.append(log)
                output = stack.enter_context(log.open("wb"))
                server = subprocess.Popen([
                    str(fixture), str(port), str(root / "trusted.pem"),
                    str(root / "server.pem"), str(root / "server.key"), tls.TICKET,
                    "workspace" if workspace else "display", str(i),
                ], stdout=output, stderr=subprocess.STDOUT)
                servers.append(server)
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                if any(server.poll() is not None for server in servers):
                    raise RuntimeError("multi: fixture exited before ready")
                if all("READY" in log.read_text(errors="replace").splitlines() for log in logs):
                    break
                time.sleep(0.05)
            else:
                raise RuntimeError("multi: fixtures not ready")
            env = {k: v for k, v in os.environ.items() if not k.startswith(("DYLD_", "GST_", "OPENSSL_"))}
            for key in list(env):
                if key.lower() in ("http_proxy", "https_proxy", "all_proxy", "no_proxy", "spice_proxy"):
                    env.pop(key)
            env["NO_PROXY"] = "127.0.0.1"
            env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
            env["GST_REGISTRY"] = str(root / "gst-registry.bin")
            exe = app / "Contents" / "MacOS" / "Mac Remote Viewer"
            env["MRV_GLIB_TRACE"] = "1"
            library = app / "Contents" / "Frameworks" / "libspice-client-glib-2.0.8.dylib"
            if library.is_file():
                symbols = subprocess.run(["/usr/bin/nm", "-u", str(library)],
                                         capture_output=True, text=True, timeout=15, check=True)
                candidates = [line for line in symbols.stdout.splitlines()
                              if any(term in line for term in ("context", "longjmp", "setjmp", "g_thread_new"))]
                print("MRV_COROUTINE_IMPORTS")
                print("\n".join(candidates)[:6000])
            if native_probe is not None:
                env["G_DEBUG"] = "fatal-criticals"
                command = [str(native_probe), str(root / "trusted.pem"), *map(str, ports)]
            else:
                mode = ("--loopback-spice-wrapper-probe" if wrapper_only else
                        "--loopback-spice-workspace-probe" if workspace else "--loopback-spice-multi-probe")
                command = [str(exe), mode, *map(str, profiles)]
            result = subprocess.run(command, cwd=root, env=env,
                                    capture_output=True, text=True, timeout=540 if workspace else 110)
            print(result.stdout[-12000:])
            if result.stderr:
                print(result.stderr[-16000:])
            if result.returncode:
                raise AssertionError(f"multi: client failed (exit={result.returncode})")
            if "MRV_GLIB_CRITICAL" in result.stderr or "CRITICAL GLib" in result.stdout:
                raise AssertionError("multi: GLib critical during concurrent sessions")
            lines = result.stdout.splitlines()
            if native_probe is None:
                connect_calls = [line for line in result.stderr.splitlines()
                                 if line.startswith("MRV_CONN_CONNECT session=")]
                expected_connects = 16 if workspace else 4
                # Allocators may reuse a freed GObject address in a later cycle.
                # Each simultaneous batch must still contain four distinct sessions.
                if len(connect_calls) != expected_connects or any(
                        len(set(connect_calls[i:i+4])) != 4 for i in range(0, len(connect_calls), 4)):
                    raise AssertionError(f"probe: expected {expected_connects} connect calls in distinct four-session batches, got {len(connect_calls)}")
                if "MRV_PROBE_WORKSPACE_EMPTY" not in lines:
                    raise AssertionError("probe: normal workspace must remain empty")
            if native_probe is not None:
                if "MRV_NATIVE_MULTI_OK" not in lines:
                    raise AssertionError("native multi: missing success marker")
            elif wrapper_only:
                if "MRV_WRAPPER_MULTI_OK" not in lines:
                    raise AssertionError("wrapper multi: missing success marker")
            elif workspace:
                switches = [line for line in lines if line.startswith("MRV_WORKSPACE_SWITCH_OK ")]
                expected = [f"MRV_WORKSPACE_SWITCH_OK step={step} selected={selected} live=4"
                            for step, selected in enumerate((0, 1, 2, 3, 0, 2, 1, 3) * 3)]
                if switches != expected:
                    raise AssertionError("workspace: incomplete SwiftUI selection checks")
                validate_workspace_soak(lines)
                validate_workspace_churn(lines)
                for marker in ("MRV_WORKSPACE_SOAK_OK seconds=60 checkpoints=7",
                               "MRV_WORKSPACE_BACKGROUND_CLOSE_OK selected=3 live=3",
                               "MRV_WORKSPACE_ACTIVE_CLOSE_OK selected=2 live=2",
                               "MRV_WORKSPACE_CLEANUP_BEGIN",
                               "MRV_WORKSPACE_CLEANUP_STATE sessions=0 views=0 disconnected=4 normal=0",
                               "MRV_WORKSPACE_OK"):
                    if lines.count(marker) != 1:
                        raise AssertionError(f"workspace: missing {marker}")
            else:
                phases = [line for line in lines if line.startswith("MRV_MULTI_PHASE_OK ")]
                if phases != [f"MRV_MULTI_PHASE_OK active={i} live=4 targets=60,15" for i in range(4)]:
                    raise AssertionError("multi: missing foreground/background phases")
                if "MRV_MULTI_CLOSE_OK live=3" not in lines or "MRV_MULTI_OK" not in lines:
                    raise AssertionError("multi: missing close/isolation success")
                validate_multi_metrics(lines)
        finally:
            # Give the peer disconnects a bounded interval to drain on each
            # fixture's GLib loop before requesting orderly VM shutdown.
            time.sleep(0.5)
            for server in servers:
                if server.poll() is None:
                    server.terminate()
            for server, log in zip(servers, logs):
                try:
                    server.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait(timeout=5)
                print(f"{log.stem}: exit={server.returncode}")
                print(log.read_text(errors="replace")[-4000:])
        for server, log in zip(servers, logs):
            lines = log.read_text(errors="replace").splitlines()
            if server.returncode != 0:
                raise AssertionError(f"{log.stem}: abnormal exit")
            for channel in ("MAIN", "DISPLAY"):
                initialized = [line for line in lines if line.startswith(f"{channel}_INITIALIZED ")]
                if initialized != [f"{channel}_INITIALIZED tls=1"] * (4 if workspace else 1):
                    raise AssertionError(f"{log.stem}: unexpected channels: {initialized}")
            counts = [re.fullmatch(r"DRAW_COUNTS submitted=(\d+) consumed=(\d+) released=(\d+)", line)
                      for line in lines if line.startswith("DRAW_COUNTS ")]
            if len(counts) != 1 or counts[0] is None:
                raise AssertionError(f"{log.stem}: missing counters")
            submitted, consumed, released = map(int, counts[0].groups())
            if not 0 < consumed <= submitted or not 0 <= released <= consumed:
                raise AssertionError(f"{log.stem}: invalid draw lifecycle")
    print("Native four-session channel checks passed." if native_probe is not None
          else ("Wrapper four-session channel checks passed." if wrapper_only
                else "Real SwiftUI workspace checks passed." if workspace
                else "Real four-session display isolation checks passed."))


def test_clipboard_isolation(app, root, fixture):
    servers = []
    profiles = []
    with ExitStack() as stack:
        try:
            for role in range(2):
                with socket.socket() as reserved:
                    reserved.bind(("127.0.0.1", 0))
                    port = reserved.getsockname()[1]
                profile = root / f"clipboard-isolation-{role}.vv"
                profile.write_text(tls.fixture_profile(port, root / "trusted.pem", tls.SUBJECT))
                profiles.append(profile)
                log = root / f"clipboard-isolation-{role}.log"
                output = stack.enter_context(log.open("wb"))
                server = subprocess.Popen([str(fixture), str(port), str(root / "trusted.pem"),
                    str(root / "server.pem"), str(root / "server.key"), tls.TICKET,
                    "agent-clipboard-isolation", str(role)], stdout=output, stderr=subprocess.STDOUT)
                servers.append((role, server, log))
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    if server.poll() is not None:
                        raise RuntimeError(f"isolation fixture {role} exited early")
                    if "READY" in log.read_text(errors="replace").splitlines():
                        break
                    time.sleep(0.05)
                else:
                    raise RuntimeError(f"isolation fixture {role} not ready")
            env = {k: v for k, v in os.environ.items() if not k.startswith(("DYLD_", "GST_", "OPENSSL_"))}
            for key in list(env):
                if key.lower() in ("http_proxy", "https_proxy", "all_proxy", "no_proxy", "spice_proxy"):
                    env.pop(key)
            env["NO_PROXY"] = "127.0.0.1"
            env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
            env["GST_REGISTRY"] = str(root / "gst-registry.bin")
            exe = app / "Contents" / "MacOS" / "Mac Remote Viewer"
            result = subprocess.run([str(exe), "--loopback-spice-clipboard-isolation-probe",
                                     *map(str, profiles)], cwd=root, env=env, capture_output=True,
                                    text=True, timeout=35)
            print(result.stdout[-6000:])
            if result.stderr:
                print(result.stderr[-6000:])
            expected = ["MRV_CLIP_ISOLATION_B_OK", "MRV_CLIP_ISOLATION_BACKGROUND_OK",
                        "MRV_CLIP_ISOLATION_A_OK", "MRV_CLIP_ISOLATION_OK"]
            actual = [line for line in result.stdout.splitlines() if line.startswith("MRV_CLIP_ISOLATION_")]
            if result.returncode != 0 or actual != expected:
                raise AssertionError(f"clipboard isolation app lifecycle: {actual}")
        finally:
            for role, server, log in servers:
                if server.poll() is None:
                    server.terminate()
            for role, server, log in servers:
                try:
                    server.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait(timeout=5)
                print(f"clipboard isolation fixture {role}: exit={server.returncode}")
                print(log.read_text(errors="replace")[-6000:])
        for role, server, log in servers:
            lines = log.read_text(errors="replace").splitlines()
            if server.returncode != 0 or [line for line in lines if line.startswith("MAIN_INITIALIZED ")] != ["MAIN_INITIALIZED tls=1"]:
                raise AssertionError(f"isolation fixture {role}: invalid TLS lifecycle")
            required = ["AGENT_CLIP_HOST_UTF8_OK", "AGENT_CLIP_GUEST_REQUEST",
                        "AGENT_CLIP_RESULT host=1 guest-request=1 guest-sent=1",
                        f"AGENT_ISOLATION_RESULT role={role} probes={3 if role == 0 else 0} grabs=1 requests=1 data=1"]
            if any(lines.count(marker) != 1 for marker in required):
                raise AssertionError(f"isolation fixture {role}: unexpected clipboard exchange/counts")
            probes = [line for line in lines if line.startswith("AGENT_ISOLATION_PROBE ")]
            if probes != ([f"AGENT_ISOLATION_PROBE stage={i}" for i in range(1, 4)] if role == 0 else []):
                raise AssertionError(f"isolation fixture {role}: missing background attempts")
            if role == 0 and lines.index("AGENT_ISOLATION_PROBE stage=3") >= lines.index("AGENT_CLIP_HOST_GRAB"):
                raise AssertionError("background attempts did not precede foreground exchange")
    print("Real two-session clipboard isolation checks passed.")


def test_clipboard_security(app, root):
    exe = app / "Contents" / "MacOS" / "Mac Remote Viewer"
    env = {k: v for k, v in os.environ.items() if not k.startswith(("DYLD_", "GST_", "OPENSSL_"))}
    env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    env["GST_REGISTRY"] = str(root / "gst-registry.bin")
    result = subprocess.run([str(exe), "--clipboard-security-probe"], cwd=root, env=env,
                            capture_output=True, text=True, timeout=30)
    print(result.stdout[-6000:])
    if result.stderr:
        print(result.stderr[-6000:])
    expected = ["MRV_CLIP_SECURITY_INVALID_OVERSIZE_DISABLED_OK",
                "MRV_CLIP_SECURITY_GENERATION_OK",
                "MRV_CLIP_SECURITY_LIMITS_OK item=16777216 snapshot=33554432",
                "MRV_CLIP_SECURITY_OK"]
    actual = [line for line in result.stdout.splitlines() if line.startswith("MRV_CLIP_SECURITY_")]
    if result.returncode != 0 or actual != expected:
        raise AssertionError(f"clipboard security: incomplete boundary checks {actual}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="mrv-spice-auth-") as raw:
        root = Path(raw)
        tls.create_certificates(root)
        fixture = root / "spice-auth-fixture"
        compile_fixture(fixture)
        test_case(args.app.resolve(), root, fixture, "valid-ticket", tls.TICKET, True)
        test_case(args.app.resolve(), root, fixture, "wrong-ticket", "mrv-ci-other-ticket", False)
        test_case(args.app.resolve(), root, fixture, "display", tls.TICKET, True, display=True)
        test_case(args.app.resolve(), root, fixture, "partial", tls.TICKET, True, display=True, partial=True)
        test_case(args.app.resolve(), root, fixture, "agent-full", tls.TICKET, True, agent="full")
        test_case(args.app.resolve(), root, fixture, "agent-limited", tls.TICKET, True, agent="limited")
        test_case(args.app.resolve(), root, fixture, "agent-monitor-full", tls.TICKET, True, agent="monitor-full")
        test_case(args.app.resolve(), root, fixture, "agent-monitor-limited", tls.TICKET, True, agent="monitor-limited")
        test_case(args.app.resolve(), root, fixture, "agent-monitor-resize-full", tls.TICKET, True, agent="monitor-resize-full")
        test_case(args.app.resolve(), root, fixture, "agent-clipboard-full", tls.TICKET, True, agent="clipboard-full")
        test_case(args.app.resolve(), root, fixture, "agent-clipboard-invalid-full", tls.TICKET, True, agent="clipboard-invalid-full")
        test_clipboard_security(args.app.resolve(), root)
        test_clipboard_isolation(args.app.resolve(), root, fixture)
        # Run both paths independently even if one fails. Do not weaken or
        # replace the existing production-app integration test.
        failures = []
        native_probe = root / "spice-native-multi"
        try:
            compile_native_probe(args.app.resolve(), native_probe)
            test_multi(args.app.resolve(), root, fixture, native_probe=native_probe)
        except (AssertionError, RuntimeError, OSError, subprocess.SubprocessError) as exc:
            failures.append(f"native: {exc}")
            print(f"MRV_NATIVE_FAILURE {exc}", flush=True)
        try:
            test_multi(args.app.resolve(), root, fixture, wrapper_only=True)
        except (AssertionError, RuntimeError, OSError, subprocess.SubprocessError) as exc:
            failures.append(f"wrapper: {exc}")
            print(f"MRV_WRAPPER_FAILURE {exc}", flush=True)
        try:
            test_multi(args.app.resolve(), root, fixture)
        except (AssertionError, RuntimeError, OSError, subprocess.SubprocessError) as exc:
            failures.append(f"app: {exc}")
            print(f"MRV_APP_FAILURE {exc}", flush=True)
        try:
            test_multi(args.app.resolve(), root, fixture, workspace=True)
        except (AssertionError, RuntimeError, OSError, subprocess.SubprocessError) as exc:
            failures.append(f"workspace: {exc}")
            print(f"MRV_WORKSPACE_FAILURE {exc}", flush=True)
        if failures:
            raise AssertionError("; ".join(failures))
    print("Real SPICE ticket authentication and reconnect checks passed.")


if __name__ == "__main__":
    main()
