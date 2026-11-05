#!/usr/bin/env python3
"""Reject a missing or corrupt Maven blob with remotes blocked."""

import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import time

from maven_download_inventory import sha256

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--proof", type=Path, required=True)
    parser.add_argument("--scratch", type=Path, required=True)
    parser.add_argument("--bazel", default="/tmp/bazelw")
    args = parser.parse_args()
    scratch = args.scratch.resolve()
    scratch.mkdir(parents=True, exist_ok=False)
    inventory = json.loads((args.proof / "warm-inventory.json").read_text())
    digest, blob = min(inventory["blobs"].items(), key=lambda entry: entry[1]["bytes"])
    reference = blob["references"][0]
    parts = reference["coordinate"].split(":")
    if reference["classifier"] != "jar":
        if len(parts) == 2:
            parts.append("jar")
        parts.append(reference["classifier"])
    parts.append(reference["version"])
    repository = re.sub(r"[.\-:/+$]", "_", ":".join(parts))
    target = "@@rules_jvm_external++maven+" + repository + "//file"
    original = args.proof / "warm-cache/content_addressable/sha256" / digest / "file"
    if sha256(original) != digest:
        raise SystemExit("Positive proof's source cache is corrupt")
    results = {"target": target, "sha256": digest, "reference": reference, "scenarios": {}}
    for scenario in ("missing", "corrupt"):
        cache = scratch / (scenario + "-cache")
        shutil.copytree(args.proof / "warm-cache/content_addressable", cache / "content_addressable")
        artifact = cache / "content_addressable/sha256" / digest / "file"
        artifact.unlink()
        corrupt_bytes = b"deliberately corrupt cached Maven artifact\n"
        if scenario == "corrupt":
            artifact.write_bytes(corrupt_bytes)
            if sha256(artifact) == digest:
                raise SystemExit("Corrupt fixture unexpectedly matches the expected checksum")
        base = scratch / (scenario + "-base")
        command = [args.bazel, "--output_base=" + str(base), "build", "--nobuild",
                   "--lockfile_mode=error", "--repository_cache=" + str(cache),
                   "--disk_cache=", "--remote_cache=", "--worker_quit_after_build",
                   "--downloader_config=" + str(args.proof / "blocked-maven.cfg"), target]
        started = time.monotonic()
        try:
            process = subprocess.run(command, cwd=ROOT / "examples/demo_app", capture_output=True, text=True)
            log = process.stdout + process.stderr
            (scratch / (scenario + ".log")).write_text(log)
            expected = [
                "cache miss and no url specified",
                "configured url rewriter blocked all urls",
                "rules_jvm_external++maven+" + repository,
            ]
            if process.returncode == 0 or any(text.lower() not in log.lower() for text in expected):
                raise SystemExit(f"{scenario}: wrong rejection, exit={process.returncode}; see {scratch}")
            if scenario == "corrupt" and artifact.read_bytes() != corrupt_bytes:
                raise SystemExit("Corrupt fixture was unexpectedly replaced")
            repository_files = base / "external" / ("rules_jvm_external++maven+" + repository) / "file"
            if repository_files.exists() and any(repository_files.rglob("*.jar")):
                raise SystemExit(f"{scenario}: rejected jar was materialized")
            results["scenarios"][scenario] = {
                "command": command, "returncode": process.returncode,
                "expected_diagnostics": expected, "seconds": time.monotonic() - started,
                "fixture_sha256": sha256(artifact) if artifact.exists() else None,
                "jar_materialized": False,
            }
            print(f"{scenario}: rejected; target jar not materialized", flush=True)
        finally:
            shutdown = subprocess.run([args.bazel, "--output_base=" + str(base), "shutdown"],
                                      cwd=ROOT / "examples/demo_app", capture_output=True, text=True)
            (scratch / (scenario + "-shutdown.log")).write_text(shutdown.stdout + shutdown.stderr)
            if shutdown.returncode:
                raise SystemExit(f"{scenario}: exact-base shutdown failed")
    if sha256(original) != digest:
        raise SystemExit("Negative fixture changed the positive proof's source cache")
    (scratch / "result.json").write_text(json.dumps(results, indent=2) + "\n")
    print("Both controls passed; source cache unchanged", flush=True)


if __name__ == "__main__":
    main()
