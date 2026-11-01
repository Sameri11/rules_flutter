#!/usr/bin/env python3
"""Check the consumer composed app's direct and helper routes.

Expects `direct-<mode>.apk` and `composed-<mode>.aar` from the release and
debug composed builds in the evidence directory. For each mode it captures the
3-ABI action graph and fails when an obsolete native carrier reappears, raw
native stripping is missing, or the direct route strips different SDK engine
inputs than the helper route. The direct APK must ship exactly the three ABIs
and the AAR's native payloads unchanged. Finally, each single-ABI AAR fixture
that lacks its native library must fail to build for that reason.
"""

from __future__ import annotations

import argparse
import collections
import json
import os
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKSPACE = ROOT / "tests" / "consumer"
ABIS = ("arm64-v8a", "x86_64", "armeabi-v7a")
PLATFORMS = ",".join("@rules_android//:" + abi for abi in ABIS)
ROOTS = (
    "deps(//composed_app:direct_apk) + deps(//composed_app:apk)"
    " + deps(//composed_app:apk_variant)"
)
MODE_FLAGS = {
    "release": ("-c", "opt", "--@rules_flutter_core//flutter:mode=release"),
    "debug": ("-c", "fastbuild", "--@rules_flutter_core//flutter:mode=debug"),
}
OBSOLETE = ("AndroidNativeLibJar", "FlutterNativeLibs", "JniLibJar", "StripNativeLibs")
MISSING_NATIVE = (
    ("aar_missing_native_arm64", "arm64-v8a"),
    ("aar_missing_native_x86_64", "x86_64"),
    ("aar_missing_native_armeabi_v7a", "armeabi-v7a"),
)


def bazel(command, *args, stdout=None, stderr=None):
    argv = [
        "bazel", command,
        "--lockfile_mode=" + os.environ.get("BAZEL_LOCKFILE_MODE", "error"),
        "--repo_env=ANDROID_NDK_HOME=" + os.environ.get("ANDROID_NDK_HOME", ""),
        *args,
    ]
    return subprocess.run(argv, cwd=WORKSPACE, stdout=stdout, stderr=stderr).returncode


def check_mode(mode, graph_path, apk_path, aar_path):
    with open(graph_path) as source:
        actions = json.load(source).get("actions", [])
    if not actions:
        sys.exit(f"{mode} direct/helper graph is empty")
    counts = collections.Counter(action.get("mnemonic") for action in actions)
    for mnemonic in OBSOLETE:
        if counts[mnemonic]:
            sys.exit(f"{mode} graph contains obsolete {mnemonic} actions")
    if not counts["AndroidNativeLibStrip"]:
        sys.exit(f"{mode} graph contains no raw native strip actions")
    # The strip input is the last argument of both engine strip actions.
    direct_inputs = [
        action["arguments"][-1] for action in actions
        if action.get("mnemonic") == "DirectCoreEngineStrip"
    ]
    helper_inputs = [
        action["arguments"][-1] for action in actions
        if action.get("mnemonic") == "FlutterEngineStrip"
    ]
    if not direct_inputs or len(direct_inputs) != len(set(direct_inputs)):
        sys.exit(f"{mode} direct engine strips are absent or duplicate: {direct_inputs}")
    if collections.Counter(direct_inputs) != collections.Counter(helper_inputs):
        sys.exit(f"{mode} direct/helper engine inputs differ: {direct_inputs} != {helper_inputs}")
    with zipfile.ZipFile(apk_path) as apk, zipfile.ZipFile(aar_path) as aar:
        names = set(apk.namelist())
        actual_abis = {
            path.split("/")[1] for path in names
            if path.startswith("lib/") and path.endswith(".so")
        }
        if actual_abis != set(ABIS):
            sys.exit(f"{mode} direct APK ABIs are {sorted(actual_abis)}")
        expected_aar = {"jni/" + abi + "/libaar_native.so" for abi in ABIS}
        actual_aar = {path for path in aar.namelist() if path.endswith(".so")}
        if actual_aar != expected_aar:
            sys.exit(f"{mode} AAR native entries are {sorted(actual_aar)}")
        for abi in ABIS:
            shipped = "lib/" + abi + "/libaar_native.so"
            source = "jni/" + abi + "/libaar_native.so"
            if shipped not in names or apk.read(shipped) != aar.read(source):
                sys.exit(f"{mode} {abi} AAR native payload differs")
    print(f"{mode}: actions={counts} direct_engine_inputs={direct_inputs}")


def check_missing_native(evidence):
    for target, abi in MISSING_NATIVE:
        log = evidence / (target + ".log")
        with open(log, "w") as output:
            code = bazel(
                "build", *MODE_FLAGS["release"],
                "--android_platforms=@rules_android//:" + abi,
                "//composed_app:" + target,
                stdout=output, stderr=subprocess.STDOUT,
            )
        if code == 0:
            sys.exit(f"missing native input unexpectedly built: {target}")
        text = log.read_text()
        if "no .so files" not in text:
            sys.stderr.write(text)
            sys.exit(f"missing native input failed for the wrong reason: {target}")
        print(f"{target}: rejected for its missing {abi} library")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "evidence",
        type=Path,
        help="directory holding the composed APKs and AARs; graphs and logs are written here",
    )
    evidence = parser.parse_args().evidence.resolve()
    for mode, flags in MODE_FLAGS.items():
        graph = evidence / f"composed-{mode}-aquery.json"
        with open(graph, "w") as output:
            if bazel("aquery", *flags, "--android_platforms=" + PLATFORMS,
                     "--output=jsonproto", ROOTS, stdout=output):
                sys.exit(f"{mode} aquery failed")
        check_mode(
            mode, graph, evidence / f"direct-{mode}.apk", evidence / f"composed-{mode}.aar"
        )
    check_missing_native(evidence)


if __name__ == "__main__":
    main()
