#!/usr/bin/env python3
"""Preserve locked CocoaSpice source and actual overlay inputs, without ZIP symlinks."""
import argparse
import hashlib
import importlib.util
import io
import json
import os
import stat
import subprocess
import tarfile
import tempfile
import tomllib
import zipfile
from pathlib import Path, PurePosixPath

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("build_spice", HERE / "build-spice-candidate.py")
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)
ARCHIVE = "cocoaspice-source-evidence.zip"
# Both are tracked upstream links. Their exact target bytes must be preserved.
LINKS = {"Sources/CocoaSpiceNoUsb", "Sources/CocoaSpiceRenderer/CSRenderer.h"}
LIMIT = 64 * 1024 * 1024
COUNT = 10000
RECIPES = ("lockfile.toml", "bootstrap-cocoaspice.sh", "cocoaspice/overlay.py",
           "cocoaspice-source-evidence.py", "generate-xcconfig.sh")

def digest(data):
    return hashlib.sha256(data).hexdigest()

def file_digest(path):
    with path.open("rb") as f:
        return hashlib.file_digest(f, "sha256").hexdigest()

def revision():
    with (HERE / "lockfile.toml").open("rb") as f:
        return tomllib.load(f)["cocoaspice"]["revision"]

def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args], timeout=60)

def safe_name(name):
    p = build.source_member(name)
    if ".git" in p.parts:
        raise ValueError("unexpected git metadata in source")
    return p

def record(data, mode):
    return {"sha256": digest(data), "size": len(data), "mode": mode}

def link_record(name, target):
    p = PurePosixPath(target)
    if name not in LINKS or p.is_absolute() or not target or "\\" in target:
        raise ValueError("unexpected source symlink")
    # Relative links may contain '..', but cannot leave the source root.
    parts = list(PurePosixPath(name).parent.parts)
    for piece in p.parts:
        if piece == "..":
            if not parts:
                raise ValueError("source symlink escapes root")
            parts.pop()
        elif piece != ".":
            parts.append(piece)
    return {"target": target, **record(target.encode("utf-8"), 0o120000)}

def snapshot(root):
    """Enumerate all files, including ignored/generated paths; exclude only root .git."""
    files, links = {}, {}
    total = 0
    for current, dirs, names in os.walk(root, followlinks=False):
        base = Path(current)
        if base == root and ".git" in dirs:
            dirs.remove(".git")
        for name in sorted(dirs + names):
            p = base / name
            rel = p.relative_to(root).as_posix()
            safe_name(rel)
            mode = p.lstat().st_mode
            if stat.S_ISLNK(mode):
                if name in dirs:
                    dirs.remove(name)
                target = os.readlink(p)
                links[rel] = link_record(rel, target)
                if not p.resolve(strict=True).is_relative_to(root.resolve()):
                    raise ValueError("source symlink escapes root")
            elif stat.S_ISDIR(mode):
                continue
            elif stat.S_ISREG(mode):
                size = p.stat().st_size
                total += size
                if total > LIMIT or len(files) >= COUNT:
                    raise ValueError("source tree limit exceeded")
                data = p.read_bytes()
                if len(data) != size:
                    raise ValueError("source changed during read")
                files[rel] = record(data, 0o755 if mode & 0o111 else 0o644)
            else:
                raise ValueError("nonregular source entry")
    if not files or set(links) != LINKS:
        raise ValueError("source files or required upstream links missing")
    return {"files": files, "links": links}

def parse_upstream(data):
    """Read locked Git archive without extraction; validate complete member names."""
    if len(data) > LIMIT:
        raise ValueError("upstream archive too large")
    files, links, blobs, seen = {}, {}, {}, set()
    total = 0
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:") as tar:
        for member in tar:
            name = member.name
            safe_name(name)
            if name in seen or len(seen) >= COUNT:
                raise ValueError("duplicate or excessive upstream archive")
            seen.add(name)
            if member.isdir():
                continue
            if member.issym():
                links[name] = link_record(name, member.linkname)
                raw = member.linkname.encode("utf-8")
                mode = "120000"
            elif member.isfile():
                total += member.size
                if total > LIMIT:
                    raise ValueError("upstream archive expansion limit")
                raw = tar.extractfile(member).read()
                mode = "100755" if member.mode & 0o111 else "100644"
                files[name] = record(raw, 0o755 if mode == "100755" else 0o644)
            else:
                raise ValueError("unsupported upstream archive member")
            blobs[name] = (mode, hashlib.sha1(b"blob " + str(len(raw)).encode() + b"\0" + raw).hexdigest())
    if not files or set(links) != LINKS or "LICENSE" not in files:
        raise ValueError("incomplete upstream archive")
    return {"files": files, "links": links}, blobs

def tracked(root, rev):
    result = {}
    for item in git(root, "ls-tree", "-rz", "--full-tree", rev).split(b"\0"):
        if not item:
            continue
        meta, raw_name = item.split(b"\t", 1)
        mode, kind, oid = meta.decode("ascii").split()
        name = raw_name.decode("utf-8")
        safe_name(name)
        if kind != "blob" or mode not in ("100644", "100755", "120000") or name in result:
            raise ValueError("unsupported upstream git entry")
        result[name] = (mode, oid)
    return result

def changes(before, after):
    return build.source_tree_difference(before["files"], after["files"])

def binding(bom, native):
    return {"cocoaspice_revision": revision(), "baseline_sbom_sha256": file_digest(bom),
            "native_manifest_sha256": file_digest(native)}

def verify(path, bom, native):
    manifest = build.verify_source_bundle(path, binding(bom, native))
    members = manifest["members"]
    fixed = {"upstream.tar", "overlay.diff", "review.json", "source-before.json",
             *("recipe/" + n for n in RECIPES)}
    with zipfile.ZipFile(path) as archive:
        upstream, _ = parse_upstream(archive.read("upstream.tar"))
        review = json.loads(archive.read("review.json"))
        before = json.loads(archive.read("source-before.json"))
        after = {"files": {k[len("modified/"):]: v for k, v in members.items()
                           if k.startswith("modified/")}, "links": review["links"]}
        if (review["schema"] != 1 or review["release_ready"] is not False
                or review["revision"] != revision() or before != after
                or upstream["links"] != after["links"]
                or review["changes"] != changes(upstream, after)
                or not any(review["changes"].values())
                or upstream["files"]["LICENSE"] != after["files"].get("LICENSE")
                or set(members) != fixed | {"modified/" + n for n in after["files"]}):
            raise ValueError("CocoaSpice source evidence mismatch")
        for name in RECIPES:
            if members["recipe/" + name]["sha256"] != file_digest(HERE / name):
                raise ValueError("CocoaSpice recipe digest mismatch")
        if not archive.read("overlay.diff").strip():
            raise ValueError("empty overlay diff")
    if json.loads(native.read_text())["cocoaspice_revision"] != revision():
        raise ValueError("native CocoaSpice revision mismatch")
    return review

def collect(root, before_path, bom, native, output):
    rev = revision()
    if git(root, "rev-parse", "HEAD").decode().strip() != rev:
        raise ValueError("CocoaSpice checkout revision mismatch")
    before = json.loads(before_path.read_text())
    after = snapshot(root)
    if before != after:
        raise ValueError("CocoaSpice source changed during app build")
    data = git(root, "archive", "--format=tar", rev)
    upstream, blobs = parse_upstream(data)
    if blobs != tracked(root, rev):
        raise ValueError("upstream archive does not match locked git tree")
    if upstream["links"] != after["links"]:
        raise ValueError("overlay changed upstream symlink targets")
    with tempfile.TemporaryDirectory(prefix="mrv-cocoaspice-") as raw:
        temp = Path(raw)
        tar = temp / "upstream.tar"
        tar.write_bytes(data)
        # Include newly generated overlay files in the diff, without changing the real index.
        index = temp / "index"
        env = dict(os.environ, GIT_INDEX_FILE=str(index))
        def indexed(*args):
            return subprocess.check_output(["git", "-C", str(root), *args], env=env, timeout=60)
        indexed("read-tree", rev)
        indexed("add", "-f", "--all", "--", ".")
        diff = indexed("diff", "--cached", "--binary", "--no-ext-diff", "--no-textconv", rev, "--")
        if not diff:
            raise ValueError("empty overlay diff")
        delta = temp / "overlay.diff"
        delta.write_bytes(diff)
        review = temp / "review.json"
        review.write_text(json.dumps({"schema": 1, "revision": rev, "release_ready": False,
            "links": after["links"], "changes": changes(upstream, after),
            "limitations": "Source evidence only; static linkage and Apache modification/notice obligations still require review."},
            sort_keys=True, indent=2) + "\n")
        entries = {"upstream.tar": tar, "overlay.diff": delta, "review.json": review,
                   "source-before.json": before_path}
        entries.update({"modified/" + n: root / n for n in after["files"]})
        entries.update({"recipe/" + n: HERE / n for n in RECIPES})
        build.write_source_bundle(output, entries, binding(bom, native))
    report = verify(output, bom, native)
    print("MRV_COCOASPICE_SOURCE_EVIDENCE_OK " + json.dumps({
        "files": len(after["files"]), "links": len(after["links"]),
        "changed": {k: len(v) for k, v in report["changes"].items()},
        "release_ready": False}, sort_keys=True))

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkout", type=Path, required=True)
    parser.add_argument("--snapshot", type=Path, required=True)
    parser.add_argument("--bom", type=Path)
    parser.add_argument("--native-manifest", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    root = args.checkout.resolve()
    if not args.output:
        if git(root, "rev-parse", "HEAD").decode().strip() != revision():
            raise ValueError("CocoaSpice checkout revision mismatch")
        with args.snapshot.open("x") as f:
            json.dump(snapshot(root), f, sort_keys=True, indent=2)
            f.write("\n")
        return
    if not args.bom or not args.native_manifest:
        parser.error("collection requires --bom and --native-manifest")
    collect(root, args.snapshot, args.bom, args.native_manifest, args.output)

if __name__ == "__main__":
    main()
