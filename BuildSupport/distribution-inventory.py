#!/usr/bin/env python3
"""Inventory actual candidate distribution inputs; never assert legal clearance."""
import argparse
import hashlib
import importlib.util
import json
import re
import tomllib
from pathlib import Path

HERE = Path(__file__).resolve().parent

def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

audit = load("audit_dependencies", "audit-dependencies.py")
build = load("build_spice_candidate", "build-spice-candidate.py")
recipes = load("homebrew_recipe_evidence", "homebrew-recipe-evidence.py")
cocoa = load("cocoaspice_source_evidence", "cocoaspice-source-evidence.py")
upstream = load("homebrew_upstream_evidence", "homebrew-upstream-evidence.py")
git_source = load("homebrew_git_source_evidence", "homebrew-git-source-evidence.py")
TARGET = "Contents/Frameworks/" + build.SPICE_CLIENT_DYLIB
MODIFIED = "modified:spice-gtk@0.43"
BASE_SPICE = "homebrew:spice-gtk@0.43_1"
HEX = re.compile(r"[0-9a-f]{64}")

def digest(path):
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()

def properties(item):
    entries = item.get("properties", [])
    result = {p["name"]: p["value"] for p in entries}
    if len(result) != len(entries):
        raise ValueError("duplicate SBOM property")
    return result

def inventory(bom):
    """Require every signed file to belong to one recognized distribution group."""
    groups, files, refs = {}, {}, set()
    def add(item, group):
        ref = item["bom-ref"]
        if ref in refs:
            raise ValueError("duplicate SBOM reference")
        refs.add(ref)
        if item["type"] != "file" or item.get("components"):
            raise ValueError("unexpected nested SBOM component")
        name = item["name"]
        path = Path(name)
        if (not name or path.is_absolute() or ".." in path.parts or "\\" in name
                or path.as_posix() != name or ref != "file:" + name or name in files):
            raise ValueError("invalid SBOM file identity")
        hashes = [h["content"] for h in item["hashes"] if h["alg"] == "SHA-256"]
        if len(hashes) != 1 or not HEX.fullmatch(hashes[0]):
            raise ValueError("invalid signed file digest")
        props = properties(item)
        if props.get("mrv:bundle-path") != name:
            raise ValueError("SBOM bundle path mismatch")
        files[name] = {"group": group, "signed_sha256": hashes[0], "properties": props}
        groups.setdefault(group, []).append(name)
    for item in bom["components"]:
        ref = item["bom-ref"]
        if item["type"] == "file":
            add(item, "app-origin-unverified")
            continue
        if ref in refs or item["type"] != "library" or not item.get("components"):
            raise ValueError("unexpected SBOM component group")
        if ref.startswith("homebrew:"):
            if ref != "homebrew:" + item["name"] + "@" + item["version"]:
                raise ValueError("Homebrew component identity mismatch")
        elif ref != MODIFIED or item["version"] != "0.43":
            raise ValueError("unrecognized library component")
        refs.add(ref)
        for child in item["components"]:
            add(child, ref)
            p = files[child["name"]]["properties"]
            if ref.startswith("homebrew:") and (
                p.get("mrv:formula") != item["name"] or p.get("mrv:version") != item["version"]
                or not HEX.fullmatch(p.get("mrv:source-sha256", ""))):
                raise ValueError("missing Homebrew file provenance")
    if not files:
        raise ValueError("empty SBOM inventory")
    return groups, files

def make_inventory(baseline, candidate, audit_report, staging, archive_sha, revision):
    bg, bf = inventory(baseline)
    cg, cf = inventory(candidate)
    if set(bf) != set(cf) or bf.get(TARGET, {}).get("group") != BASE_SPICE:
        raise ValueError("baseline/candidate file coverage mismatch")
    if MODIFIED in bg or cg.get(MODIFIED) != [TARGET]:
        raise ValueError("candidate replacement coverage mismatch")
    if properties(candidate["metadata"]).get("mrv:distribution-scope") != "candidate-test-only; distribution review incomplete":
        raise ValueError("unexpected candidate distribution scope")
    for name, before in bf.items():
        after = cf[name]
        if name == TARGET:
            continue
        if before["group"] != after["group"]:
            raise ValueError("unaffected component group changed")
        for key in ("mrv:source-sha256", "mrv:source-name", "mrv:formula", "mrv:version", "mrv:keg-path"):
            if before["properties"].get(key) != after["properties"].get(key):
                raise ValueError("unaffected source provenance changed")
    target = cf[TARGET]
    props = target["properties"]
    if (props.get("mrv:build-origin") != "locally-built-modified-spice-gtk"
            or "mrv:formula" in props or "mrv:version" in props
            or props.get("mrv:baseline-source-sha256") != bf[TARGET]["properties"].get("mrv:source-sha256")
            or not HEX.fullmatch(archive_sha)
            or props.get("mrv:source-evidence-sha256") != archive_sha
            or staging.get("source_evidence_sha256") != archive_sha
            or staging.get("candidate_raw_sha256") != props.get("mrv:source-sha256")
            or staging.get("candidate_patch_sha256") != props.get("mrv:candidate-patch-sha256")
            or staging.get("candidate_signed_sha256") != target["signed_sha256"]):
        raise ValueError("candidate source/signed binary binding mismatch")
    notices = {}
    advisories = {}
    for key, dest in (("notices", notices), ("packages", advisories)):
        for item in audit_report[key]:
            ref = "homebrew:" + item["formula"] + "@" + item["version"]
            if ref in dest:
                raise ValueError("duplicate baseline audit component")
            dest[ref] = item
        if set(dest) != {g for g in bg if g.startswith("homebrew:")}:
            raise ValueError("baseline audit coverage mismatch")
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("invalid CocoaSpice revision")
    rows = []
    for group, names in sorted(cg.items()):
        row = {"component": group, "signed_files": [
            {"path": name, "sha256": cf[name]["signed_sha256"]} for name in sorted(names)],
            "license_conclusion": None, "review_status": "required",
            "corresponding_source_status": "unverified"}
        if group.startswith("homebrew:"):
            row.update(notice_candidates=notices[group]["files"],
                       notice_status=notices[group]["status"],
                       source_fallback=notices[group].get("source_fallback"),
                       baseline_osv_status=advisories[group]["status"],
                       baseline_advisory_ids=advisories[group]["advisory_ids"])
        elif group == MODIFIED:
            row.update(corresponding_source_status="modified-tree-evidence-collected-review-required",
                       source_evidence_sha256=archive_sha,
                       baseline_osv_status="not-applicable-to-modified-component")
        rows.append(row)
    rows.append({"component": "cocoaspice:" + revision, "signed_files": [],
                 "license_conclusion": None, "review_status": "required",
                 "corresponding_source_status": "overlay-and-static-linkage-review-required"})
    return {"schema": 1, "scope": "candidate-test-only", "release_ready": False,
            "components": rows, "signed_file_count": len(cf),
            "limitations": ["Notice candidates are not license conclusions.",
                            "Baseline OSV evidence does not scan modified or static code.",
                            "CocoaSpice linkage and all other static/system dependencies require review.",
                            "No complete corresponding-source or distribution approval is asserted."]}

def only(root, pattern):
    paths = list(root.rglob(pattern))
    if len(paths) != 1 or not paths[0].is_file() or paths[0].is_symlink():
        raise ValueError(f"expected exactly one regular artifact: {pattern}")
    return paths[0]

def main():
    parser = argparse.ArgumentParser()
    for arg in ("baseline", "candidate", "runtime", "output"):
        parser.add_argument("--" + arg, type=Path, required=True)
    args = parser.parse_args()
    args.baseline_bom = only(args.baseline, "*.bom.json")
    args.candidate_bom = only(args.runtime / "candidate-package", "*.bom.json")
    args.audit = only(args.baseline, "*.dependency-audit.json")
    args.notices = only(args.baseline, "*.notices.zip")
    args.native_manifest = only(args.baseline, "native-build.json")
    args.recipe_evidence = only(args.baseline, recipes.ARCHIVE)
    args.cocoa_evidence = only(args.baseline, cocoa.ARCHIVE)
    args.upstream_evidence = only(args.baseline, upstream.ARCHIVE)
    args.git_evidence = only(args.baseline, git_source.ARCHIVE)
    args.source_evidence = only(args.candidate, build.SOURCE_BUNDLE)
    # There are two intentional identical staging report copies; the root
    # report is the uploaded evidence contract, not a recursive lookup.
    args.staging = args.runtime / "staging-report.json"
    if not args.staging.is_file() or args.staging.is_symlink():
        raise ValueError("missing root staging report")
    audit.verify_report(args.baseline_bom, args.audit, args.notices)
    read = lambda path: json.loads(path.read_text())
    staging = read(args.staging)
    sha = digest(args.source_evidence)
    if staging["candidate_package"]["sbom_sha256"] != digest(args.candidate_bom):
        raise ValueError("candidate SBOM staging digest mismatch")
    baseline, candidate = read(args.baseline_bom), read(args.candidate_bom)
    _, files = inventory(candidate)
    p = files[TARGET]["properties"]
    build.verify_source_bundle(args.source_evidence, {
        "upstream_sha256": p["mrv:upstream-sha256"],
        "downstream_sha256": p["mrv:downstream-patch-sha256"],
        "candidate_patch_sha256": p["mrv:candidate-patch-sha256"],
        "candidate_dylib_sha256": p["mrv:source-sha256"],
    })
    with (HERE / "lockfile.toml").open("rb") as handle:
        revision = tomllib.load(handle)["cocoaspice"]["revision"]
    if read(args.native_manifest)["cocoaspice_revision"] != revision:
        raise ValueError("CocoaSpice build manifest revision mismatch")
    result = make_inventory(baseline, candidate, read(args.audit), staging, sha, revision)
    recipe_report = recipes.verify(args.recipe_evidence, args.baseline_bom, args.native_manifest)
    recipe_rows = {"homebrew:" + row["formula"] + "@" + row["version"]: row
                   for row in recipe_report["packages"]}
    for row in result["components"]:
        if row["component"].startswith("homebrew:"):
            row["installed_recipe_evidence"] = recipe_rows[row["component"]]
    cocoa_review = cocoa.verify(args.cocoa_evidence, args.baseline_bom, args.native_manifest)
    for row in result["components"]:
        if row["component"] == "cocoaspice:" + revision:
            row.update(corresponding_source_status="overlay-source-evidence-collected-review-required",
                       source_evidence_sha256=digest(args.cocoa_evidence),
                       overlay_changes={key: sorted(value) for key, value in cocoa_review["changes"].items()})
    upstream_review = upstream.verify(args.upstream_evidence, args.baseline_bom, args.native_manifest, args.recipe_evidence)
    upstream_rows = {"homebrew:" + row["formula"] + "@" + row["version"]: row
                     for row in upstream_review["packages"]}
    for row in result["components"]:
        if row["component"].startswith("homebrew:"):
            row["upstream_source_candidates"] = upstream_rows[row["component"]]
    git_review = git_source.verify(args.git_evidence, args.baseline_bom, args.native_manifest, args.recipe_evidence)
    for row in result["components"]:
        if row["component"] == "homebrew:x264@" + git_review["source"]["version"]:
            row["git_source_evidence"] = git_review
    result["evidence_sha256"] = {key: digest(getattr(args, key)) for key in (
        "baseline_bom", "candidate_bom", "audit", "notices", "staging",
        "source_evidence", "native_manifest", "recipe_evidence", "cocoa_evidence", "upstream_evidence", "git_evidence")}
    with args.output.open("x", encoding="utf-8") as handle:
        json.dump(result, handle, indent=2, sort_keys=True)
        handle.write("\n")
    print("MRV_DISTRIBUTION_INVENTORY_OK review_required=true release_ready=false")

if __name__ == "__main__":
    main()
