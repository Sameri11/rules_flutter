#!/usr/bin/env python3
"""Probe the foreign build tools on the runner's native toolchain.

Records the runner image, compiler defaults and Bazel version; regenerates the
examples/pub_plugins root lock in update mode; runs the existing pub_plugins
APK hash gate in error mode; then records the resolved rules_foreign_cc and
pkgconf graph. Every step runs even after a failure, so the evidence set is
complete. Exit status is nonzero if any step failed.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EXAMPLE = ROOT / "examples" / "pub_plugins"
TARGET = "//android/app:pub_plugins"
# Same flags as the pub_plugins row in tools/ci/example_hashes.py.
TARGET_FLAGS = (
    "-c", "opt", "--@rules_flutter_core//flutter:mode=release",
    "--android_platforms=@rules_android//:arm64-v8a",
)
LOCK_ENV = dict(os.environ, BAZEL_LOCKFILE_MODE="error")


def sha256(path: Path) -> str | None:
    if not path.is_file():
        return None
    return hashlib.sha256(path.read_bytes()).hexdigest()


class Probe:
    def __init__(self, out: Path):
        self.out = out
        self.out.mkdir(parents=True, exist_ok=True)
        self.records: list[dict] = []
        self.failed: str | None = None

    def run(self, name: str, argv: list[str], cwd: Path = ROOT,
            env: dict | None = None) -> str:
        """Run argv; stdout and stderr go to separate files under out/."""
        started = time.time()
        proc = subprocess.run(
            argv, cwd=cwd, env=env or os.environ.copy(),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        (self.out / f"{name}.out").write_text(proc.stdout)
        (self.out / f"{name}.err").write_text(proc.stderr)
        self.records.append({
            "step": name,
            "argv": argv,
            "cwd": str(cwd),
            "returncode": proc.returncode,
            "seconds": round(time.time() - started, 1),
            "stdout": f"{name}.out",
            "stderr": f"{name}.err",
        })
        if proc.returncode and self.failed is None:
            self.failed = name
        return proc.stdout

    def environment(self) -> None:
        os_release = Path("/etc/os-release")
        info = {
            "platform": platform.platform(),
            "image_os": os.environ.get("ImageOS"),
            "image_version": os.environ.get("ImageVersion"),
            "use_bazel_version": os.environ.get("USE_BAZEL_VERSION"),
            "os_release": os_release.read_text() if os_release.is_file() else None,
            "bazelversion_file": (EXAMPLE / ".bazelversion").read_text().strip(),
        }
        (self.out / "environment.json").write_text(
            json.dumps(info, indent=2) + "\n")
        self.run("cc_version", ["cc", "--version"])
        self.run("cc_macros", [
            "sh", "-c",
            "cc -dM -E -x c /dev/null | grep -E '__GNUC__|__GNUC_MINOR__|__STDC_VERSION__'",
        ])
        self.run("bazel_version", ["bazel", "--version"], cwd=EXAMPLE)

    def lock_update(self) -> None:
        lock = EXAMPLE / "MODULE.bazel.lock"
        before = sha256(lock)
        self.run("lock_update", [
            "bazel", "build", "--nobuild", "--lockfile_mode=update",
            *TARGET_FLAGS, TARGET,
        ], cwd=EXAMPLE)
        after = sha256(lock)
        if lock.is_file():
            shutil.copyfile(lock, self.out / "MODULE.bazel.lock")
        (self.out / "lock_hashes.json").write_text(json.dumps(
            {"before": before, "after": after}, indent=2) + "\n")

    def hash_gate(self) -> None:
        lock = EXAMPLE / "MODULE.bazel.lock"
        before = sha256(lock)
        self.run("hash_gate", [
            sys.executable, "tools/ci/example_hashes.py", "--check",
            "--only", "pub_plugins",
            "--golden", "tools/ci/example_hashes_linux.txt",
            "--manifests", str(self.out / "manifests"),
        ], env=LOCK_ENV)
        after = sha256(lock)
        if before != after:
            self.failed = self.failed or "hash_gate_lock_changed"

    def graph(self) -> None:
        self.run("foreign_cc_version", [
            "bazel", "mod", "show_repo", "@rules_foreign_cc",
        ], cwd=EXAMPLE)
        self.run("module_graph", ["bazel", "mod", "graph", "--nofetch"],
                 cwd=EXAMPLE)
        self.run("pkgconf_toolchain_cquery", [
            "bazel", "cquery", "--nofetch", *TARGET_FLAGS,
            "@rules_foreign_cc_toolchains//:all",
            "--output=label_kind",
        ], cwd=EXAMPLE)
        self.run("pkgconf_target_cquery", [
            "bazel", "cquery", "--nofetch", *TARGET_FLAGS,
            "@rules_foreign_cc//toolchains/private:built_pkgconfig",
            "--output=label_kind",
        ], cwd=EXAMPLE)
        self.run("target_transitions", [
            "bazel", "cquery", "--nofetch", *TARGET_FLAGS, TARGET,
            "--output=transitions",
        ], cwd=EXAMPLE)
        self.run("cmake_aquery", [
            "bazel", "aquery", "--nofetch", *TARGET_FLAGS,
            "--include_commandline",
            'mnemonic("CMake.*|ForeignCc.*", deps(%s))' % TARGET,
            "--output=text",
        ], cwd=EXAMPLE)

    def execution_summary(self) -> None:
        """Summarize executed actions that touch pkgconf or rules_foreign_cc."""
        spawns_dir = self.out / "manifests"
        logs = sorted(spawns_dir.glob("*.execution.json"))
        if not logs:
            self.failed = self.failed or "execution_summary_missing"
            return
        matches = []
        runners: dict[str, int] = {}
        for log in logs:
            for line in log.read_text().splitlines():
                if not line.strip():
                    continue
                spawn = json.loads(line)
                runner = spawn.get("runner", "unknown")
                runners[runner] = runners.get(runner, 0) + 1
                text = json.dumps(spawn)
                if "pkgconf" in text or "foreign_cc" in text:
                    matches.append({
                        "log": log.name,
                        "mnemonic": spawn.get("mnemonic"),
                        "runner": runner,
                        "cacheHit": spawn.get("cacheHit"),
                        "targetLabel": spawn.get("targetLabel"),
                        "commandArgs": spawn.get("commandArgs", [])[:4],
                    })
        (self.out / "execution_summary.json").write_text(json.dumps(
            {"runners": runners, "pkgconf_or_foreign_cc_spawns": matches},
            indent=2) + "\n")

    def finish(self) -> None:
        self.run("bazel_shutdown", ["bazel", "shutdown"], cwd=EXAMPLE)
        (self.out / "commands.json").write_text(
            json.dumps(self.records, indent=2) + "\n")
        digests = {
            p.name: sha256(p) for p in sorted(self.out.iterdir())
            if p.is_file() and p.name != "SHA256SUMS"
        }
        (self.out / "SHA256SUMS").write_text("".join(
            f"{digest}  {name}\n" for name, digest in digests.items()))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    probe = Probe(args.out.resolve())
    probe.environment()
    probe.lock_update()
    probe.hash_gate()
    probe.graph()
    probe.execution_summary()
    probe.finish()
    if probe.failed:
        print(f"FAIL: first failing step: {probe.failed}", file=sys.stderr)
        return 1
    print("OK: foreign build tools probe complete")
    return 0


if __name__ == "__main__":
    sys.exit(main())
