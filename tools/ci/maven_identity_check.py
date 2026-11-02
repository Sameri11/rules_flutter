#!/usr/bin/env python3
"""Check project-derived Maven selection through public Android helpers."""

import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CONSUMER = ROOT / "tests/consumer"
BAZEL = os.environ.get("BAZEL", "bazel")


def query(expression):
    command = [BAZEL, "cquery", "--lockfile_mode=error", "--output=label", expression]
    ndk = os.environ.get("ANDROID_NDK_HOME")
    if ndk:
        command.insert(2, "--repo_env=ANDROID_NDK_HOME=" + ndk)
    return subprocess.run(
        command,
        cwd=CONSUMER,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )


def main():
    positive = query(
        "//:apk + //:maven_alias_inputs + //:maven_custom_no_plugins_inputs + //:maven_reused_app"
    )
    if positive.returncode or not positive.stdout.strip():
        sys.exit("FAIL: public positive Maven cases did not configure:\n" + positive.stdout)
    print("PASS: project-derived, canonical alias, reused-input, and plugin-free custom selections")

    for target in ("maven_mismatch_inputs", "maven_mismatch_app", "maven_mismatched_reused_inputs_app"):
        result = query("//:" + target)
        if result.returncode == 0:
            sys.exit("FAIL: public mismatch target unexpectedly configured: " + target)
        for repository in (
            "rules_jvm_external++maven+plugin_maven",
            "rules_jvm_external++maven+flutter_maven",
        ):
            if repository not in result.stdout:
                sys.exit(
                    "FAIL: {} diagnostic did not name both canonical Maven repositories:\n{}".format(
                        target, result.stdout
                    )
                )
        print("PASS: {} rejects and names both canonical repositories".format(target))


if __name__ == "__main__":
    main()
