#!/usr/bin/env python3
"""Audit actual bundled Homebrew kegs; report advisory coverage, not a safety verdict."""
import argparse
import datetime
import hashlib
import json
import re
import subprocess
import urllib.request
import zipfile
from pathlib import Path

OSV_URL = "https://api.osv.dev/v1/querybatch"
NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.+@-]*$")


def sha256(path):
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def package_components(bom):
    return [p for p in bom["components"] if p.get("bom-ref", "").startswith("homebrew:")]


def verify_kegs(packages, manifest, cellar):
    installed = {}
    for line in manifest["installed_formulae"]:
        name, *versions = line.split()
        installed[name] = set(versions)
    result = []
    for package in packages:
        name, version = package["name"], package["version"]
        if not NAME.fullmatch(name) or not NAME.fullmatch(version):
            raise ValueError("invalid keg name/version")
        if version not in installed.get(name, set()):
            raise ValueError(f"bundled keg absent from build inventory: {name}@{version}")
        root = (cellar / name / version).resolve()
        if not root.is_relative_to(cellar.resolve()) or not root.is_dir():
            raise ValueError(f"invalid keg directory: {name}@{version}")
        receipt = root / "INSTALL_RECEIPT.json"
        if not receipt.is_file():
            raise ValueError(f"missing keg receipt: {name}@{version}")
        metadata = json.loads(receipt.read_text())
        tap = metadata.get("source", {}).get("tap")
        for binary in package.get("components", []):
            props = {p["name"]: p["value"] for p in binary["properties"]}
            relative = Path(props["mrv:keg-path"])
            source = root / relative
            if relative.is_absolute() or not source.resolve().is_relative_to(root):
                raise ValueError("source outside keg")
            if sha256(source) != props["mrv:source-sha256"]:
                raise ValueError(f"source changed after packaging: {name}/{relative}")
        result.append((name, version, root, tap))
    return result


def query_batch(queries):
    request = urllib.request.Request(OSV_URL, data=json.dumps({"queries": queries}).encode(),
                                    headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(request, timeout=30) as response:
        data = response.read(8 * 1024 * 1024 + 1)
    if len(data) > 8 * 1024 * 1024:
        raise ValueError("OSV response too large")
    results = json.loads(data)["results"]
    if not isinstance(results, list) or len(results) != len(queries):
        raise ValueError("OSV result count mismatch")
    return results


def scan(kegs):
    reports = []
    pending = []
    for name, version, _, tap in kegs:
        entry = {"formula": name, "version": version, "tap": tap,
                 "status": "not-queried", "advisory_ids": []}
        reports.append(entry)
        if tap != "homebrew/core":
            entry["status"] = "unverified-tap"
            continue
        pending.append((entry, {"package": {"name": name, "ecosystem": "Homebrew"},
                                "version": version}))
    # Follow per-package pagination; an incomplete response is never "no matches".
    for start in range(0, len(pending), 100):
        batch = pending[start:start + 100]
        for _ in range(20):
            if not batch:
                break
            try:
                results = query_batch([query for _, query in batch])
                next_batch = []
                for (entry, query), result in zip(batch, results):
                    if not isinstance(result, dict) or not isinstance(result.get("vulns", []), list):
                        raise ValueError("malformed OSV result")
                    ids = [v["id"] for v in result.get("vulns", [])]
                    if any(not isinstance(i, str) or not i for i in ids):
                        raise ValueError("malformed advisory ID")
                    entry["advisory_ids"] = sorted(set(entry["advisory_ids"] + ids))
                    token = result.get("next_page_token")
                    if token:
                        if not isinstance(token, str) or token == query.get("page_token"):
                            raise ValueError("invalid OSV page token")
                        next_batch.append((entry, dict(query, page_token=token)))
                        entry["status"] = "partial"
                    else:
                        entry["status"] = "matches" if entry["advisory_ids"] else "no-known-matches"
                batch = next_batch
            except (OSError, ValueError, KeyError, TypeError) as error:
                for entry, _ in batch:
                    entry["status"] = "query-error"
                    entry["error"] = type(error).__name__
                break
        else:
            for entry, _ in batch:
                entry["status"] = "pagination-limit"
    return reports


def collect_notices(kegs, output):
    """Collect candidate notices only from the exact installed keg, never follow external links."""
    entries = []
    prefixes = ("license", "licence", "copying", "copyright", "notice", "authors", "legal")
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name, version, root, _ in kegs:
            collected = []
            skipped = []
            for candidate in sorted(root.rglob("*")):
                relative = candidate.relative_to(root)
                if not any(part.lower().startswith(prefixes) for part in relative.parts):
                    continue
                if candidate.is_symlink() or not candidate.is_file():
                    continue
                if not candidate.resolve().is_relative_to(root) or candidate.stat().st_size > 2 * 1024 * 1024:
                    skipped.append(relative.as_posix())
                    continue
                target = f"{name}/{version}/{relative.as_posix()}"
                archive.write(candidate, target)
                collected.append({"path": target, "sha256": sha256(candidate)})
            entries.append({"formula": name, "version": version, "files": collected,
                            "skipped": skipped, "status": "candidates-collected" if collected else "missing-review-required"})
        archive.writestr("notice-inventory.json", json.dumps(entries, indent=2) + "\n")
    return entries


COMPLETE_STATUSES = {"matches", "no-known-matches"}
INCOMPLETE_STATUSES = {"unverified-tap", "not-queried", "partial", "query-error", "pagination-limit"}


def verify_report(bom_path, report_path, notices_path, *, require_complete=False):
    """Cross-check exact observed keg set and report status against signed inventory.

    This is evidence consistency, not advisory applicability or legal clearance.
    """
    bom = json.loads(bom_path.read_text())
    report = json.loads(report_path.read_text())
    if report.get("sbom_sha256") != sha256(bom_path):
        raise ValueError("audit SBOM hash mismatch")
    if report.get("notice_archive_sha256") != sha256(notices_path):
        raise ValueError("audit notice archive hash mismatch")
    if report.get("release_review_required") is not True or report.get("osv_endpoint") != OSV_URL:
        raise ValueError("audit review/endpoint metadata mismatch")
    expected = {(p["name"], p["version"]) for p in package_components(bom)}
    if not expected or len(expected) != len(package_components(bom)):
        raise ValueError("invalid SBOM keg set")

    def keyed(items, label):
        if not isinstance(items, list):
            raise ValueError(f"invalid {label} inventory")
        result = {}
        for item in items:
            key = (item["formula"], item["version"])
            if key in result:
                raise ValueError(f"duplicate {label} keg: {key}")
            result[key] = item
        if result.keys() != expected:
            raise ValueError(f"{label} keg coverage mismatch")
        return result

    entries = keyed(report["packages"], "advisory")
    notices = keyed(report["notices"], "notice")
    for key, entry in entries.items():
        status = entry.get("status")
        ids = entry.get("advisory_ids")
        if status not in COMPLETE_STATUSES | INCOMPLETE_STATUSES:
            raise ValueError(f"unknown scan status for {key}")
        if (not isinstance(ids, list) or
                any(not isinstance(i, str) or not NAME.fullmatch(i) for i in ids) or
                ids != sorted(set(ids))):
            raise ValueError(f"invalid advisory IDs for {key}")
        if ((status == "matches" and not ids) or (status == "no-known-matches" and ids) or
                (status in COMPLETE_STATUSES and entry.get("tap") != "homebrew/core")):
            raise ValueError(f"inconsistent scan status for {key}")
    complete = all(e["status"] in COMPLETE_STATUSES for e in entries.values())
    if report.get("scan_complete_for_observed_kegs") is not complete:
        raise ValueError("inconsistent scan completeness flag")
    with zipfile.ZipFile(notices_path) as archive:
        members = archive.namelist()
        if len(members) != len(set(members)) or "notice-inventory.json" not in members:
            raise ValueError("invalid notice archive inventory")
        if archive.getinfo("notice-inventory.json").file_size > 8 * 1024 * 1024:
            raise ValueError("notice inventory too large")
        inventory = json.loads(archive.read("notice-inventory.json"))
        if inventory != report["notices"]:
            raise ValueError("notice archive inventory mismatch")
        recorded = {"notice-inventory.json"}
        for (name, version), entry in notices.items():
            files = entry["files"]
            if entry["status"] != ("candidates-collected" if files else "missing-review-required"):
                raise ValueError("inconsistent notice status")
            for file in files:
                path = file["path"]
                relative = Path(path)
                if (relative.is_absolute() or ".." in relative.parts or
                        relative.parts[:2] != (name, version) or path in recorded):
                    raise ValueError("invalid notice member path")
                recorded.add(path)
                if archive.getinfo(path).file_size > 2 * 1024 * 1024:
                    raise ValueError("notice member too large")
                if hashlib.sha256(archive.read(path)).hexdigest() != file["sha256"]:
                    raise ValueError("notice member hash mismatch")
        if set(members) != recorded:
            raise ValueError("unrecorded notice archive member")
    # Print bounded structured lines to CI logs, without implying no matches
    # means safe. Missing notices and incomplete scans remain explicit.
    for key in sorted(expected):
        entry = entries[key]
        print("MRV_DEPENDENCY_REVIEW " + json.dumps({
            "formula": key[0], "version": key[1], "status": entry["status"],
            "advisory_ids": entry["advisory_ids"], "notice_status": notices[key]["status"],
        }, ensure_ascii=True, sort_keys=True))
    print("MRV_DEPENDENCY_SUMMARY " + json.dumps({
        "observed_kegs": len(expected), "complete": complete,
        "matched_kegs": sum(e["status"] == "matches" for e in entries.values()),
        "advisory_ids": sorted({i for e in entries.values() for i in e["advisory_ids"]}),
        "incomplete_kegs": sum(e["status"] not in COMPLETE_STATUSES for e in entries.values()),
        "missing_notice_kegs": sum(e["status"] == "missing-review-required" for e in notices.values()),
        "release_review_required": True,
    }, ensure_ascii=True, sort_keys=True))
    if require_complete and not complete:
        raise ValueError("incomplete observed-keg OSV coverage")
    return complete


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("bom", type=Path)
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--verify-report", type=Path)
    parser.add_argument("--notices", type=Path)
    parser.add_argument("--require-complete", action="store_true")
    args = parser.parse_args()
    if args.verify_report:
        if not args.notices or args.manifest:
            parser.error("--verify-report requires --notices instead of --manifest")
        verify_report(args.bom, args.verify_report, args.notices,
                      require_complete=args.require_complete)
        return
    if not args.manifest or args.notices or args.require_complete:
        parser.error("audit generation requires --manifest")
    bom = json.loads(args.bom.read_text())
    manifest = json.loads(args.manifest.read_text())
    cellar = Path(subprocess.check_output(["brew", "--cellar"], text=True).strip()).resolve()
    kegs = verify_kegs(package_components(bom), manifest, cellar)
    if not kegs:
        raise ValueError("no observed Homebrew kegs")
    stem = args.bom.name.removesuffix(".bom.json")
    notices = args.bom.with_name(stem + ".notices.zip")
    report_path = args.bom.with_name(stem + ".dependency-audit.json")
    notice_inventory = collect_notices(kegs, notices)
    reports = scan(kegs)
    complete = all(r["status"] in ("matches", "no-known-matches") for r in reports)
    report = {
        "sbom_sha256": sha256(args.bom),
        "checked_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "osv_endpoint": OSV_URL,
        "coverage": "observed Homebrew core kegs only; other binaries and static dependencies not scanned",
        "scan_complete_for_observed_kegs": complete,
        "release_review_required": True,
        "packages": reports,
        "notices": notice_inventory,
        "notice_archive_sha256": sha256(notices),
        "limitations": "No matches is not proof of safety; collected notices do not establish licensing compliance.",
    }
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    for path in (notices, report_path):
        path.with_name(path.name + ".sha256").write_text(f"{sha256(path)}  {path.name}\n", encoding="utf-8")
    verify_report(args.bom, report_path, notices)
    print(f"Verified {len(kegs)} kegs; OSV coverage complete: {complete}; review advisory IDs and notices.")
    # A network outage must be visible in the report, but should not hide an otherwise usable preview.
    # The draft-release workflow requires complete queries and explicit human review.


if __name__ == "__main__":
    main()
