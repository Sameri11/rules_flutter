#!/usr/bin/env python3
"""Probe configured libapp rejection and guard against an Android fallback."""

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

BAZEL = os.environ.get("BAZEL", "bazel")
ROOT = Path(__file__).resolve().parents[2]


def run(workspace, output_user_root):
    return subprocess.run(
        [
            BAZEL,
            "--output_user_root=" + str(output_user_root),
            "build",
            "--nobuild",
            "--lockfile_mode=update",
            "--platforms=@platforms//host:host",
            "//:app_core_libapp_arm64-v8a",
        ],
        cwd=workspace,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )


def main():
    with tempfile.TemporaryDirectory(prefix="rules-flutter-target-os-") as tmp:
        tmp = Path(tmp)
        core_copy = tmp / "rules_flutter_core"
        shutil.copytree(
            ROOT / "rules_flutter_core",
            core_copy,
            ignore=shutil.ignore_patterns("bazel-*", "MODULE.bazel.lock", "*.checked"),
        )
        core_rules_copy = core_copy / "flutter/private/core.bzl"
        workspace = tmp / "consumer"
        shutil.copytree(
            ROOT / "tests/consumer",
            workspace,
            ignore=shutil.ignore_patterns("bazel-*", "MODULE.bazel.lock", "*.checked"),
        )
        module = workspace / "MODULE.bazel"
        text = module.read_text()
        text = text.replace(
            'path = "../../rules_flutter_core"',
            'path = "{}"'.format(core_copy),
        ).replace(
            'path = "../../rules_flutter_android"',
            'path = "{}"'.format(ROOT / "rules_flutter_android"),
        )
        module.write_text(text)
        (workspace / ".bazelrc").write_text("common --enable_bzlmod\n")
        output_user_root = tmp / "output-user-root"

        try:
            rejected = run(workspace, output_user_root)
            if rejected.returncode == 0:
                sys.exit("FAIL: host-configured macro-generated libapp unexpectedly analyzed")
            for expected in (
                "Target OS selection failed for label",
                "app_core_libapp_arm64-v8a (ABI arm64-v8a)",
            ):
                if expected not in rejected.stdout:
                    sys.exit("FAIL: rejection lacked {!r}:\n{}".format(expected, rejected.stdout))

            original = core_rules_copy.read_text()
            fallback = '"//conditions:default": None,'
            planted = '"//conditions:default": ":" + name + "_kernel_neutral",'
            if original.count(fallback) != 1:
                sys.exit("FAIL: could not uniquely locate the rejecting OS selection")
            try:
                core_rules_copy.write_text(original.replace(fallback, planted, 1))
                accepted = run(workspace, output_user_root)
            finally:
                core_rules_copy.write_text(original)
            if accepted.returncode != 0:
                sys.exit("FAIL: planted Android fallback was not detected by the probe:\n" + accepted.stdout)
            print("PASS: configured libapp rejects without an OS kernel and detects an Android fallback")
        finally:
            subprocess.run(
                [BAZEL, "--output_user_root=" + str(output_user_root), "shutdown"],
                cwd=workspace,
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )


if __name__ == "__main__":
    main()
