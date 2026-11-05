#!/usr/bin/env python3
"""Regenerate the module locks of the affected roots on the CI runner.

Each root runs its CI analysis graph in update mode, then the same graph in
error mode. The lock digest is recorded before and after each phase. Roots run
one after another; a failed root is recorded and the remaining roots still run.
Nothing is retried. The state file is rewritten after every root.
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
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

ROOT = Path(__file__).resolve().parents[2]
MIN_FREE_BYTES = 12 << 30
STEP_TIMEOUT_SECONDS = 3600
ARM64 = "--android_platforms=@rules_android//:arm64-v8a"
RELEASE = ("-c", "opt", "--@rules_flutter_core//flutter:mode=release")
ANDROID_ENV_UNSET = ("ANDROID_HOME", "ANDROID_NDK_HOME")
NAMESPACE_EXPECTED = (
    "Unsupported namespace expression",
    "android/build.gradle",
    '"com.example." + project.name',
)


def build(mode: str, *flags: str) -> list[str]:
    return ["bazel", "build", "--nobuild", f"--lockfile_mode={mode}", *flags]


def consumer_flags() -> tuple[str, ...]:
    # Same NDK wiring as the consumer job in ci.yml.
    return (f"--repo_env=ANDROID_NDK_HOME={os.environ['ANDROID_NDK_HOME']}", "-c", "opt", ARM64)


@dataclass(frozen=True)
class Step:
    name: str
    argv: Callable[[str], list[str]]
    env_unset: tuple[str, ...] = ()
    expect_failure: tuple[str, ...] = ()  # output substrings required on failure


@dataclass(frozen=True)
class Root:
    name: str
    directory: str
    steps: tuple[Step, ...]


ROOTS = (
    Root("rules_flutter_android", "rules_flutter_android", (
        Step("tests_graph",
             lambda m: ["bazel", "build", "--nobuild", f"--lockfile_mode={m}", "//..."],
             env_unset=ANDROID_ENV_UNSET),
    )),
    Root("examples/demo_app", "examples/demo_app", (
        Step("release_arm64", lambda m: build(m, *RELEASE, ARM64, "//android/app:demo_app")),
    )),
    Root("examples/no_plugins", "examples/no_plugins", (
        Step("release_arm64", lambda m: build(m, *RELEASE, ARM64, "//android/app:no_plugins")),
    )),
    Root("examples/pub_plugins", "examples/pub_plugins", (
        Step("release_arm64", lambda m: build(m, *RELEASE, ARM64, "//android/app:pub_plugins")),
    )),
    Root("examples/local_plugin", "examples/local_plugin", (
        Step("release_arm64",
             lambda m: build(m, *RELEASE, ARM64, "//packages/host_app/android/app:host_app")),
    )),
    Root("tests/consumer", "tests/consumer", (
        Step("analysis_only", lambda m: build(m, *consumer_flags(), "//:analysis_only")),
        Step("api_graph", lambda m: build(m, "--build_tests_only", *consumer_flags(), "//...")),
    )),
    Root("tests/namespace_dynamic", "tests/namespace_dynamic", (
        # Intended analysis failure. CI omits --nobuild here; it only suppresses
        # execution, which an analysis failure never reaches.
        Step("dynamic_namespace_failure",
             lambda m: build(m, "//:dynamic_namespace_failure"),
             expect_failure=NAMESPACE_EXPECTED),
    )),
)


def sha256(path: Path) -> str | None:
    if not path.is_file():
        return None
    return hashlib.sha256(path.read_bytes()).hexdigest()


def git(*args: str) -> str:
    return subprocess.run(["git", *args], cwd=ROOT, text=True,
                          stdout=subprocess.PIPE, check=True).stdout.strip()


def text(value: bytes | str | None) -> str:
    if value is None:
        return ""
    return value.decode(errors="replace") if isinstance(value, bytes) else value


class Run:
    def __init__(self, out: Path):
        self.out = out
        self.logs = out / "logs"
        self.logs.mkdir(parents=True, exist_ok=True)
        self.state: dict = {"roots": [], "ok": None}

    def command(self, label: str, argv: list[str], cwd: Path,
                env_unset: tuple[str, ...] = ()) -> dict:
        env = os.environ.copy()
        for key in env_unset:
            env.pop(key, None)
        started = time.monotonic()
        try:
            proc = subprocess.run(argv, cwd=cwd, env=env, text=True,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                  timeout=STEP_TIMEOUT_SECONDS)
            code, stdout, stderr = proc.returncode, proc.stdout, proc.stderr
        except subprocess.TimeoutExpired as exc:
            code, stdout, stderr = None, text(exc.stdout), text(exc.stderr)
        stem = label.replace("/", "_")
        (self.logs / f"{stem}.stdout").write_text(stdout)
        (self.logs / f"{stem}.stderr").write_text(stderr)
        return {
            "label": label,
            "argv": argv,
            "cwd": str(cwd.relative_to(ROOT)) or ".",
            "returncode": code,
            "seconds": round(time.monotonic() - started, 1),
            "stdout": f"logs/{stem}.stdout",
            "stderr": f"logs/{stem}.stderr",
        }

    def free_bytes(self) -> int:
        return shutil.disk_usage(ROOT).free

    def write_state(self) -> None:
        (self.out / "state.json").write_text(json.dumps(self.state, indent=2) + "\n")

    def environment(self) -> None:
        if "USE_BAZEL_VERSION" in os.environ:
            sys.exit("FAIL: USE_BAZEL_VERSION must be unset; the native .bazelversion selects Bazel.")
        if not os.environ.get("ANDROID_NDK_HOME"):
            sys.exit("FAIL: ANDROID_NDK_HOME is unset; the composite action must set it.")
        os_release = Path("/etc/os-release")
        modules = {}
        for rel in ("rules_flutter_android", "rules_flutter_core",
                    *(root.directory for root in ROOTS)):
            modules[rel] = {
                "sha256": sha256(ROOT / rel / "MODULE.bazel"),
                "blob": git("rev-parse", f"HEAD:{rel}/MODULE.bazel"),
            }
        self.state["environment"] = {
            "revision": git("rev-parse", "HEAD"),
            "platform": platform.platform(),
            "image_os": os.environ.get("ImageOS"),
            "image_version": os.environ.get("ImageVersion"),
            "os_release": os_release.read_text() if os_release.is_file() else None,
            "use_bazel_version": os.environ.get("USE_BAZEL_VERSION"),
            "android_ndk_home": os.environ.get("ANDROID_NDK_HOME"),
            "free_bytes": self.free_bytes(),
            "modules": modules,
        }
        version = self.command("bazel_version", ["bazel", "--version"], ROOT)
        self.state["environment"]["bazel_version"] = version
        self.write_state()

    def step_met(self, step: Step, record: dict) -> bool:
        if record["returncode"] is None:
            return False
        if not step.expect_failure:
            return record["returncode"] == 0
        if record["returncode"] == 0:
            return False
        output = (ROOT / record["stdout"]).read_text() + (ROOT / record["stderr"]).read_text()
        return all(needle in output for needle in step.expect_failure)

    def phase(self, root: Root, cwd: Path, mode: str) -> tuple[list[dict], bool]:
        records, ok = [], True
        for step in root.steps:
            record = self.command(f"{root.name}.{mode}.{step.name}", step.argv(mode), cwd,
                                  step.env_unset)
            record["step"] = step.name
            record["expected"] = "failure" if step.expect_failure else "success"
            record["met"] = self.step_met(step, record)
            records.append(record)
            ok = ok and record["met"]
        return records, ok

    def run_root(self, root: Root, previous: Path | None) -> dict:
        cwd = ROOT / root.directory
        lock = cwd / "MODULE.bazel.lock"
        result: dict = {"name": root.name, "directory": root.directory,
                        "free_bytes_before": self.free_bytes(), "failure": None}
        if previous is not None and result["free_bytes_before"] < MIN_FREE_BYTES:
            result["expunge_previous"] = self.command(
                f"{root.name}.expunge_previous", ["bazel", "clean", "--expunge"], previous)
        result["lock_before"] = sha256(lock)
        try:
            result["output_base"] = self.command(
                f"{root.name}.output_base", ["bazel", "info", "output_base"], cwd)
            result["update"], update_ok = self.phase(root, cwd, "update")
            result["lock_after_update"] = sha256(lock)
            result["error"], error_ok = self.phase(root, cwd, "error")
            result["lock_after_error"] = sha256(lock)
            if not update_ok:
                result["failure"] = "update phase"
            elif not error_ok:
                result["failure"] = "error phase"
            elif result["lock_after_update"] != result["lock_after_error"]:
                result["failure"] = "error phase changed the lock"
        except Exception as exc:  # recorded; the next root still runs
            result["failure"] = f"exception: {exc!r}"
        finally:
            result["shutdown"] = self.command(f"{root.name}.shutdown", ["bazel", "shutdown"], cwd)
            if lock.is_file():
                dest = self.out / "locks" / root.directory.replace("/", "__")
                dest.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(lock, dest / "MODULE.bazel.lock")
            result["free_bytes_after"] = self.free_bytes()
            result["ok"] = result["failure"] is None and result["shutdown"]["returncode"] == 0
        return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    out = args.out.resolve()
    run = Run(out)
    run.environment()
    previous: Path | None = None
    for root in ROOTS:
        result = run.run_root(root, previous)
        run.state["roots"].append(result)
        run.write_state()
        status = "ok" if result["ok"] else f"FAILED: {result['failure']}"
        print(f"{root.name}: {status}")
        previous = ROOT / root.directory
    run.state["ok"] = all(r["ok"] for r in run.state["roots"])
    run.write_state()
    files = sorted(p for p in out.rglob("*") if p.is_file() and p.name != "SHA256SUMS")
    (out / "SHA256SUMS").write_text("".join(
        f"{sha256(p)}  {p.relative_to(out)}\n" for p in files))
    return 0 if run.state["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
