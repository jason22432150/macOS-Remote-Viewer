#!/usr/bin/env python3
"""Preserve exact Homebrew :DATA patch bytes from the observed installed recipes."""
import argparse
import hashlib
import importlib.util
import json
import re
import tempfile
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("recipe_evidence", HERE / "homebrew-recipe-evidence.py")
recipes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recipes)
ARCHIVE = "homebrew-inline-patch-evidence.zip"
MAX_PATCH = 2 * 1024 * 1024

def inline_patch(data):
    """Do not evaluate Ruby or apply a patch; preserve only exact DATA payload."""
    lines = data.splitlines(keepends=True)
    markers = [i for i, line in enumerate(lines) if line.rstrip(b"\r\n") == b"__END__"]
    if len(markers) > 1:
        raise ValueError("ambiguous formula DATA marker")
    boundary = markers[0] if markers else len(lines)
    declarations = [i + 1 for i, line in enumerate(lines[:boundary])
                    if re.match(rb"^[ \t]*patch[ \t]+:DATA(?:[ \t]*(?:#.*)?[\r\n]*)$", line)]
    if not declarations:
        return None
    if len(declarations) != 1 or not markers:
        raise ValueError("ambiguous or missing inline patch body")
    payload = b"".join(lines[boundary + 1:])
    if not payload or len(payload) > MAX_PATCH:
        raise ValueError("invalid inline patch body size")
    return {"declaration_line": declarations[0], "data_line": boundary + 1,
            "sha256": hashlib.sha256(payload).hexdigest(), "size": len(payload)}, payload

def expected(bom, native, recipe_path):
    report = recipes.verify(recipe_path, bom, native)
    rows, members = [], {}
    with zipfile.ZipFile(recipe_path) as archive:
        for item in report["packages"]:
            name, version = item["formula"], item["version"]
            prefix = name + "/" + version
            parsed = inline_patch(archive.read(prefix + "/formula.rb"))
            row = {"formula": name, "version": version, "inline_patch": None}
            if parsed:
                meta, payload = parsed
                member = prefix + "/data.patch"
                row["inline_patch"] = {**meta, "member": member}
                members[member] = payload
            rows.append(row)
    return sorted(rows, key=lambda row: (row["formula"], row["version"])), members

def binding(bom, native, recipe_path):
    return {**recipes.binding(bom, native), "installed_recipe_sha256": recipes.digest(recipe_path)}

def verify(path, bom, native, recipe_path):
    rows, expected_members = expected(bom, native, recipe_path)
    manifest = recipes.build.verify_source_bundle(path, binding(bom, native, recipe_path))
    if set(manifest["members"]) != {"review.json", *expected_members}:
        raise ValueError("inline patch inventory mismatch")
    with zipfile.ZipFile(path) as archive:
        if manifest["members"]["review.json"]["size"] > MAX_PATCH:
            raise ValueError("inline patch review too large")
        report = json.loads(archive.read("review.json"))
        if report != {"schema": 1, "release_ready": False, "packages": rows}:
            raise ValueError("inline patch report mismatch")
        for name, payload in expected_members.items():
            if archive.read(name) != payload:
                raise ValueError("inline patch bytes mismatch")
    return report

def collect(bom, native, recipe_path, output):
    rows, members = expected(bom, native, recipe_path)
    with tempfile.TemporaryDirectory(prefix="mrv-inline-patches-") as raw:
        root = Path(raw)
        entries = {}
        for i, (name, data) in enumerate(sorted(members.items())):
            path = root / str(i)
            path.write_bytes(data)
            entries[name] = path
        review = root / "review.json"
        review.write_text(json.dumps({"schema": 1, "release_ready": False, "packages": rows},
                                     sort_keys=True, indent=2) + "\n")
        entries["review.json"] = review
        recipes.build.write_source_bundle(output, entries, binding(bom, native, recipe_path))
    report = verify(output, bom, native, recipe_path)
    print("MRV_HOMEBREW_INLINE_PATCH_EVIDENCE_OK " + json.dumps({
        "kegs": len(report["packages"]),
        "inline_patch_kegs": [row["formula"] for row in rows if row["inline_patch"]],
        "release_ready": False}, sort_keys=True))

def main():
    parser = argparse.ArgumentParser()
    for name in ("bom", "native-manifest", "recipes", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    args = parser.parse_args()
    collect(args.bom, args.native_manifest, args.recipes, args.output)

if __name__ == "__main__":
    main()
