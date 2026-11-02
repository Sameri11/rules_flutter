#!/usr/bin/env python3
"""Require the removed per-app plugin_deps argument to fail analysis."""

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

BAZEL = os.environ.get("BAZEL", "bazel")

ROOT = Path(__file__).resolve().parents[2]


def main():
    with tempfile.TemporaryDirectory(prefix="rules-flutter-plugin-deps-") as tmp:
        workspace = Path(tmp) / "consumer"
        shutil.copytree(
            ROOT / "tests/consumer",
            workspace,
            ignore=shutil.ignore_patterns("bazel-*", "MODULE.bazel.lock", "*.checked"),
        )
        module = workspace / "MODULE.bazel"
        text = module.read_text()
        for name in ("rules_flutter_core", "rules_flutter_android"):
            text = text.replace(
                'path = "../../{}"'.format(name),
                'path = "{}"'.format(ROOT / name),
            )
        module.write_text(text)
        (workspace / ".bazelrc").write_text("common --enable_bzlmod\n")

        build = workspace / "BUILD.bazel"
        build.write_text(
            build.read_text()
            + """

flutter_android_app(
    name = "plugin_deps_rejected",
    core = ":app_core",
    manifest_values = {"applicationId": "com.example.rejected"},
    plugins = None,
    plugin_deps = None,
    tags = ["manual"],
)
"""
        )
        output_root = Path(tmp) / "output-user-root"
        result = subprocess.run(
            [
                BAZEL,
                "--output_user_root=" + str(output_root),
                "build",
                "--lockfile_mode=update",
                "//:plugin_deps_rejected",
            ],
            cwd=workspace,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        subprocess.run(
            [BAZEL, "--output_user_root=" + str(output_root), "shutdown"],
            cwd=workspace,
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if result.returncode == 0:
            sys.exit("FAIL: flutter_android_app accepted the removed plugin_deps argument")
        if "plugin_deps" not in result.stdout or "no such attribute" not in result.stdout.lower():
            sys.exit("FAIL: rejection did not identify the removed plugin_deps attribute:\n" + result.stdout)
        print("PASS: flutter_android_app rejects the removed plugin_deps argument in an isolated fixture")


if __name__ == "__main__":
    main()
