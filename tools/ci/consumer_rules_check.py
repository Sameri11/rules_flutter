#!/usr/bin/env python3
"""Check generated consumer shrink rules reach R8 and leave plain apps unshrunk."""

import json
import os
import re
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CONSUMER = ROOT / "tests/consumer"

PROBE_DESCRIPTOR = b"Lcom/example/fake_plugin/ConsumerRuleProbe;"
R8_APK = CONSUMER / "bazel-bin/consumer_rules_r8.apk"
CONVENTIONAL_RULES = CONSUMER / "fixtures/fake_plugin/android/consumer-rules.pro"
BAZEL = os.environ.get("BAZEL", "bazel")


def run(*args):
    command = [BAZEL, args[0], "--lockfile_mode=error", *args[1:]]
    ndk = os.environ.get("ANDROID_NDK_HOME")
    if ndk:
        command.insert(2, "--repo_env=ANDROID_NDK_HOME=" + ndk)
    result = subprocess.run(
        command,
        cwd=CONSUMER,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode:
        raise RuntimeError(
            "command failed: {}\n{}".format(" ".join(command), result.stdout + result.stderr)
        )
    return result.stdout


def _path_fragments(data):
    fragments = {item["id"]: item for item in data.get("pathFragments", [])}
    resolved = {}

    def resolve(fragment_id):
        if fragment_id not in resolved:
            item = fragments[fragment_id]
            parent_id = item.get("parentId")
            parent = resolve(parent_id) if parent_id is not None else ""
            resolved[fragment_id] = (parent + "/" if parent else "") + item["label"]
        return resolved[fragment_id]

    return {
        item["id"]: resolve(item["pathFragmentId"])
        for item in data.get("artifacts", [])
    }


def _input_paths(action, data, artifacts):
    dep_sets = {item["id"]: item for item in data.get("depSetOfFiles", [])}
    seen = set()
    paths = set()

    def visit(dep_id):
        if dep_id in seen:
            return
        seen.add(dep_id)
        dep = dep_sets.get(dep_id)
        if dep is None:
            return
        paths.update(artifacts[item] for item in dep.get("directArtifactIds", []) if item in artifacts)
        for child in dep.get("transitiveDepSetIds", []):
            visit(child)

    for dep_id in action.get("inputDepSetIds", []):
        visit(dep_id)
    return paths


def r8_inputs(label):
    expression = 'mnemonic("AndroidR8", deps({}))'.format(label)
    raw = run(
        "aquery",
        "-c",
        "opt",
        "--android_platforms=@rules_android//:arm64-v8a",
        "--output=jsonproto",
        expression,
    )
    data = json.loads(raw)
    actions = [action for action in data.get("actions", []) if action.get("mnemonic") == "AndroidR8"]
    return [
        path
        for action in actions
        for path in _input_paths(action, data, _path_fragments(data))
    ]


def _apk_has_probe_class():
    if not R8_APK.is_file():
        raise RuntimeError("R8 APK is missing: {}".format(R8_APK))
    with zipfile.ZipFile(R8_APK) as apk:
        dex_files = [
            entry.filename
            for entry in apk.infolist()
            if re.fullmatch(r"classes[0-9]*\.dex", entry.filename)
        ]
        if not dex_files:
            raise RuntimeError("R8 APK contains no dex files")
        return any(PROBE_DESCRIPTOR in apk.read(name) for name in dex_files)


def _build_r8_apk():
    run(
        "build",
        "-c",
        "opt",
        "--android_platforms=@rules_android//:arm64-v8a",
        "//:consumer_rules_r8",
    )


def _check_rule_dependent_dex():
    _build_r8_apk()
    if not _apk_has_probe_class():
        raise RuntimeError("R8 APK omits the reflectively loaded class protected by consumer rules")

    original_rules = CONVENTIONAL_RULES.read_bytes()
    try:
        CONVENTIONAL_RULES.write_bytes(b"")
        _build_r8_apk()
        if _apk_has_probe_class():
            raise RuntimeError("planted removal of the conventional consumer rule did not strip ConsumerRuleProbe")
        print("PASS: planted rule removal strips the reflection-only class from R8 dex")
    finally:
        CONVENTIONAL_RULES.write_bytes(original_rules)
        _build_r8_apk()

    if not _apk_has_probe_class():
        raise RuntimeError("restored conventional consumer rule did not retain ConsumerRuleProbe")


def main():
    bare = run("query", "--output=build", "@flutter_plugins//namespace_bare:namespace_bare")
    empty = run("query", "--output=build", "@flutter_plugins//namespace_call:namespace_call")
    for label, output in (("namespace_bare", bare), ("namespace_call", empty)):
        if "proguard_specs = []" not in output:
            raise RuntimeError("{} must have no generated consumer shrink rules".format(label))

    shrunk = r8_inputs("//:consumer_rules_r8")
    if not shrunk:
        raise RuntimeError("shrinking consumer has no AndroidR8 action")
    for suffix in (
        "fake_plugin/android/consumer-rules.pro",
        "build_config_plugin/android/custom-consumer.pro",
    ):
        if not any(suffix in path for path in shrunk):
            raise RuntimeError("AndroidR8 inputs omit {}".format(suffix))

    _check_rule_dependent_dex()

    unshrunk = r8_inputs("//:consumer_rules_unshrunk")
    if unshrunk:
        raise RuntimeError("nonshrinking consumer unexpectedly has AndroidR8 inputs: {}".format(unshrunk))
    print("PASS: conventional Kotlin and custom Java rules reach AndroidR8; empty/default and unshrunk cases stay empty")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, json.JSONDecodeError) as error:
        sys.exit("FAIL: {}".format(error))
