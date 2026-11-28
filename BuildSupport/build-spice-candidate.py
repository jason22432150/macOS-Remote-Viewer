#!/usr/bin/env python3
"""Compile the verified receive candidate in a private prefix; never replace Homebrew."""
import argparse
import ctypes
import hashlib
import importlib.util
import io
import json
import os
import re
import shutil
import subprocess
import tarfile
import tomllib
import zipfile
from pathlib import Path, PurePosixPath

HERE = Path(__file__).resolve().parent
SPICE_CLIENT_DYLIB = "libspice-client-glib-2.0.8.dylib"
SPEC = importlib.util.spec_from_file_location("audit_spice_source", HERE / "audit-spice-source.py")
audit = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(audit)


def run(*args, cwd=None, env=None, timeout=600):
    print("+", " ".join(map(str, args)), flush=True)
    subprocess.run(list(map(str, args)), cwd=cwd, env=env, check=True, timeout=timeout)


def capture(*args, env=None):
    return subprocess.check_output(list(map(str, args)), env=env, text=True, timeout=60).strip()


def sha(data):
    return hashlib.sha256(data).hexdigest()


def read_locked_patch(path, digest):
    """Read the exact audited downstream patch; never trust mutable network content."""
    with path.open("rb") as handle:
        data = handle.read(2 * 1024 * 1024 + 1)
    if len(data) > 2 * 1024 * 1024 or not re.fullmatch(r"[0-9a-f]{64}", digest) or sha(data) != digest:
        raise ValueError("downstream patch checksum/size mismatch")
    return data


def unpack(data, destination, version):
    expected = f"spice-gtk-{version}"
    seen = set()
    total = 0
    with tarfile.open(fileobj=io.BytesIO(data), mode="r|*") as archive:
        for count, member in enumerate(archive, 1):
            path = PurePosixPath(member.name)
            total += max(0, member.size)
            if (count > 100000 or total > audit.MAX_EXPANDED or path.is_absolute()
                    or ".." in path.parts or "\\" in member.name
                    or not path.parts or path.parts[0] != expected
                    or path in seen or not (member.isfile() or member.isdir())):
                raise ValueError(f"unsafe or unsupported source member: {member.name}")
            seen.add(path)
            output = destination.joinpath(*path.parts)
            if member.isdir():
                output.mkdir(parents=True, exist_ok=True)
            else:
                output.parent.mkdir(parents=True, exist_ok=True)
                with archive.extractfile(member) as src, output.open("xb") as dst:
                    shutil.copyfileobj(src, dst)
                output.chmod(0o755 if member.mode & 0o111 else 0o644)
    return destination / expected


SOURCE_BUNDLE = "spice-gtk-candidate-source-evidence.zip"
SOURCE_LIMIT = 384 * 1024 * 1024
SOURCE_COUNT = 100000


def source_tree(source):
    """Hash the exact regular source inputs, including executable mode."""
    files = {}
    total = 0
    for path in sorted(source.rglob("*")):
        if path.is_symlink():
            raise ValueError("unexpected source symlink")
        if path.is_dir():
            continue
        if not path.is_file():
            raise ValueError("unexpected nonregular source")
        size = path.stat().st_size
        total += size
        if len(files) >= SOURCE_COUNT or total > audit.MAX_EXPANDED:
            raise ValueError("source tree expansion limit")
        relative = path.relative_to(source).as_posix()
        files[relative] = {"sha256": sha(path.read_bytes()),
                           "size": size, "mode": 0o755 if path.stat().st_mode & 0o111 else 0o644}
    if not files:
        raise ValueError("empty source tree")
    return files


def source_tree_difference(before, after):
    """Never silently filter generated files or changes to build inputs."""
    return {
        "added": {name: after[name] for name in sorted(after.keys() - before.keys())},
        "removed": {name: before[name] for name in sorted(before.keys() - after.keys())},
        "changed": {name: {"before": before[name], "after": after[name]}
                    for name in sorted(before.keys() & after.keys()) if before[name] != after[name]},
    }


def verify_unchanged_source(source, before, evidence):
    difference = source_tree_difference(before, source_tree(source))
    (evidence / "source-tree-difference.json").write_text(
        json.dumps(difference, indent=2, sort_keys=True) + "\n")
    if any(difference.values()):
        counts = ", ".join(f"{key}={len(value)}" for key, value in difference.items())
        raise ValueError(f"source tree changed during candidate build ({counts}); see source-tree-difference.json")


def source_member(name):
    path = PurePosixPath(name)
    if (not name or path.is_absolute() or ".." in path.parts or "\\" in name
            or path.as_posix() != name or name.endswith("/")):
        raise ValueError("unsafe source evidence member")
    return path


def write_source_bundle(destination, entries, binding):
    """Fixed names and modes; per-member checksums, no host timestamps."""
    inventory = {}
    total = 0
    with zipfile.ZipFile(destination, "x", compression=zipfile.ZIP_DEFLATED) as archive:
        for name, path in sorted(entries.items()):
            source_member(name)
            if name == "manifest.json" or path.is_symlink() or not path.is_file():
                raise ValueError("invalid source evidence input")
            size = path.stat().st_size
            total += size
            if len(inventory) >= SOURCE_COUNT or total > SOURCE_LIMIT:
                raise ValueError("source evidence expansion limit")
            data = path.read_bytes()
            if len(data) != size:
                raise ValueError("source evidence input changed")
            mode = 0o755 if path.stat().st_mode & 0o111 else 0o644
            inventory[name] = {"sha256": sha(data), "size": size, "mode": mode}
            info = zipfile.ZipInfo(name)
            info.create_system = 3
            info.external_attr = (0o100000 | mode) << 16
            archive.writestr(info, data, compress_type=zipfile.ZIP_DEFLATED)
        info = zipfile.ZipInfo("manifest.json")
        info.create_system = 3
        info.external_attr = 0o100644 << 16
        data = (json.dumps({"schema": 1, "binding": binding, "members": inventory},
                           sort_keys=True, indent=2) + "\n").encode()
        if len(data) > 16 * 1024 * 1024:
            raise ValueError("source manifest too large")
        archive.writestr(info, data, compress_type=zipfile.ZIP_DEFLATED)
    return verify_source_bundle(destination, binding)


def verify_source_bundle(path, binding):
    """Verify without extraction; do not trust ZIP names or manifest alone."""
    with zipfile.ZipFile(path) as archive:
        infos = archive.infolist()
        names = [item.filename for item in infos]
        if (len(names) > SOURCE_COUNT + 1 or len(names) != len(set(names))
                or "manifest.json" not in names
                or sum(item.file_size for item in infos) > SOURCE_LIMIT + 16 * 1024 * 1024):
            raise ValueError("invalid source bundle inventory")
        for item in infos:
            source_member(item.filename)
            if item.is_dir() or (item.external_attr >> 16) & 0o170000 != 0o100000:
                raise ValueError("nonregular source evidence member")
        if archive.getinfo("manifest.json").file_size > 16 * 1024 * 1024:
            raise ValueError("source manifest too large")
        manifest = json.loads(archive.read("manifest.json"))
        if (manifest["schema"] != 1 or manifest["binding"] != binding
                or set(manifest["members"]) != set(names) - {"manifest.json"}):
            raise ValueError("source bundle binding/inventory mismatch")
        for name, expected in manifest["members"].items():
            item = archive.getinfo(name)
            mode = (item.external_attr >> 16) & 0o777
            if (item.file_size != expected["size"] or mode != expected["mode"]
                    or sha(archive.read(name)) != expected["sha256"]):
                raise ValueError("source bundle member mismatch")
    return manifest


def exported_symbols(library):
    # -j prints just symbol names, -U excludes undefined imports.
    return set(capture("nm", "-gjU", library).splitlines())


def install_name(library):
    lines = capture("otool", "-D", library).splitlines()
    if len(lines) != 2:
        raise ValueError("unexpected dylib install name")
    return lines[1]


def tls_load_names(dependencies):
    """Require exactly one SSL/crypto pair with the same Mach-O ABI suffix."""
    matches = {}
    for dependency in dependencies:
        match = re.fullmatch(r"lib(ssl|crypto)\.(\d+(?:\.\d+)*)\.dylib", Path(dependency).name)
        if match:
            kind, abi = match.groups()
            if kind in matches:
                raise ValueError("ambiguous OpenSSL library dependency")
            matches[kind] = (abi, dependency)
    if set(matches) != {"ssl", "crypto"} or matches["ssl"][0] != matches["crypto"][0]:
        raise ValueError("missing or mismatched OpenSSL ABI pair")
    return {kind: item[1] for kind, item in matches.items()}


def linked_dependencies(library):
    # otool -L lists the dylib's own install name first.
    lines = capture("otool", "-L", library).splitlines()[2:]
    return [line.strip().split(" (compatibility version ", 1)[0] for line in lines]


def resolve_tls_pair(library):
    pair = tls_load_names(linked_dependencies(library))
    paths = {kind: Path(value).resolve(strict=True) for kind, value in pair.items()
             if Path(value).is_absolute()}
    if set(paths) != set(pair) or len({path.parent for path in paths.values()}) != 1:
        raise ValueError("OpenSSL libraries do not resolve to the same keg directory")
    libdir = paths["crypto"].parent
    if ("Cellar" not in libdir.parts or libdir.name != "lib"
            or not libdir.parent.parent.name.startswith("openssl@")):
        raise ValueError("OpenSSL dependency is not from a versioned Homebrew keg")
    return paths


def spice_client_library(prefix):
    libdir = (prefix / "lib").resolve(strict=True)
    library = (libdir / SPICE_CLIENT_DYLIB).resolve(strict=True)
    if not library.is_relative_to(libdir) or not library.is_file():
        raise ValueError("spice client library escapes expected prefix or is not a file")
    return library


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--audit", type=Path, required=True)
    parser.add_argument("--work", type=Path, required=True)
    args = parser.parse_args()
    evidence = args.audit.resolve()
    work = args.work.resolve()
    work.mkdir(parents=True, exist_ok=False)
    with (HERE / "lockfile.toml").open("rb") as handle:
        lock = tomllib.load(handle)["spice_gtk"]
    version = lock["version"].split("_", 1)[0]
    archive = (evidence / f"spice-gtk-{version}.tar.xz").read_bytes()
    audit.verify_digest(archive, lock["upstream_sha256"])
    source = unpack(archive, work, version)
    keg = Path(capture("brew", "--prefix", "spice-gtk")).resolve()
    if keg.name != lock["version"]:
        raise ValueError("spice-gtk keg changed")
    formula = (keg / ".brew" / "spice-gtk.rb").read_bytes()
    if formula != (evidence / "installed-formula.rb").read_bytes():
        raise ValueError("installed formula changed since audit")
    formula_text = formula.decode("utf-8")
    if (lock["macos_patch_url"] not in formula_text
            or lock["macos_patch_sha256"] not in formula_text
            or "-#!/usr/bin/python3" not in formula_text
            or "+#!/usr/bin/env python3" not in formula_text):
        raise ValueError("installed formula downstream patch evidence differs")
    downstream = read_locked_patch(HERE / "patches" / "homebrew-macos-drm.patch", lock["macos_patch_sha256"])
    print("Verified vendored Homebrew macOS DRM patch:", lock["macos_patch_sha256"], flush=True)
    (evidence / "homebrew-macos-drm.patch").write_bytes(downstream)
    candidate = evidence / "receive-limits-candidate.patch"
    run("/usr/bin/patch", "-p1", "-F", "0", "-i", candidate, cwd=source)
    run("/usr/bin/patch", "-p1", "-F", "0", "-i",
        evidence / "homebrew-macos-drm.patch", cwd=source)
    keymap = source / "subprojects/keycodemapdb/tools/keymap-gen"
    original = keymap.read_bytes()
    if not original.startswith(b"#!/usr/bin/python3\n"):
        raise ValueError("unexpected keymap-gen shebang")
    keymap.write_bytes(original.replace(b"#!/usr/bin/python3\n", b"#!/usr/bin/env python3\n", 1))
    expected = json.loads((evidence / "candidate.json").read_text())
    if expected["upstream_sha256"] != lock["upstream_sha256"]:
        raise ValueError("candidate source version mismatch")
    for source_name, digest in expected["patched_file_sha256"].items():
        if sha((source / source_name).read_bytes()) != digest:
            raise ValueError(f"patched source mismatch: {source_name}")
    source_before = source_tree(source)
    if not any(name.startswith(("COPYING", "LICENSE")) and "/" not in name
               and entry["size"] > 0 for name, entry in source_before.items()):
        raise ValueError("upstream license text missing")
    build, prefix = work / "build", work / "prefix"
    env = os.environ.copy()
    # spice-common's Python code generator imports modules in the source
    # tree. Prevent interpreter caches at their origin, rather than ignoring
    # files or deleting them after a build. Keep all integrity checks intact.
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    # Select the actual ABI of the locked bottle, not any installed formula.
    baseline = spice_client_library(keg)
    baseline_tls = resolve_tls_pair(baseline)
    tls_libdir = baseline_tls["crypto"].parent
    pc = [str(tls_libdir / "pkgconfig")]
    print("Baseline TLS dependencies:", {k: str(p) for k, p in baseline_tls.items()}, flush=True)
    for formula_name in ("gettext", "gobject-introspection", "spice-protocol", "glib", "gstreamer"):
        base = Path(capture("brew", "--prefix", formula_name)).resolve()
        pc.extend(str(base / suffix) for suffix in ("lib/pkgconfig", "share/pkgconfig"))
    if env.get("PKG_CONFIG_PATH"):
        pc.append(env["PKG_CONFIG_PATH"])
    env["PKG_CONFIG_PATH"] = os.pathsep.join(pc)
    for module in ("openssl", "libssl", "libcrypto"):
        pc_libdir = Path(capture("pkg-config", "--variable=libdir", module, env=env)).resolve(strict=True)
        if pc_libdir != tls_libdir:
            raise ValueError(f"pkg-config {module} does not match baseline TLS keg")
    # Direct invocation of the Xcode clang binary does not necessarily inherit
    # the SDK selection performed by xcrun. Set it explicitly for both compile
    # and link stages, including Meson's initial compiler sanity check.
    sdk = Path(capture("xcrun", "--sdk", "macosx", "--show-sdk-path")).resolve(strict=True)
    if not (sdk / "usr/lib/libSystem.tbd").is_file():
        raise ValueError("selected macOS SDK is missing libSystem.tbd")
    env["SDKROOT"] = str(sdk)
    env["CC"] = capture("xcrun", "--sdk", "macosx", "--find", "clang")
    env["CXX"] = capture("xcrun", "--sdk", "macosx", "--find", "clang++")
    env["MACOSX_DEPLOYMENT_TARGET"] = capture("xcrun", "--sdk", "macosx", "--show-sdk-version")
    import shlex
    flags = "-arch arm64 -isysroot " + shlex.quote(str(sdk))
    # Keep candidate flags reproducible rather than inheriting runner overrides.
    for key in ("CFLAGS", "CXXFLAGS", "CPPFLAGS", "LDFLAGS"):
        env[key] = flags
    print("SDK:", sdk, "deployment:", env["MACOSX_DEPLOYMENT_TARGET"], flush=True)
    print("OpenSSL build version:", capture("pkg-config", "--modversion", "openssl", env=env), flush=True)
    for lang, compiler, extension in (("c", "CC", "c"), ("c++", "CXX", "cc")):
        test_source = work / ("sdk-check." + extension)
        test_executable = work / ("sdk-check-" + extension)
        test_source.write_text("#include <stdio.h>\nint main(void) { return puts(\"SDK OK\") < 0; }\n")
        run(env[compiler], *shlex.split(flags), test_source, "-o", test_executable, env=env)
        if capture("lipo", "-archs", test_executable) != "arm64":
            raise ValueError(f"{lang} SDK preflight architecture mismatch")
        run(test_executable, env=env)
    print("MRV_SPICE_CANDIDATE_SDK_PREFLIGHT_OK", flush=True)
    try:
        run("meson", "setup", build, source, "--prefix", prefix,
            "--buildtype=release", "--wrap-mode=nodownload", env=env)
        run("meson", "compile", "-C", build, env=env)
        run("meson", "install", "-C", build, env=env)
    finally:
        # Preserve complete Meson diagnostics in the always-uploaded evidence,
        # including if setup fails before compilation.
        log = build / "meson-logs" / "meson-log.txt"
        if log.is_file():
            shutil.copyfile(log, evidence / "meson-log.txt")
    library = spice_client_library(prefix)
    print("Installed candidate:", library, flush=True)
    candidate_tls = resolve_tls_pair(library)
    if candidate_tls != baseline_tls:
        raise ValueError("candidate OpenSSL dependencies differ from baseline bottle")
    print("MRV_SPICE_CANDIDATE_TLS_ABI_OK", flush=True)
    if not library.is_relative_to(prefix) or capture("lipo", "-archs", library) != "arm64":
        raise ValueError("candidate architecture/path mismatch")
    if Path(install_name(baseline)).name != Path(install_name(library)).name:
        raise ValueError("candidate ABI install-name mismatch")
    base_symbols = exported_symbols(baseline)
    symbols = exported_symbols(library)
    missing = sorted(base_symbols - symbols)
    extra = sorted(symbols - base_symbols)
    print("ABI baseline exports:", len(base_symbols), "candidate:", len(symbols), flush=True)
    if not base_symbols or missing:
        raise ValueError(f"candidate missing exports: {missing}")
    print(capture("otool", "-L", library), flush=True)
    # Fresh process loads candidate by absolute path, not via the opt alias.
    # g_object_unref is resolved through the candidate dependency closure.
    loaded = ctypes.CDLL(str(library))
    loaded.spice_session_new.restype = ctypes.c_void_p
    loaded.spice_session_new.argtypes = []
    loaded.g_object_unref.argtypes = [ctypes.c_void_p]
    loaded.g_object_unref.restype = None
    session = loaded.spice_session_new()
    if not session:
        raise ValueError("candidate failed to create native SpiceSession")
    loaded.g_object_unref(session)
    report = {
        "scope": "isolated candidate; not linked into app",
        "upstream_sha256": lock["upstream_sha256"],
        "downstream_sha256": lock["macos_patch_sha256"],
        "candidate_patch_sha256": sha(candidate.read_bytes()),
        "baseline_sha256": sha(baseline.read_bytes()),
        "candidate_dylib_sha256": sha(library.read_bytes()),
        "candidate_install_name": install_name(library),
        "baseline_exports": len(base_symbols),
        "candidate_exports": len(symbols),
        "extra_exports": extra,
        "meson": capture("meson", "--version"),
        "sdk_version": env["MACOSX_DEPLOYMENT_TARGET"],
        "compiler": capture(env["CC"], "--version"),
        "openssl": capture("pkg-config", "--modversion", "openssl", env=env),
        "tls_dependencies": {
            kind: {"name": path.name, "sha256": sha(path.read_bytes()),
                   "formula": path.parent.parent.parent.name, "version": path.parent.parent.name}
            for kind, path in baseline_tls.items()
        },
    }
    # Capture the actual pre/post-build source tree, original archive, every
    # modification and build recipe. This is evidence, not legal clearance or
    # a claim of bit-for-bit reproducibility on arbitrary build hosts.
    verify_unchanged_source(source, source_before, evidence)
    recipe = {
        "scope": "modified spice-gtk source evidence only; distribution review incomplete",
        "architecture": "arm64",
        "source_revision": os.environ.get("GITHUB_SHA", "local-unrecorded"),
        "patch_order": ["receive-limits-candidate.patch", "homebrew-macos-drm.patch",
                        "keymap-gen shebang: /usr/bin/python3 -> /usr/bin/env python3"],
        "meson_commands": ["meson setup BUILD SOURCE --prefix PREFIX --buildtype=release --wrap-mode=nodownload",
                           "meson compile -C BUILD", "meson install -C BUILD"],
        "build_flags": flags,
        "python_dont_write_bytecode": env["PYTHONDONTWRITEBYTECODE"],
        "sdk_version": report["sdk_version"],
        "compiler": report["compiler"],
        "meson": report["meson"],
        "ninja": capture("ninja", "--version"),
        "python": capture("python3", "--version"),
        "pkg_config": capture("pkg-config", "--version"),
        "installed_kegs": capture("brew", "list", "--versions").splitlines(),
        "limitations": "No complete dependency source closure or bit-identical rebuild proof; review all licenses before distribution.",
    }
    recipe_path = evidence / "candidate-build-recipe.json"
    recipe_path.write_text(json.dumps(recipe, indent=2) + "\n")
    entries = {"source/" + name: source / name for name in source_before}
    for name in (f"spice-gtk-{version}.tar.xz", "receive-limits-candidate.patch",
                 "homebrew-macos-drm.patch", "candidate.json", "installed-formula.rb",
                 "candidate-build-recipe.json", "source-tree-difference.json"):
        entries["evidence/" + name] = evidence / name
    for name in ("build-spice-candidate.py", "audit-spice-source.py",
                 "spice-receive-candidate.py", "spice-receive-limits.h",
                 "lockfile.toml"):
        entries["recipe/" + name] = HERE / name
    entries["recipe/patches/homebrew-macos-drm.patch"] = HERE / "patches/homebrew-macos-drm.patch"
    for name in ("intro-buildoptions.json", "intro-dependencies.json", "intro-compilers.json"):
        entries["meson/" + name] = build / "meson-info" / name
    binding = {key: report[key] for key in ("upstream_sha256", "downstream_sha256",
                "candidate_patch_sha256", "candidate_dylib_sha256")}
    bundle = evidence / SOURCE_BUNDLE
    manifest = write_source_bundle(bundle, entries, binding)
    if {name.removeprefix("source/"): value for name, value in manifest["members"].items()
            if name.startswith("source/")} != source_before:
        raise ValueError("archived tree differs from compiled tree")
    for name, key in ((f"spice-gtk-{version}.tar.xz", "upstream_sha256"),
                      ("receive-limits-candidate.patch", "candidate_patch_sha256"),
                      ("homebrew-macos-drm.patch", "downstream_sha256")):
        if manifest["members"]["evidence/" + name]["sha256"] != binding[key]:
            raise ValueError("source evidence input digest mismatch")
    report["source_evidence_sha256"] = sha(bundle.read_bytes())
    report["source_evidence_name"] = SOURCE_BUNDLE
    (evidence / (SOURCE_BUNDLE + ".sha256")).write_text(
        f'{report["source_evidence_sha256"]}  {SOURCE_BUNDLE}\n')
    print("MRV_SPICE_CANDIDATE_SOURCE_EVIDENCE_OK", flush=True)
    (evidence / "native-build-report.json").write_text(json.dumps(report, indent=2) + "\n")
    print("MRV_SPICE_CANDIDATE_NATIVE_BUILD_OK", flush=True)
    print("MRV_SPICE_CANDIDATE_ABI_OK", flush=True)
    print("MRV_SPICE_CANDIDATE_SESSION_SMOKE_OK", flush=True)


if __name__ == "__main__":
    main()
