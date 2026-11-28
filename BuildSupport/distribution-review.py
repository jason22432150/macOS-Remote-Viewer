"""Derive a review queue from already verified candidate distribution evidence.

No automatic license conclusion, legal approval, or inferred source completeness.
"""
import re
from pathlib import Path

HEX = re.compile(r"[0-9a-f]{64}")
PROJECT_LICENSE_NAMES = ("LICENSE", "LICENSE.md", "LICENSE.txt", "COPYING", "COPYING.md", "COPYING.txt")

def project_license_files(root):
    found = []
    for name in PROJECT_LICENSE_NAMES:
        path = root / name
        if path.is_symlink():
            raise ValueError("unexpected project license symlink")
        if path.is_file():
            import hashlib
            with path.open("rb") as handle:
                digest = hashlib.file_digest(handle, "sha256").hexdigest()
            found.append({"path": name, "sha256": digest})
    return found

def make_review(inventory, project_licenses):
    if (inventory["scope"] != "candidate-test-only"
            or inventory["release_ready"] is not False):
        raise ValueError("unexpected distribution review scope")
    for item in project_licenses:
        if item["path"] not in PROJECT_LICENSE_NAMES or not HEX.fullmatch(item["sha256"]):
            raise ValueError("invalid project license evidence")
    if len({item["path"] for item in project_licenses}) != len(project_licenses):
        raise ValueError("duplicate project license evidence")
    rows, seen = [], set()
    for component in inventory["components"]:
        ref = component["component"]
        if (ref in seen or component["review_status"] != "required"
                or component["license_conclusion"] is not None):
            raise ValueError("duplicate or prematurely approved component")
        seen.add(ref)
        tasks = {"review-license-conclusion", "review-linkage-and-distribution-obligations"}
        evidence = {}
        if ref.startswith("homebrew:"):
            recipe = component["installed_recipe_evidence"]
            upstream = component["upstream_source_candidates"]
            if ref != "homebrew:" + recipe["formula"] + "@" + recipe["version"] or ref != (
                    "homebrew:" + upstream["formula"] + "@" + upstream["version"]):
                raise ValueError("review component identity mismatch")
            plan = upstream["plan"]
            pairs, downloads = plan["literal_source_candidates"], upstream["downloads"]
            if len(pairs) != len(downloads):
                raise ValueError("review source coverage mismatch")
            sources = []
            for pair, download in zip(pairs, downloads):
                if pair["line"] != download["line"]:
                    raise ValueError("review source line mismatch")
                sources.append({"line": pair["line"], "url": pair["url"],
                                "sha256": pair["sha256"], "status": download["status"]})
            git = component.get("git_source_evidence")
            if git and ("homebrew:" + git["source"]["formula"] + "@" + git["source"]["version"] != ref):
                raise ValueError("review Git component identity mismatch")
            inline = component["inline_patch_evidence"]
            evidence = {
                "literal_license_candidates": plan["literal_license_candidates"],
                "nonliteral_license_declarations": [d for d in plan["unresolved_declarations"]
                                                   if re.match(r"^license\b", d["declaration"])],
                "notice_status": component["notice_status"],
                "source_candidates": sources,
                "git_source_status": git["status"] if git else None,
                "inline_patch": inline,
                "formula_review_hints": plan["review_hints"],
                "unresolved_declarations": plan["unresolved_declarations"],
                "binary_license_reports": recipe["ffmpeg_build_metadata"],
            }
            if not evidence["literal_license_candidates"]:
                tasks.add("review-nonliteral-or-missing-license-declaration")
            if component["notice_status"] != "candidates-collected":
                tasks.add("resolve-notice-evidence")
            if not any(x["status"] == "collected" for x in sources) and not (
                    git and git["status"] == "collected"):
                tasks.add("resolve-missing-source-bytes")
            if any(x["status"] != "collected" for x in sources):
                tasks.add("review-uncollected-source-candidates")
            if plan["unresolved_declarations"]:
                tasks.add("review-unresolved-formula-declarations")
            if any(x["role"] == "local-tap-patch-unverified" for x in plan["review_hints"]):
                tasks.add("resolve-unverified-local-tap-patch")
            if any(x["role"] == "recipe-source-edit-review" for x in plan["review_hints"]):
                tasks.add("review-formula-source-edits")
            if inline:
                tasks.add("review-inline-patch-application")
            if recipe["ffmpeg_build_metadata"]:
                tasks.add("review-actual-binary-license-and-configuration")
                if any(re.search(r"\bGPL\b", probe["license"], re.I)
                       for probe in recipe["ffmpeg_build_metadata"]):
                    tasks.add("review-gpl-binary-linkage-compatibility")
            tasks.add("review-complete-corresponding-source-and-build-inputs")
        elif ref.startswith("cocoaspice:"):
            evidence = {"source_evidence_sha256": component["source_evidence_sha256"],
                        "overlay_changes": component["overlay_changes"],
                        "upstream_license_candidate": "Apache-2.0"}
            tasks.update(("review-modified-file-notices-and-upstream-notice",
                          "review-static-linkage"))
        elif ref == "modified:spice-gtk@0.43":
            evidence = {"source_evidence_sha256": component["source_evidence_sha256"]}
            tasks.update(("review-modified-source-and-license-notices",
                          "review-modified-component-advisories"))
        elif ref == "app-origin-unverified":
            evidence = {"project_root_license_candidates": project_licenses}
            tasks.update(("review-project-license-and-ownership",
                          "review-app-origin-and-static-dependencies"))
            if not project_licenses:
                tasks.add("resolve-project-root-license-not-found")
        else:
            raise ValueError("unrecognized review component")
        rows.append({"component": ref, "review_status": "required",
                     "license_conclusion": None, "signed_file_count": len(component["signed_files"]),
                     "evidence": evidence, "required_review_tasks": sorted(tasks)})
    if not rows or "app-origin-unverified" not in seen:
        raise ValueError("missing app review group")
    counts = {}
    for row in rows:
        for task in row["required_review_tasks"]:
            counts[task] = counts.get(task, 0) + 1
    return {"schema": 1, "release_ready": False, "review_status": "required",
            "components": rows, "task_counts": counts,
            "limitations": ["Root license filenames are evidence only, not a legal conclusion.",
                            "Formula declarations may be compound or conditional.",
                            "Candidate source bytes do not establish complete corresponding source.",
                            "All tasks require review; none is an approval."] }
