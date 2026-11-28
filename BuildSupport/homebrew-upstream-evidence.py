#!/usr/bin/env python3
"""Collect bounded, hash-pinned source candidates from archived installed recipes.

Ruby is never evaluated. A literal URL/checksum pair is evidence, not a
complete formula interpreter or a determination of corresponding source.
"""
import argparse
import hashlib
import importlib.util
import json
import re
import tempfile
import urllib.request
import zipfile
from pathlib import Path
from urllib.parse import urlsplit

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("recipes", HERE / "homebrew-recipe-evidence.py")
recipes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recipes)
build = recipes.build
ARCHIVE = "homebrew-upstream-evidence.zip"
PRIORITY = {"ffmpeg", "glib", "gstreamer", "json-glib", "x264", "x265", "sqlite"}
HOSTS = {"ffmpeg.org", "www.ffmpeg.org", "download.gnome.org",
         "gstreamer.freedesktop.org", "gitlab.freedesktop.org",
         "code.videolan.org", "download.videolan.org", "bitbucket.org",
         "github.com", "codeload.github.com", "release-assets.githubusercontent.com",
         "objects.githubusercontent.com", "raw.githubusercontent.com",
         "sqlite.org", "www.sqlite.org", "downloads.sourceforge.net",
         "sourceforge.net", "www.videolan.org", "videolan.org",
         "ftpmirror.gnu.org", "ftp.gnu.org",
         "xorg.freedesktop.org", "www.x.org", "x.org", "www.mpg123.de",
         "mpg123.de", "ftp.osuosl.org", "cairographics.org", "gitlab.com",
         "www.spice-space.org", "spice-space.org",
         "prdownloads.sourceforge.net", "master.dl.sourceforge.net"}
MAX_FILE = 96 * 1024 * 1024
MAX_TOTAL = 320 * 1024 * 1024
MAX_DOWNLOADS = 64
URL = re.compile(r'^([ ]*)url ["\x27](https://[^"\x27\s]+)["\x27]\s*$')
SHA = re.compile(r'^([ ]*)sha256 ["\x27]([0-9a-f]{64})["\x27]\s*$')
LICENSE = re.compile(r'^  license ["\x27]([A-Za-z0-9.+-]+)["\x27]\s*$')
STATUSES = {"collected", "unapproved-host", "download-unavailable",
            "size-limit", "budget-limit", "redirect-blocked"}

class LimitError(ValueError):
    pass

class BlockedRedirect(ValueError):
    pass

def plan(text):
    """Recognize only adjacent literal pairs; keep unsupported declarations visible."""
    lines = text.splitlines()
    pairs, unresolved, licenses = [], [], []
    for i, line in enumerate(lines):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        license_match = LICENSE.fullmatch(line)
        if license_match:
            licenses.append(license_match.group(1))
        if not re.match(r"^(url|patch|resource|head|license)\b", stripped):
            continue
        m = URL.fullmatch(line)
        if m and "#{" not in m[2] and "\\" not in m[2]:
            j = i + 1
            mirrors = []
            while j < len(lines):
                # Only known literal metadata can intervene. Never evaluate Ruby,
                # cross a block boundary, or substitute a mirror for the primary.
                metadata = re.fullmatch(r'([ ]*)(?:mirror "https?://[^"\s]+"|version "[A-Za-z0-9_.+-]+")\s*', lines[j])
                if (not lines[j].strip() or lines[j].lstrip().startswith("#")
                        or (metadata and metadata[1] == m[1]
                            and "#{" not in lines[j] and "\\" not in lines[j])):
                    mirror = re.fullmatch(r\'[ ]*mirror "(https://[^"\s]+)"\s*\', lines[j])
                    if mirror and metadata and mirror[1] not in mirrors:
                        mirrors.append(mirror[1])
                    j += 1
                else:
                    break
            s = SHA.fullmatch(lines[j]) if j < len(lines) else None
            if s and s[1] == m[1]:
                pairs.append({"line": i + 1, "url": m[2], "sha256": s[2],
                              "kind": "primary-candidate" if m[1] == "  " else "nested-candidate"})
                if mirrors:
                    pairs[-1]["mirrors"] = mirrors
                continue
        if not license_match:
            unresolved.append({"line": i + 1, "declaration": stripped[:512]})
    return {"literal_license_candidates": sorted(set(licenses)),
            "literal_source_candidates": pairs, "unresolved_declarations": unresolved}

def approved(url):
    try:
        parts = urlsplit(url)
        return (parts.scheme == "https" and parts.hostname in HOSTS
                and not parts.username and not parts.password
                and parts.port in (None, 443) and not parts.fragment)
    except ValueError:
        return False

class RestrictedRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not approved(newurl):
            raise BlockedRedirect("unapproved source redirect")
        return super().redirect_request(req, fp, code, msg, headers, newurl)

def fetch(url, sha, destination, limit):
    if not approved(url):
        raise ValueError("unapproved source host")
    opener = urllib.request.build_opener(RestrictedRedirect())
    total = 0
    digest = hashlib.sha256()
    try:
        with opener.open(url, timeout=30) as response, destination.open("xb") as out:
            if not approved(response.geturl()):
                raise BlockedRedirect("unapproved final source host")
            while True:
                chunk = response.read(1024 * 1024)
                if not chunk:
                    break
                total += len(chunk)
                if total > limit:
                    raise LimitError("source size limit")
                digest.update(chunk)
                out.write(chunk)
        if not total or digest.hexdigest() != sha:
            raise ValueError("source checksum mismatch")
        return total
    except BaseException:
        destination.unlink(missing_ok=True)
        raise

def fallback_urls(key, pair):
    # Explicit archived HTTPS mirrors; never relax the host allowlist.
    urls = [url for url in pair.get("mirrors", []) if approved(url)]
    # SourceForge's fixed project download host, for this exact observed
    # LAME path only. Keep the original Formula checksum as authority.
    if key == ("lame", "4.0") and pair["url"] == (
            "https://downloads.sourceforge.net/project/lame/lame/4.0/lame-4.0.tar.gz"):
        urls.append("https://master.dl.sourceforge.net/project/lame/lame/4.0/lame-4.0.tar.gz")
    return list(dict.fromkeys(url for url in urls if url != pair["url"] and approved(url)))

def fetch_candidate(key, pair, target, limit):
    try:
        return fetch(pair["url"], pair["sha256"], target, limit), pair["url"]
    except BlockedRedirect:
        # Preserve existing fail-closed behavior for priority packages.
        if key[0] in PRIORITY:
            raise
        for url in fallback_urls(key, pair):
            try:
                return fetch(url, pair["sha256"], target, limit), url
            except (BlockedRedirect, OSError):
                continue
        raise

def binding(bom, native, recipe_path):
    return {**recipes.binding(bom, native), "installed_recipe_sha256": recipes.digest(recipe_path)}

def recipe_plans(recipe_path, bom, native):
    review = recipes.verify(recipe_path, bom, native)
    result = {}
    with zipfile.ZipFile(recipe_path) as archive:
        for row in review["packages"]:
            key = (row["formula"], row["version"])
            body = archive.read("/".join(key) + "/formula.rb").decode("utf-8")
            result[key] = plan(body)
    return result

def verify(path, bom, native, recipe_path):
    expected = recipe_plans(recipe_path, bom, native)
    manifest = build.verify_source_bundle(path, binding(bom, native, recipe_path))
    members = {"review.json"}
    with zipfile.ZipFile(path) as archive:
        if archive.getinfo("review.json").file_size > 8 * 1024 * 1024:
            raise ValueError("source review too large")
        report = json.loads(archive.read("review.json"))
        if report["schema"] != 1 or report["release_ready"] is not False:
            raise ValueError("unexpected upstream review scope")
        seen = set()
        total, count = 0, 0
        for row in report["packages"]:
            key = (row["formula"], row["version"])
            if key not in expected or key in seen or row["plan"] != expected[key]:
                raise ValueError("recipe source plan mismatch")
            seen.add(key)
            pairs = row["plan"]["literal_source_candidates"]
            if len(pairs) != len(row["downloads"]):
                raise ValueError("source candidate coverage mismatch")
            for pair, download in zip(pairs, row["downloads"]):
                status = download["status"]
                if download["line"] != pair["line"] or status not in STATUSES:
                    raise ValueError("invalid download record")
                if (status == "unapproved-host") != (not approved(pair["url"])):
                    raise ValueError("unexpected source host status")
                if status == "redirect-blocked" and key[0] in PRIORITY:
                    raise ValueError("priority redirect must fail collection")
                if status != "collected":
                    if "member" in download:
                        raise ValueError("uncollected source claims bytes")
                    continue
                name = "/".join(key) + "/source-" + str(pair["line"])
                if download.get("member") != name or name in members or not approved(pair["url"]):
                    raise ValueError("invalid source member identity")
                if download.get("retrieved_from", pair["url"]) not in [pair["url"], *fallback_urls(key, pair)]:
                    raise ValueError("unapproved source fallback provenance")
                entry = manifest["members"][name]
                if (entry["sha256"] != pair["sha256"] or entry["size"] != download["size"]
                        or not 0 < entry["size"] <= MAX_FILE):
                    raise ValueError("source bytes mismatch")
                total += entry["size"]
                count += 1
                members.add(name)
        if seen != set(expected) or set(manifest["members"]) != members:
            raise ValueError("upstream evidence inventory mismatch")
        if total > MAX_TOTAL or count > MAX_DOWNLOADS:
            raise ValueError("upstream source budget exceeded")
    return report

def collect(bom, native, recipe_path, output):
    plans = recipe_plans(recipe_path, bom, native)
    rows, entries = [], {}
    total, attempts = 0, 0
    with tempfile.TemporaryDirectory(prefix="mrv-upstream-") as raw:
        root = Path(raw)
        # Preserve the established priority sources before spending the expanded budget.
        for key, candidates in sorted(plans.items(), key=lambda item: (item[0][0] not in PRIORITY, item[0])):
            row = {"formula": key[0], "version": key[1], "plan": candidates, "downloads": []}
            for pair in candidates["literal_source_candidates"]:
                result = {"line": pair["line"]}
                if not approved(pair["url"]):
                    result["status"] = "unapproved-host"
                elif attempts >= MAX_DOWNLOADS or total >= MAX_TOTAL:
                    result["status"] = "budget-limit"
                else:
                    attempts += 1
                    member = "/".join(key) + "/source-" + str(pair["line"])
                    target = root / member
                    target.parent.mkdir(parents=True, exist_ok=True)
                    try:
                        size, retrieved = fetch_candidate(key, pair, target, min(MAX_FILE, MAX_TOTAL-total))
                    except BlockedRedirect:
                        # New non-priority sources may use geo-selected mirrors.
                        # Never follow unapproved hosts; preserve the original
                        # fail-closed behavior for established priority sources.
                        if key[0] in PRIORITY:
                            raise
                        result["status"] = "redirect-blocked"
                    except LimitError:
                        result["status"] = "size-limit"
                    except (OSError, urllib.error.URLError, TimeoutError):
                        result["status"] = "download-unavailable"
                    else:
                        entries[member] = target
                        total += size
                        result.update(status="collected", member=member, size=size, retrieved_from=retrieved)
                row["downloads"].append(result)
            rows.append(row)
        review = root / "review.json"
        review.write_text(json.dumps({"schema": 1, "release_ready": False, "packages": rows,
            "limitations": "Literal URL/checksum pairs only; dynamic Ruby, git revisions, inline patches, platform conditions, resources and complete corresponding source require separate review."},
            sort_keys=True, indent=2) + "\n")
        entries["review.json"] = review
        build.write_source_bundle(output, entries, binding(bom, native, recipe_path))
    report = verify(output, bom, native, recipe_path)
    for row in report["packages"]:
        print("MRV_HOMEBREW_UPSTREAM_KEG " + json.dumps({
            "formula": row["formula"], "version": row["version"],
            "candidates": len(row["downloads"]),
            "statuses": [d["status"] for d in row["downloads"]],
            "unresolved_declarations": len(row["plan"]["unresolved_declarations"]),
        }, sort_keys=True))
    print("MRV_HOMEBREW_UPSTREAM_EVIDENCE_OK " + json.dumps({
        "kegs": len(report["packages"]),
        "collected": count_status(report, "collected"),
        "kegs_with_collected_bytes": sum(any(d["status"] == "collected" for d in row["downloads"])
                                         for row in report["packages"]),
        "kegs_without_collected_bytes": sorted(row["formula"] for row in report["packages"]
            if not any(d["status"] == "collected" for d in row["downloads"])),
        "priority_candidates_uncollected": sum(d["status"] != "collected"
            for row in report["packages"] if row["formula"] in PRIORITY for d in row["downloads"]),
        "priority_kegs_without_collected_bytes": sorted(row["formula"] for row in report["packages"]
            if row["formula"] in PRIORITY and not any(d["status"] == "collected" for d in row["downloads"])),
        "release_ready": False}, sort_keys=True))

def count_status(report, status):
    return sum(d["status"] == status for row in report["packages"] for d in row["downloads"])

def main():
    parser = argparse.ArgumentParser()
    for arg in ("bom", "native-manifest", "recipes", "output"):
        parser.add_argument("--" + arg, type=Path, required=True)
    args = parser.parse_args()
    collect(args.bom, args.native_manifest, args.recipes, args.output)

if __name__ == "__main__":
    main()
