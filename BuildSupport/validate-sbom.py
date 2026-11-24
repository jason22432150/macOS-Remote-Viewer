#!/usr/bin/env python3
"""Validate CycloneDX 1.6 using pinned upstream schemas and exact signed bundle inventory."""
import argparse
import hashlib
import json
import subprocess
import urllib.request
from pathlib import Path

SCHEMA_REV = "8a27bfd1be5be0dcb2c208a34d2f4fa0b6d75bd7"
SCHEMA_NAMES = ("bom-1.6.schema.json", "spdx.schema.json", "jsf-0.82.schema.json")


def schemas():
    from referencing import Registry, Resource
    from jsonschema import Draft7Validator

    documents = {}
    for name in SCHEMA_NAMES:
        url = f"https://raw.githubusercontent.com/CycloneDX/specification/{SCHEMA_REV}/schema/{name}"
        with urllib.request.urlopen(url, timeout=30) as response:
            data = response.read(2 * 1024 * 1024 + 1)
        if len(data) > 2 * 1024 * 1024:
            raise ValueError("schema too large")
        document = json.loads(data)
        if document["$id"] != f"http://cyclonedx.org/schema/{name}":
            raise ValueError(f"unexpected schema ID: {name}")
        Draft7Validator.check_schema(document)
        documents[name] = document
    registry = Registry().with_resources(
        (doc["$id"], Resource.from_contents(doc)) for doc in documents.values()
    )
    return Draft7Validator(documents[SCHEMA_NAMES[0]], registry=registry)


def components(items):
    for item in items:
        yield item
        yield from components(item.get("components", []))


def verify_inventory(bom, app):
    refs = set()
    paths = {}
    for item in components(bom["components"]):
        ref = item["bom-ref"]
        if ref in refs:
            raise ValueError(f"duplicate component reference: {ref}")
        refs.add(ref)
        if item["type"] != "file":
            continue
        relative = item["name"]
        path = app / relative
        if not path.resolve().is_relative_to(app.resolve()) or Path(relative).is_absolute():
            raise ValueError("file outside bundle")
        if relative in paths:
            raise ValueError(f"duplicate file: {relative}")
        hashes = [h["content"] for h in item["hashes"] if h["alg"] == "SHA-256"]
        with path.open("rb") as handle:
            actual = hashlib.file_digest(handle, "sha256").hexdigest()
        if hashes != [actual]:
            raise ValueError(f"file hash mismatch: {relative}")
        paths[relative] = actual
    actual_paths = set()
    for path in app.rglob("*"):
        if path.is_file():
            kind = subprocess.check_output(["file", "-b", str(path)], text=True)
            if "Mach-O" in kind:
                actual_paths.add(path.relative_to(app).as_posix())
    if not actual_paths or actual_paths != paths.keys():
        raise ValueError(f"inventory mismatch: missing={sorted(actual_paths - paths.keys())}, extra={sorted(paths.keys() - actual_paths)}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("bom", type=Path)
    parser.add_argument("--app", type=Path)
    args = parser.parse_args()
    bom = json.loads(args.bom.read_text())
    if bom.get("specVersion") != "1.6":
        raise ValueError("expected CycloneDX 1.6")
    schemas().validate(bom)
    if args.app:
        verify_inventory(bom, args.app)
    print("CycloneDX schema and requested inventory checks passed.")


if __name__ == "__main__":
    main()
