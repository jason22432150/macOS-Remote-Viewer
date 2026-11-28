#!/usr/bin/env python3
"""Collect a pinned x264 Git commit without checkout or executing source."""
import argparse
import hashlib
import importlib.util
import io
import json
import os
import re
import subprocess
import tempfile
import tarfile
import zipfile
from pathlib import Path, PurePosixPath

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("recipe_evidence", HERE / "homebrew-recipe-evidence.py")
recipes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recipes)
ARCHIVE = "homebrew-git-source-evidence.zip"
REPO = "https://code.videolan.org/videolan/x264.git"
MAX_TAR = 32 * 1024 * 1024
MAX_COMMIT = 1024 * 1024
MAX_FILES = 20000

def pinned_revision(formula):
    # Match the actual stable declaration, not HEAD or a mutable branch/tag.
    match = re.findall(r'^  url "' + re.escape(REPO) +
                       r'",\s*\n[ ]+revision: "([0-9a-f]{40})"\s*$', formula, re.M)
    if len(match) != 1:
        raise ValueError("missing or ambiguous pinned x264 source")
    return match[0]

def git_hash(kind, raw):
    return hashlib.sha1(kind.encode() + b" " + str(len(raw)).encode() + b"\0" + raw).digest()

def tree_hash(data):
    """Reconstruct Git tree objects from exact file bytes, modes and link targets."""
    if len(data) > MAX_TAR:
        raise ValueError("Git tar exceeds limit")
    tree, seen, directories = {}, set(), set()
    total = 0
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:") as archive:
        for entry in archive:
            p = PurePosixPath(entry.name)
            name = p.as_posix()
            if (not p.parts or p.is_absolute() or ".." in p.parts or ".git" in p.parts
                    or "\\" in entry.name or name != entry.name.rstrip("/")
                    or name in seen or len(seen) >= MAX_FILES):
                raise ValueError("invalid Git tar path")
            seen.add(name)
            if entry.isdir():
                directories.add(name)
                continue
            if entry.isfile():
                total += entry.size
                if total > MAX_TAR:
                    raise ValueError("Git tar expansion limit")
                raw = archive.extractfile(entry).read()
                if len(raw) != entry.size:
                    raise ValueError("truncated Git tar")
                mode = "100755" if entry.mode & 0o111 else "100644"
            elif entry.issym():
                raw = entry.linkname.encode("utf-8")
                mode = "120000"
            else:
                raise ValueError("unsupported Git tar member")
            node = tree
            for part in p.parts[:-1]:
                node = node.setdefault(part, {})
                if not isinstance(node, dict):
                    raise ValueError("Git path collision")
            if p.name in node:
                raise ValueError("Git path collision")
            node[p.name] = (mode, git_hash("blob", raw))
    if not tree:
        raise ValueError("empty Git tree")
    actual_dirs = set()
    def encode(node, prefix=""):
        rows = []
        for name, value in node.items():
            directory = isinstance(value, dict)
            if directory:
                actual_dirs.add(prefix + name)
                mode, oid = "40000", encode(value, prefix + name + "/")
            else:
                mode, oid = value
            key = name.encode("utf-8")
            rows.append((key + (b"/" if directory else b""),
                         mode.encode() + b" " + key + b"\0" + oid))
        return git_hash("tree", b"".join(row for _, row in sorted(rows)))
    result = encode(tree).hex()
    if directories - actual_dirs:
        raise ValueError("unrepresented Git tar directory")
    return result

def verify_git(data, commit, revision):
    if (not re.fullmatch(r"[0-9a-f]{40}", revision) or len(commit) > MAX_COMMIT
            or git_hash("commit", commit).hex() != revision):
        raise ValueError("Git commit hash mismatch")
    tree = tree_hash(data)
    if commit.split(b"\n", 1)[0] != b"tree " + tree.encode():
        raise ValueError("Git tree hash mismatch")
    return tree

def expected(bom, native, recipe_path):
    report = recipes.verify(recipe_path, bom, native)
    found = [row for row in report["packages"] if row["formula"] == "x264"]
    if len(found) != 1:
        raise ValueError("missing or ambiguous x264 package")
    row = found[0]
    with zipfile.ZipFile(recipe_path) as archive:
        formula = archive.read("x264/" + row["version"] + "/formula.rb").decode("utf-8")
    return {"formula": "x264", "version": row["version"], "repository": REPO,
            "revision": pinned_revision(formula)}

def binding(bom, native, recipe_path):
    return {**recipes.binding(bom, native), "installed_recipe_sha256": recipes.digest(recipe_path)}

def fetch(revision, tar_path, commit_path):
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("invalid Git revision")
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
               GIT_TERMINAL_PROMPT="0", GIT_ALLOW_PROTOCOL="https")
    with tempfile.TemporaryDirectory(prefix="mrv-x264-git-") as raw:
        repo = Path(raw) / "repo"
        def run(*args):
            return subprocess.check_output(["git", "-c", "http.followRedirects=false",
                "-c", "core.hooksPath=/dev/null", *args], env=env, timeout=120)
        run("init", "--bare", str(repo))
        run("-C", str(repo), "fetch", "--depth=1", "--no-tags",
            "--no-recurse-submodules", REPO, revision)
        if run("-C", str(repo), "rev-parse", "FETCH_HEAD").decode().strip() != revision:
            raise ValueError("fetched Git revision mismatch")
        if int(run("-C", str(repo), "cat-file", "-s", revision)) > MAX_COMMIT:
            raise ValueError("commit size exceeds limit")
        commit = run("-C", str(repo), "cat-file", "commit", revision)
        # The fetch is time-bounded, not a network-byte quota. Bound archive
        # output on disk, and never check out or execute upstream code.
        with tar_path.open("xb") as out:
            proc = subprocess.Popen(["git", "-C", str(repo), "archive", "--format=tar", revision],
                                    env=env, stdout=subprocess.PIPE)
            total = 0
            try:
                while True:
                    chunk = proc.stdout.read(1024 * 1024)
                    if not chunk:
                        break
                    total += len(chunk)
                    if total > MAX_TAR:
                        raise ValueError("Git tar size exceeds limit")
                    out.write(chunk)
                if proc.wait(timeout=30):
                    raise ValueError("Git archive failed")
            finally:
                if proc.poll() is None:
                    proc.kill()
                    proc.wait()
                proc.stdout.close()
        tree = verify_git(tar_path.read_bytes(), commit, revision)
        commit_path.write_bytes(commit)
        return tree

def verify(path, bom, native, recipe_path):
    want = expected(bom, native, recipe_path)
    manifest = recipes.build.verify_source_bundle(path, binding(bom, native, recipe_path))
    members = manifest["members"]
    if set(members) not in ({"review.json"}, {"review.json", "source.tar", "commit.raw"}):
        raise ValueError("Git evidence member mismatch")
    with zipfile.ZipFile(path) as archive:
        if members["review.json"]["size"] > 65536:
            raise ValueError("Git review too large")
        report = json.loads(archive.read("review.json"))
        if (report["schema"] != 1 or report["release_ready"] is not False
                or report["source"] != want):
            raise ValueError("Git evidence binding mismatch")
        if report["status"] == "collected":
            if (set(members) != {"review.json", "source.tar", "commit.raw"}
                    or members["source.tar"]["size"] > MAX_TAR
                    or members["commit.raw"]["size"] > MAX_COMMIT):
                raise ValueError("missing or oversized Git source")
            if verify_git(archive.read("source.tar"), archive.read("commit.raw"),
                          want["revision"]) != report["tree"]:
                raise ValueError("Git tree report mismatch")
        elif (report["status"] != "download-unavailable" or set(members) != {"review.json"}
              or "tree" in report):
            raise ValueError("invalid uncollected Git source report")
    return report

def collect(bom, native, recipe_path, output):
    source = expected(bom, native, recipe_path)
    with tempfile.TemporaryDirectory(prefix="mrv-git-source-evidence-") as raw:
        root = Path(raw)
        review, tar, commit = (root / name for name in ("review.json", "source.tar", "commit.raw"))
        entries = {"review.json": review}
        report = {"schema": 1, "release_ready": False, "source": source}
        try:
            report["tree"] = fetch(source["revision"], tar, commit)
        except (OSError, subprocess.SubprocessError):
            report["status"] = "download-unavailable"
        else:
            report["status"] = "collected"
            entries.update({"source.tar": tar, "commit.raw": commit})
        review.write_text(json.dumps(report, sort_keys=True, indent=2) + "\n")
        recipes.build.write_source_bundle(output, entries, binding(bom, native, recipe_path))
    print("MRV_HOMEBREW_GIT_SOURCE_EVIDENCE_OK " +
          json.dumps(verify(output, bom, native, recipe_path), sort_keys=True))

def main():
    parser = argparse.ArgumentParser()
    for name in ("bom", "native-manifest", "recipes", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    args = parser.parse_args()
    collect(args.bom, args.native_manifest, args.recipes, args.output)

if __name__ == "__main__":
    main()
