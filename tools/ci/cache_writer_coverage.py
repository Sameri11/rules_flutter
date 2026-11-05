#!/usr/bin/env python3
"""Measure unique repository-cache files not carried by a candidate writer."""

import argparse
import hashlib
import json
import os
import subprocess
import tarfile
import zipfile
from pathlib import Path

ROOTS = [
    Path.home() / ".cache/bazel-repo/content_addressable",
    Path.home() / ".cache/bazelisk",
]
REPORT = Path(os.environ["RUNNER_TEMP"]) / "cache-writer-manifest.json"


def files():
    for root in ROOTS:
        if root.exists():
            for path in root.rglob("*"):
                if path.is_file():
                    yield path


def capture(name):
    manifest = json.loads(REPORT.read_text()) if REPORT.exists() else {}
    entries = {}
    for path in files():
        digest = hashlib.sha256()
        with path.open("rb") as src:
            for block in iter(lambda: src.read(1024 * 1024), b""):
                digest.update(block)
        sha = digest.hexdigest()
        size = path.stat().st_size
        item = {"size": size}
        if size >= 1_000_000:
            item["type"], item["members"] = describe(path)
        entries[sha] = item
    manifest[name] = entries
    REPORT.write_text(json.dumps(manifest, sort_keys=True))
    print(f"Captured {name}: {len(entries)} unique files, {sum(v['size'] for v in entries.values())} bytes")


def describe(path):
    kind = subprocess.run(["file", "-b", str(path)], check=True, text=True, capture_output=True).stdout.strip()
    members = []
    try:
        if zipfile.is_zipfile(path):
            with zipfile.ZipFile(path) as archive:
                members = archive.namelist()[:2]
        elif tarfile.is_tarfile(path):
            with tarfile.open(path, "r:*") as archive:
                members = [member.name for member in archive.getmembers()[:2]]
    except (OSError, tarfile.TarError, zipfile.BadZipFile):
        pass
    return kind, members


def analyze(candidate):
    manifest = json.loads(REPORT.read_text())
    union = {}
    for entries in manifest.values():
        union.update(entries)
    carried = set(manifest[candidate])
    absent = sorted(set(union) - carried)
    print(f"Candidate {candidate}: {len(carried)} files, {sum(v['size'] for v in manifest[candidate].values())} bytes")
    print(f"Absent from candidate: {len(absent)} unique files, {sum(union[sha]['size'] for sha in absent)} bytes")
    large = [(sha, union[sha]) for sha in absent if union[sha]["size"] >= 1_000_000]
    print(f"Absent files >=1 MB: {len(large)}")
    for sha, item in sorted(large, key=lambda pair: (-pair[1]["size"], pair[0])):
        print("ARTIFACT", sha, item["size"], item.get("type", "unknown"), json.dumps(item.get("members", []), ensure_ascii=False))
    print(f"Absent small files (<1 MB): {len(absent) - len(large)} files, {sum(union[sha]['size'] for sha in absent if union[sha]['size'] < 1_000_000)} bytes")
    best = sorted(manifest, key=lambda name: (sum(union[sha]['size'] for sha in set(union) - set(manifest[name])), len(set(union) - set(manifest[name]))))
    print("CANDIDATE_RANKING", json.dumps([{ "entry": name, "absent_count": len(set(union) - set(manifest[name])), "absent_bytes": sum(union[sha]['size'] for sha in set(union) - set(manifest[name])) } for name in best]))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["capture", "analyze"])
    parser.add_argument("entry")
    args = parser.parse_args()
    capture(args.entry) if args.command == "capture" else analyze(args.entry)


if __name__ == "__main__":
    main()
