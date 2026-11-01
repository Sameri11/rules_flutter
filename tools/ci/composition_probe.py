#!/usr/bin/env python3
"""Exercise direct core packaging, raw native composition and strict compilation."""
import collections
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[2]
CONSUMER = ROOT / "tests/consumer"
RESULT = Path(os.environ.get("RUNNER_TEMP", "/tmp")) / "composition-results"
RESULT.mkdir(exist_ok=True)
ABIS = ("arm64-v8a", "x86_64", "armeabi-v7a")
BASE = ["--disk_cache=", "--remote_cache=", "--worker_quit_after_build", "--jobs=4",
        "--repo_env=ANDROID_NDK_HOME=" + os.environ["ANDROID_NDK_HOME"]]
records = []


def run(name, arguments, expected=None):
    command = ["bazel"] + arguments
    log = RESULT / (name + ".log")
    with log.open("w") as out:
        completed = subprocess.run(command, cwd=CONSUMER, stdout=out, stderr=subprocess.STDOUT)
    text = log.read_text()
    records.append({"name": name, "command": command, "exit": completed.returncode})
    (RESULT / "commands.json").write_text(json.dumps(records, indent=2) + "\n")
    if expected:
        if completed.returncode == 0 or expected not in text:
            print(text[-18000:])
            raise RuntimeError(name + ": expected failure containing " + expected)
    elif completed.returncode:
        print(text[-18000:])
        raise RuntimeError(name + ": build failed")
    print(name + ": " + ("expected rejection" if expected else "passed"), flush=True)


def options(mode, abis):
    return BASE + ["-c", "opt" if mode == "release" else "fastbuild",
                   "--@rules_flutter_core//flutter:mode=" + mode,
                   "--android_platforms=" + ",".join("@rules_android//:" + abi for abi in abis)]


def inspect_apk(mode, abis, name):
    source = CONSUMER / "bazel-bin/composed_app/direct_apk.apk"
    dest = RESULT / (name + ".apk")
    shutil.copyfile(source, dest)
    with zipfile.ZipFile(dest) as apk, zipfile.ZipFile(CONSUMER / "bazel-bin/composed_app/composed_aar.aar") as aar:
        names = set(apk.namelist())
        actual = {p.split("/")[1] for p in names if p.startswith("lib/") and p.endswith(".so")}
        assert actual == set(abis), (name, actual, abis)
        expected = {"libflutter.so", "libaar_native.so", "libcmake_marker.so", "librecipe_marker.so"}
        expected |= {"libapp.so"} if mode == "release" else {"libdev_cmake_marker.so"}
        for abi in abis:
            shipped = {p.split("/")[-1] for p in names if p.startswith("lib/" + abi + "/") and p.endswith(".so")}
            assert expected <= shipped, (name, abi, expected - shipped)
            assert ("libapp.so" in shipped) == (mode == "release")
            assert ("libdev_cmake_marker.so" in shipped) == (mode == "debug")
            assert apk.read("lib/" + abi + "/libaar_native.so") == aar.read("jni/" + abi + "/libaar_native.so")
        assert {p for p in aar.namelist() if p.endswith(".so")} == {"jni/" + abi + "/libaar_native.so" for abi in ABIS}
        kernel = "assets/flutter_assets/kernel_blob.bin"
        assert (kernel in names) == (mode == "debug"), (name, kernel)
        assert "classes.dex" in names
    return {"name": name, "abis": list(abis), "sha256": hashlib.sha256(dest.read_bytes()).hexdigest()}


def graph(mode):
    command = ["bazel", "aquery", "deps(//composed_app:direct_apk) + deps(//composed_app:apk)",
               "--output=jsonproto"] + options(mode, ABIS)
    path = RESULT / (mode + "-graph.json")
    with path.open("w") as out, (RESULT / (mode + "-graph.log")).open("w") as err:
        subprocess.run(command, cwd=CONSUMER, stdout=out, stderr=err, check=True)
    actions = json.loads(path.read_text()).get("actions", [])
    assert actions, "empty action graph"
    counts = collections.Counter(action.get("mnemonic") for action in actions)
    for obsolete in ("AndroidNativeLibJar", "JniLibJar", "StripNativeLibs"):
        assert not counts[obsolete], (mode, obsolete, counts[obsolete])
    assert counts["AndroidNativeLibStrip"] >= 6, counts
    assert counts["DirectCoreEngineStrip"] == 3, counts
    print(json.dumps({"mode": mode, "mnemonics": counts}, sort_keys=True), flush=True)


def planted(name, path, before, after, arguments, expected):
    original = path.read_text()
    assert original.count(before) == 1, (path, before)
    try:
        path.write_text(original.replace(before, after))
        run(name, arguments, expected)
    finally:
        path.write_text(original)


def main():
    apks = []
    try:
        run("wildcard-host-analysis", ["build", "--nobuild", "//..."] + BASE + ["-c", "opt"])
        for mode in ("release", "debug"):
            run(mode + "-wildcard", ["build", "//composed_app:all"] + options(mode, ABIS))
            for name, abis in [("fat", ABIS)] + [(abi, (abi,)) for abi in ABIS]:
                label = mode + "-" + name
                run(label, ["build", "//composed_app:direct_apk"] + options(mode, abis))
                apks.append(inspect_apk(mode, abis, label))
            graph(mode)
        run("missing-abi", ["build", "//composed_app:direct_native_files"] + options("release", ()),
            "direct core packaging needs an Android ABI")
        planted("missing-engine", ROOT / "rules_flutter_core/flutter/private/core.bzl",
                "    engine_libs = ctx.files.engine_libs\n",
                "    engine_libs = [] if abi == \"arm64-v8a\" else ctx.files.engine_libs\n",
                ["build", "//composed_app:direct_apk"] + options("release", ("arm64-v8a",)),
                "ABI 'arm64-v8a' has no engine libraries")
        planted("strict-annotation-rejection", CONSUMER / "BUILD.bazel",
                "    exports = EMBEDDING_DEPS,\n", "    exports = [],\n",
                ["build", "@composed_plugins//:generated_plugin_registrant"] + options("release", ("arm64-v8a",)),
                "NonNull")
        run("restored-strict-compile", ["build", "@composed_plugins//:generated_plugin_registrant",
                                        "//composed_app:direct_activity"] + options("release", ("arm64-v8a",)))
        run("restored-direct-apk", ["build", "//composed_app:direct_apk"] + options("release", ("arm64-v8a",)))
        (RESULT / "apks.json").write_text(json.dumps(apks, indent=2) + "\n")
        print("PASS: direct output groups, eight APK ABI/mode checks, raw AAR bytes, jar-free graphs, wildcard and planted failures", flush=True)
    finally:
        subprocess.run(["bazel", "shutdown"], cwd=CONSUMER, check=False)


if __name__ == "__main__":
    main()
