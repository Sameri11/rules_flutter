#!/usr/bin/env python3
"""Check that the host test closure reaches no Android SDK or NDK.

Reads `bazel aquery --output=jsonproto` output for the host test targets and
fails when an action reads a file under the Android SDK or NDK repositories,
names an Android SDK or NDK environment variable, or when the closure has no
FlutterTestAssets action (so the check cannot pass on an empty graph).
"""

from __future__ import annotations

import json
import re
import sys

SDK_INPUT = re.compile(r"external/([^/]*\+)?(androidsdk|androidndk)/|/_android_sdk_marker(/|$)")
SDK_ENV = re.compile(r"ANDROID_(HOME|SDK|SDK_ROOT|NDK_HOME|NDK_ROOT)\b")
SAMPLE = 20


def _fragment_paths(data):
    fragments = {fragment["id"]: fragment for fragment in data.get("pathFragments", [])}

    def path(fragment_id):
        parts = []
        while fragment_id:
            fragment = fragments[fragment_id]
            parts.append(fragment["label"])
            fragment_id = fragment.get("parentId", 0)
        return "/".join(reversed(parts))

    return path


def _input_paths(data):
    fragment_path = _fragment_paths(data)
    artifacts = {artifact["id"]: fragment_path(artifact["pathFragmentId"]) for artifact in data.get("artifacts", [])}
    depsets = {depset["id"]: depset for depset in data.get("depSetOfFiles", [])}
    memo = {}

    def closure(depset_id):
        if depset_id not in memo:
            depset = depsets[depset_id]
            paths = {artifacts[i] for i in depset.get("directArtifactIds", [])}
            for child in depset.get("transitiveDepSetIds", []):
                paths |= closure(child)
            memo[depset_id] = paths
        return memo[depset_id]

    def inputs(action):
        paths = set()
        for depset_id in action.get("inputDepSetIds", []):
            paths |= closure(depset_id)
        return paths

    return inputs


def main(argv):
    if len(argv) != 2:
        sys.exit("usage: host_test_closure.py AQUERY_JSON")
    with open(argv[1]) as handle:
        data = json.load(handle)
    inputs = _input_paths(data)
    actions = data.get("actions", [])

    sdk_inputs = []
    sdk_env = []
    assets = 0
    for action in actions:
        mnemonic = action.get("mnemonic", "")
        if mnemonic == "FlutterTestAssets":
            assets += 1
        for path in sorted(inputs(action)):
            if SDK_INPUT.search(path):
                sdk_inputs.append("{} {}".format(mnemonic, path))
        text = " ".join(action.get("arguments", []))
        text += " " + " ".join(
            "{}={}".format(item["key"], item.get("value", "")) for item in action.get("environmentVariables", [])
        )
        match = SDK_ENV.search(text)
        if match:
            sdk_env.append("{} {}".format(mnemonic, match.group(0)))

    print(
        "host test closure: {} actions, {} Android SDK/NDK inputs, {} Android environment mentions, "
        "{} FlutterTestAssets actions".format(len(actions), len(sdk_inputs), len(sdk_env), assets)
    )
    failures = []
    if not actions:
        failures.append("the host test closure has no actions")
    if sdk_inputs:
        failures.append("Android SDK or NDK inputs:\n  " + "\n  ".join(sdk_inputs[:SAMPLE]))
    if sdk_env:
        failures.append("Android environment mentions:\n  " + "\n  ".join(sdk_env[:SAMPLE]))
    if assets == 0:
        failures.append("no FlutterTestAssets action; the check would pass vacuously")
    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
