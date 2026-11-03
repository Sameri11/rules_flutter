#!/usr/bin/env python3
"""Exercise native-hook environment analysis through the public consumer API."""

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BAZEL = os.environ.get("BAZEL", "bazel")


def _run(workspace, output_root, target):
    return subprocess.run(
        [
            BAZEL,
            "--output_user_root=" + str(output_root),
            "build",
            "--nobuild",
            "--lockfile_mode=update",
            target,
        ],
        cwd=workspace,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )


def main():
    with tempfile.TemporaryDirectory(prefix="rules-flutter-native-hook-") as tmp:
        temp = Path(tmp)
        workspace = temp / "consumer"
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
        output_root = temp / "output-user-root"
        hook = workspace / "fixtures/production_probe/hook/build.dart"
        pubspec = workspace / "pubspec.yaml"
        original_pubspec = pubspec.read_text()
        try:
            hook_free = _run(workspace, output_root, "//:app_core_assets")
            if hook_free.returncode:
                sys.exit("FAIL: hook-free app without native_build_env did not analyze:\n" + hook_free.stdout)
            hook.parent.mkdir(parents=True)
            hook.write_text("void main() {}\n")
            host = _run(workspace, output_root, "//:app_core_test_assets")
            if host.returncode:
                sys.exit("FAIL: host-test assets required native_build_env:\n" + host.stdout)

            missing = _run(workspace, output_root, "//:app_core_assets")
            if missing.returncode == 0:
                sys.exit("FAIL: production staged hook did not require native_build_env")
            for expected in ("native_build_env", "production_probe"):
                if expected not in missing.stdout:
                    sys.exit("FAIL: missing-environment diagnostic lacked {!r}:\n{}".format(expected, missing.stdout))

            dependency = "  production_probe:\n    path: fixtures/production_probe\n"
            moved = original_pubspec.replace(dependency, "", 1).replace(
                "dev_dependencies:\n",
                "dev_dependencies:\n" + dependency,
                1,
            )
            if moved == original_pubspec:
                sys.exit("FAIL: could not construct the dev-only dependency case")
            pubspec.write_text(moved)
            dev_only = _run(workspace, output_root, "//:app_core_assets")
            if dev_only.returncode:
                sys.exit("FAIL: dev-only staged hook was not excluded:\n" + dev_only.stdout)
            print("PASS: public analysis rejects production staged hooks and accepts hook-free, dev-only, and host-test targets")
        finally:
            pubspec.write_text(original_pubspec)
            subprocess.run(
                [BAZEL, "--output_user_root=" + str(output_root), "shutdown"],
                cwd=workspace,
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )


if __name__ == "__main__":
    main()
