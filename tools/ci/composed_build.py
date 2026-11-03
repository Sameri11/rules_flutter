#!/usr/bin/env python3
"""Build consumer composed APK checks and mode artifacts."""

import argparse
import os
import shlex
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKSPACE = ROOT / "tests" / "consumer"
BAZEL = os.environ.get("BAZEL", "bazel")
ABIS = ("arm64-v8a", "x86_64", "armeabi-v7a")
PLATFORMS = ",".join("@rules_android//:" + abi for abi in ABIS)
MODE_FLAGS = {
    "release": ("-c", "opt", "--@rules_flutter_core//flutter:mode=release"),
    "debug": ("--@rules_flutter_core//flutter:mode=debug", "-c", "fastbuild"),
}
CHECKS = {
    "release": ("//composed_app:apk_check_test", "//composed_app:apk_variant_check_test",
                "//composed_app:apk_override_contents_check", "//composed_app:direct_apk"),
    "debug": ("//composed_app:apk_check_test", "//composed_app:apk_variant_check_test",
              "//composed_app:native_files_coexistence_check", "//composed_app:native_files_override_check",
              "//composed_app:direct_apk"),
}


def build(*args):
    argv = [
        BAZEL,
        "build",
        "--lockfile_mode=" + os.environ.get("BAZEL_LOCKFILE_MODE", "error"),
        "--repo_env=ANDROID_NDK_HOME=" + os.environ.get("ANDROID_NDK_HOME", ""),
        *args,
    ]
    print(shlex.join(argv), flush=True)
    subprocess.run(argv, cwd=WORKSPACE, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("mode", choices=MODE_FLAGS)
    parser.add_argument("evidence_dir", type=Path)
    args = parser.parse_args()
    evidence = args.evidence_dir.resolve()
    flags = MODE_FLAGS[args.mode]
    build(*flags, "--android_platforms=@rules_android//:arm64-v8a", "--", *CHECKS[args.mode])

    if args.mode == "release":
        # Configure the three OS-specific roots directly; keep the rest host-configured.
        roots = tuple("//composed_app:core_libapp_" + abi for abi in ABIS)
        build(*flags, "--android_platforms=" + PLATFORMS,
              "--platforms=@rules_android//:arm64-v8a", "--", *roots)
        # This partition retains every non-libapp root and must run last for host artifacts.
        excluded = tuple("-" + root for root in roots)
        build(*flags, "--android_platforms=" + PLATFORMS, "--", "//composed_app:all", *excluded)
    else:
        build(*flags, "--android_platforms=" + PLATFORMS, "--", "//composed_app:all")

    shutil.copy2(WORKSPACE / "bazel-bin/composed_app/direct_apk.apk",
                 evidence / ("direct-" + args.mode + ".apk"))
    shutil.copy2(WORKSPACE / "bazel-bin/composed_app/composed_aar.aar",
                 evidence / ("composed-" + args.mode + ".aar"))


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        raise SystemExit(error.returncode)
