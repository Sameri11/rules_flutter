#!/usr/bin/env python3
"""Measure checksummed Maven downloads in a download-only repository cache."""

import argparse
import hashlib
import json
from pathlib import Path


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lock", type=Path, action="append", required=True)
    parser.add_argument("--cache", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--require-complete", action="store_true")
    args = parser.parse_args()
    report = {"locks": [], "blobs": {}}
    for path in args.lock:
        data = json.loads(path.read_text())
        if data["version"] != "3":
            raise SystemExit(f"Unsupported lock format: {path}: {data['version']}")
        rows = []
        for coordinate, artifact in data["artifacts"].items():
            for classifier, digest in artifact["shasums"].items():
                if digest is None:
                    continue
                if len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
                    raise SystemExit(f"Invalid SHA-256: {path}: {coordinate}: {digest}")
                row = {"coordinate": coordinate, "version": artifact["version"],
                       "classifier": classifier, "sha256": digest}
                rows.append(row)
                blob = report["blobs"].setdefault(digest, {"references": []})
                blob["references"].append({"lock": path.name, **row})
        if not rows:
            raise SystemExit(f"No checksummed artifacts in {path}")
        report["locks"].append({"path": str(path), "bytes": path.stat().st_size,
                                "sha256": sha256(path), "artifacts": rows,
                                "candidate_repositories": data["repositories"]})

    missing = []
    for digest, blob in report["blobs"].items():
        cached = args.cache / "content_addressable" / "sha256" / digest / "file"
        blob["cache_path"] = str(cached)
        if not cached.is_file():
            missing.append(digest)
            blob["bytes"] = None
            continue
        actual = sha256(cached)
        if actual != digest:
            raise SystemExit(f"Cache checksum mismatch: {cached}: {actual}")
        blob["bytes"] = cached.stat().st_size

    report["summary"] = {
        "lock_bytes": sum(lock["bytes"] for lock in report["locks"]),
        "artifact_references": sum(len(lock["artifacts"]) for lock in report["locks"]),
        "unique_sha256_blobs": len(report["blobs"]),
        "missing_sha256_blobs": missing,
        "verified_blob_bytes": sum(blob["bytes"] or 0 for blob in report["blobs"].values()),
        "candidate_repositories_are_not_observed_download_origins": True,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    console = {**report["summary"], "missing_sha256_blobs": len(missing)}
    print(json.dumps(console, indent=2))
    if args.require_complete and missing:
        raise SystemExit(f"Missing {len(missing)} checksummed blobs from the cache")


if __name__ == "__main__":
    main()
