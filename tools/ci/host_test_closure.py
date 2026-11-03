#!/usr/bin/env python3
"""Check that the host test closure reaches no Android SDK or NDK.

Discovers test labels with unconfigured `bazel query`, then reads an
`aquery --output=jsonproto` graph for exactly those targets and their closure.
fails when an action reads a file under the Android SDK or NDK repositories,
names an Android SDK or NDK environment variable, or when the closure has no
FlutterTestAssets action (so the check cannot pass on an empty graph).
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
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


def _bazel_output(bazel, arguments):
    command = [bazel] + arguments
    result = subprocess.run(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode:
        sys.exit(
            "Bazel command failed ({}):\n{}{}".format(
                " ".join(command),
                result.stdout,
                result.stderr,
            )
        )
    return result.stdout


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bazel", default="bazel")
    parser.add_argument("--lockfile-mode", default="error")
    parser.add_argument("output_json")
    args = parser.parse_args(argv[1:])

    raw_test_labels = _bazel_output(
        args.bazel,
        [
            "query",
            'kind(".*_test rule", //...) except //android/...',
            "--lockfile_mode=" + args.lockfile_mode,
            "--output=label",
        ],
    ).splitlines()
    test_labels = [label.strip() for label in raw_test_labels if label.strip()]
    invalid_labels = [label for label in test_labels if not label.startswith(("//", "@"))]
    if invalid_labels:
        sys.exit(
            "FAIL: unconfigured test-label query produced non-label output:\n  " +
            "\n  ".join(invalid_labels)
        )
    if not test_labels:
        sys.exit("FAIL: unconfigured test-label query returned no targets")
    expression = "deps(set({}))".format(" ".join(test_labels))
    query_output = _bazel_output(
        args.bazel,
        [
            "aquery",
            expression,
            "--output=jsonproto",
            "--lockfile_mode=" + args.lockfile_mode,
        ],
    )
    with open(args.output_json, "w") as handle:
        handle.write(query_output)
    with open(args.output_json) as handle:
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
