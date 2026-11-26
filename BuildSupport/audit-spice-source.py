#!/usr/bin/env python3
"""Capture pinned upstream receive-path evidence; never extract or execute source."""
import argparse
import hashlib
import io
import json
import re
import subprocess
import tarfile
import tomllib
import urllib.request
from pathlib import Path, PurePosixPath
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
HOSTS = {"www.spice-space.org", "spice-space.org"}
MAX_ARCHIVE = 32 * 1024 * 1024
MAX_EXPANDED = 256 * 1024 * 1024
MAX_MEMBER = 2 * 1024 * 1024
FILES = ("src/channel-main.c", "src/spice-channel.c", "src/spice-channel-priv.h",
         "src/spice-session.c", "src/spice-uri.c")
PATTERNS = {
    FILES[0]: re.compile(r"agent_msg|main_handle_agent_data|agent_data|[Mm]ax.clipboard|g_(?:try_)?(?:malloc|realloc|new0?)\s*\("),
    FILES[1]: re.compile(r"spice_channel_recv_msg|spice_channel_read|header.*size|msg_size|g_(?:try_)?(?:malloc|realloc|new0?)\s*\(|spice_malloc|spice_msg_in_(?:ref|unref|new|sub_new)|in->data|peer_msg"),
    FILES[2]: re.compile(r"struct _SpiceMsgIn|refcount|SpiceMsgIn\s+\*parent"),
    FILES[3]: re.compile(r"g_free\((?:s->)?(?:password|username|host|uri)\)|g_value_dup_string|spice_parse_uri"),
    FILES[4]: re.compile(r"g_(?:free|clear_pointer)\((?:&)?(?:self->(?:user|password)|dup)|spice_uri_set_(?:user|password)|spice_uri_reset"),
}


def check_url(url):
    parts = urlsplit(url)
    if (parts.scheme != "https" or parts.hostname not in HOSTS
            or parts.username or parts.password or parts.port not in (None, 443)):
        raise ValueError("unexpected source URL")


def verify_digest(data, digest):
    if (len(data) > MAX_ARCHIVE or not re.fullmatch(r"[0-9a-f]{64}", digest)
            or hashlib.sha256(data).hexdigest() != digest):
        raise ValueError("source archive size/checksum mismatch")


def fetch(url, digest):
    class RestrictedRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            check_url(newurl)
            return super().redirect_request(req, fp, code, msg, headers, newurl)

    check_url(url)
    opener = urllib.request.build_opener(RestrictedRedirect())
    with opener.open(url, timeout=30) as response:
        check_url(response.geturl())
        data = response.read(MAX_ARCHIVE + 1)
    verify_digest(data, digest)
    return data


def read_source_files(data, version):
    expected = {f"spice-gtk-{version}/{name}": name for name in FILES}
    result = {}
    expanded = 0
    with tarfile.open(fileobj=io.BytesIO(data), mode="r|*") as archive:
        for count, member in enumerate(archive, 1):
            expanded += max(member.size, 0)
            if count > 100000 or expanded > MAX_EXPANDED:
                raise ValueError("archive expansion limit")
            path = PurePosixPath(member.name)
            if path.is_absolute() or ".." in path.parts or "\\" in member.name:
                raise ValueError("unsafe archive member path")
            name = expected.get(path.as_posix())
            if name is None:
                continue
            if not member.isfile() or name in result or not 0 < member.size <= MAX_MEMBER:
                raise ValueError("invalid or duplicate source member")
            with archive.extractfile(member) as handle:
                result[name] = handle.read()
            if len(result[name]) != member.size:
                raise ValueError("truncated source member")
    if set(result) != set(FILES):
        raise ValueError("missing expected source members")
    return result


def review_lines(source, name):
    lines = source.splitlines()
    pattern = PATTERNS[name]
    indices = set()
    for n, line in enumerate(lines):
        if pattern.search(line):
            indices.update(range(max(0, n - 4), min(len(lines), n + 9)))
    return [{"line": n + 1, "text": lines[n]} for n in sorted(indices)]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    with (ROOT / "BuildSupport/lockfile.toml").open("rb") as handle:
        lock = tomllib.load(handle)["spice_gtk"]
    version = lock["version"]
    upstream_version = version.split("_", 1)[0]
    url, digest = lock["upstream_url"], lock["upstream_sha256"]
    keg = Path(subprocess.check_output(
        ["brew", "--prefix", lock["formula"]], text=True, timeout=30).strip()).resolve()
    if keg.name != version:
        raise ValueError("active spice-gtk keg version mismatch")
    formula_path = keg / ".brew" / "spice-gtk.rb"
    formula = formula_path.read_bytes()
    formula_text = formula.decode("utf-8")
    # Check the primary stable source declarations, not the later patch hashes.
    url_match = re.search(r'^\s*url\s+"([^"]+)"', formula_text, re.MULTILINE)
    sha_match = re.search(r'^\s*sha256\s+"([0-9a-f]{64})"', formula_text, re.MULTILINE)
    if not url_match or not sha_match or (url_match[1], sha_match[1]) != (url, digest):
        raise ValueError("installed formula upstream source differs from lock")
    data = fetch(url, digest)
    sources = read_source_files(data, upstream_version)
    report = {
        "keg_version": version,
        "upstream_url": url,
        "upstream_sha256": digest,
        "installed_formula_sha256": hashlib.sha256(formula).hexdigest(),
        "scope": "upstream source evidence; downstream patch and bottle equivalence not proven",
        "files": {},
    }
    for name, body in sources.items():
        selected = review_lines(body.decode("utf-8"), name)
        if not selected:
            raise ValueError(f"no receive-path anchors found in {name}")
        report["files"][name] = {
            "sha256": hashlib.sha256(body).hexdigest(),
            "context": selected,
        }
        print(f"Source evidence {name}: {len(selected)} context lines", flush=True)
        for row in selected:
            print(f"{name}:{row['line']}: {row['text']}", flush=True)
    args.output.mkdir(parents=True, exist_ok=False)
    (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    (args.output / "installed-formula.rb").write_bytes(formula)
    (args.output / f"spice-gtk-{upstream_version}.tar.xz").write_bytes(data)
    print("MRV_SPICE_SOURCE_EVIDENCE_OK", flush=True)


if __name__ == "__main__":
    main()
