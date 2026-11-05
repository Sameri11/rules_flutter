#!/usr/bin/env python3
"""Fetch locked Maven artifacts with only download-cache contents restored."""

import argparse
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import time
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[2]
LOCK_NAMES = (
    "flutter_maven_install.json",
    "rules_android_maven_install.json",
    "android_ide_common_30_1_3_install.json",
)


def run(command, cwd, log):
    print(shlex.join(map(str, command)), flush=True)
    started = time.monotonic()
    with log.open("w") as stream:
        stream.write(shlex.join(map(str, command)) + "\n")
        stream.flush()
        result = subprocess.run(command, cwd=cwd, stdout=stream, stderr=subprocess.STDOUT)
    elapsed = time.monotonic() - started
    print(f"exit={result.returncode} seconds={elapsed:.3f} log={log}", flush=True)
    if result.returncode:
        raise SystemExit(result.returncode)
    return elapsed


def targets_and_hosts(module):
    targets = set()
    hosts = {"dl.google.com", "repo.maven.apache.org", "maven-central.storage-download.googleapis.com"}
    for name in LOCK_NAMES:
        data = json.loads((module / name).read_text())
        if data["version"] != "3":
            raise SystemExit(f"Unsupported lock version: {name}")
        hosts.update(urlparse(url).hostname for url in data["repositories"])
        for coordinate, artifact in data["artifacts"].items():
            for classifier, digest in artifact["shasums"].items():
                if digest is None:
                    continue
                parts = coordinate.split(":")
                if classifier != "jar":
                    if len(parts) == 2:
                        parts.append("jar")
                    parts.append(classifier)
                parts.append(artifact["version"])
                name = re.sub(r"[.\-:/+$]", "_", ":".join(parts))
                name = name.replace("[", "").replace("]", "").split(",")[0]
                targets.add(f"@@rules_jvm_external++maven+{name}//file")
    if not targets or None in hosts:
        raise SystemExit("Empty artifact set or invalid repository URL")
    return sorted(targets), sorted(hosts)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bazel", default="/tmp/bazelw")
    parser.add_argument("--scratch", type=Path, required=True)
    args = parser.parse_args()
    scratch = args.scratch.resolve()
    scratch.mkdir(parents=True, exist_ok=False)
    module = ROOT / "examples/demo_app"
    targets, hosts = targets_and_hosts(module)
    config = scratch / "blocked-maven.cfg"
    config.write_text("".join(f"block {re.escape(host)}\n" for host in hosts))
    (scratch / "targets.txt").write_text("\n".join(targets) + "\n")
    report = {"module": str(module), "targets": targets, "blocked_hosts": hosts,
              "restored_paths": ["content_addressable"], "phases": {}}
    cold_cache = scratch / "cold-cache"
    for phase in ("cold", "warm"):
        cache = scratch / f"{phase}-cache"
        base = scratch / f"{phase}-base"
        if phase == "warm":
            cache.mkdir()
            shutil.copytree(cold_cache / "content_addressable", cache / "content_addressable")
            if (cache / "contents").exists() or base.exists():
                raise SystemExit("Warm proof contains more than restored downloads")
        command = [args.bazel, f"--output_base={base}", "build", "--nobuild",
                   "--lockfile_mode=error", f"--repository_cache={cache}",
                   "--disk_cache=", "--remote_cache=", "--worker_quit_after_build"]
        if phase == "warm":
            command.append(f"--downloader_config={config}")
        command.extend(targets)
        try:
            elapsed = run(command, module, scratch / f"{phase}.log")
            inventory = [sys.executable, str(ROOT / "tools/ci/maven_download_inventory.py"),
                         "--cache", str(cache), "--output", str(scratch / f"{phase}-inventory.json"),
                         "--require-complete"]
            for name in LOCK_NAMES:
                inventory.extend(["--lock", str(module / name)])
            run(inventory, ROOT, scratch / f"{phase}-inventory.log")
            materialized = sorted(path.name for path in (base / "external").glob("*unpinned*"))
            if materialized:
                raise SystemExit(f"Unpinned resolvers unexpectedly materialized: {materialized}")
            summary = json.loads((scratch / f"{phase}-inventory.json").read_text())["summary"]
            report["phases"][phase] = {"seconds": elapsed, "inventory": summary,
                                       "unpinned_resolvers_materialized": materialized}
            (scratch / "result.json").write_text(json.dumps(report, indent=2) + "\n")
        finally:
            run([args.bazel, f"--output_base={base}", "shutdown"], module,
                scratch / f"{phase}-shutdown.log")
    if report["phases"]["cold"]["inventory"] != report["phases"]["warm"]["inventory"]:
        raise SystemExit("Cold and warm Maven inventory differ")
    print(json.dumps({phase: data["inventory"] for phase, data in report["phases"].items()}, indent=2))


if __name__ == "__main__":
    main()
