#!/usr/bin/env python3
"""Require two consumer app graphs to be nonempty and project-isolated."""

import argparse
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CONSUMER = ROOT / "tests/consumer"
BAZEL = os.environ.get("BAZEL", "bazel")
FIRST_APP = "deps(//:apk)"
SECOND_APP = "deps(//composed_app:apk)"
FIRST_PROJECT_REPOS = (
    "pub",
    "flutter_plugins",
    "plugin_maven",
)
SECOND_PROJECT_REPOS = (
    "composed_pub",
    "composed_plugins",
    "flutter_maven",
)
NATIVE_EDGE_TARGETS = (
    ("standard", "@composed_plugins//cmake_plugin:cmake_plugin"),
    ("recipe", "@composed_override_plugins//cmake_plugin:cmake_plugin"),
)
DART_ONLY_EDGE_SUFFIXES = (
    "//production_probe:production_probe",
    "//shared_probe:shared_probe",
    "//dev_only_probe:dev_only_probe",
)
REAL_NATIVE_EDGE_SUFFIX = "//composed_plugin:composed_plugin"

PUB_REPOSITORY = "sameri11_rules_flutter_core++pub+pub"
REGISTRANT_CALLS = {
    "dev_only_probe": "dev_only_probe_android.DevOnlyProbe.registerWith()",
    "production_probe": "production_probe_android.ProductionProbe.registerWith()",
    "shared_probe": "shared_probe_android.SharedProbe.registerWith()",
}


def _check_dart_registrants():
    output_base = subprocess.run(
        [BAZEL, "info", "--noshow_progress", "--lockfile_mode=error", "output_base"],
        cwd=CONSUMER,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    output_base_lines = output_base.stdout.strip().splitlines()
    if output_base.returncode or not output_base_lines:
        raise ValueError("Bazel output_base lookup failed:\n{}".format(output_base.stdout))
    repository = Path(output_base_lines[-1]) / "external" / PUB_REPOSITORY
    modes = (
        ("debug", repository / "dart_plugin_registrant.dart", set(REGISTRANT_CALLS)),
        ("release", repository / "dart_plugin_registrant_release.dart", {"production_probe", "shared_probe"}),
    )
    for mode, path, expected in modes:
        try:
            source = path.read_text()
        except OSError as error:
            raise ValueError("{} registrant is unavailable at {}: {}".format(mode, path, error)) from error
        counts = {name: source.count(call) for name, call in REGISTRANT_CALLS.items()}
        total_calls = source.count(".registerWith()")
        expected_count = len(expected)
        if (
            any(counts[name] != (1 if name in expected else 0) for name in counts)
            or total_calls != expected_count
            or (mode == "release" and "package:dev_only_probe/" in source)
        ):
            raise ValueError(
                "{} registrant has unexpected registration reachability: "
                "class_counts={} total_calls={} expected_total={}".format(
                    mode, counts, total_calls, expected_count
                )
            )
        print("PASS: {} Dart registrant registerWith counts={}".format(mode, counts))


def _check_native_edges():
    for name, target in NATIVE_EDGE_TARGETS:
        labels = _labels(
            _query("deps({}, 1)".format(target)),
            "{} native dependency graph".format(name),
        )
        real_native = sorted(label for label in labels if label.endswith(REAL_NATIVE_EDGE_SUFFIX))
        dart_only = sorted(
            label
            for label in labels
            if any(label.endswith(suffix) for suffix in DART_ONLY_EDGE_SUFFIXES)
        )
        if not real_native:
            raise ValueError("{} native dependency graph omits its real native plugin".format(name))
        if dart_only:
            raise ValueError(
                "{} native dependency graph contains non-native plugin labels: {}".format(
                    name,
                    ", ".join(dart_only),
                )
            )
        print(
            "PASS: {} native plugin edges preserve {} and exclude Dart-only targets; "
            "configured labels={} retained_native={}".format(
                name,
                REAL_NATIVE_EDGE_SUFFIX,
                len(labels),
                len(real_native),
            )
        )


def _check_query_failure():
    build_file = CONSUMER / "BUILD.bazel"
    original = build_file.read_bytes()
    planted_target = b"""

filegroup(
    name = "graph_guard_missing_target",
    srcs = ["@composed_plugins//composed_plugin:plugin_graph_guard_missing_target"],
    tags = ["manual"],
)
"""
    try:
        build_file.write_bytes(original + planted_target)
        planted = _query("deps(//:graph_guard_missing_target)")
    finally:
        build_file.write_bytes(original)
    output = planted.stdout + planted.stderr
    if planted.returncode == 0 or "plugin_graph_guard_missing_target" not in output:
        raise ValueError("planted missing native target query did not fail with its label:\n{}".format(output))
    try:
        _labels(planted, "planted missing native target")
    except ValueError:
        print("PASS: missing native dependency on a real fixture target is rejected")
    else:
        raise ValueError("graph guard accepted a missing native target")


def _query(expression):
    return subprocess.run(
        [
            BAZEL,
            "cquery",
            "--noshow_progress",
            "--noshow_loading_progress",
            "--lockfile_mode=error",
            "--output=label",
            expression,
        ],
        cwd=CONSUMER,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


def _labels(result, name):
    if result.returncode:
        raise ValueError("{} cquery failed:\n{}".format(name, result.stdout + result.stderr))
    labels = set()
    for line in result.stdout.splitlines():
        token = line.strip().split(" ", 1)[0]
        if token.startswith("//") or (token.startswith("@") and "//" in token):
            labels.add(token)
    if not labels:
        raise ValueError("{} cquery returned no configured labels".format(name))
    return labels



def _repo(label):
    return label.split("//", 1)[0].lstrip("@")


def _project_repos(labels, repositories):
    return {
        repository: sorted(label for label in labels if _repo(label) == repository)
        for repository in repositories
    }


def check(first, second):
    first_labels = _labels(_query(first), "first app graph")
    second_labels = _labels(_query(second), "second app graph")
    first_repos = _project_repos(first_labels, FIRST_PROJECT_REPOS)
    second_repos = _project_repos(second_labels, SECOND_PROJECT_REPOS)
    first_missing = sorted(repo for repo, labels in first_repos.items() if not labels)
    second_missing = sorted(repo for repo, labels in second_repos.items() if not labels)
    if first_missing or second_missing:
        raise ValueError(
            "app graph lacks project markers: first missing {}; second missing {}".format(
                ", ".join(first_missing) or "none",
                ", ".join(second_missing) or "none",
            )
        )

    first_cross = sorted(label for label in first_labels if _repo(label) in SECOND_PROJECT_REPOS)
    second_cross = sorted(label for label in second_labels if _repo(label) in FIRST_PROJECT_REPOS)
    if first_cross or second_cross:
        raise ValueError(
            "cross-project plugin/pub/Maven labels: first graph references {}; "
            "second graph references {}".format(
                ", ".join(first_cross) or "none",
                ", ".join(second_cross) or "none",
            )
        )
    print(
        "PASS: isolated project plugin/pub/Maven graphs; first labels={} markers={}, "
        "second labels={} markers={}, cross-project labels=0 "
        "(shared SDK/toolchain labels are permitted)".format(
            len(first_labels),
            {repo: len(labels) for repo, labels in first_repos.items()},
            len(second_labels),
            {repo: len(labels) for repo, labels in second_repos.items()},
        )
    )
    _check_dart_registrants()
    _check_native_edges()



def selftest():
    _check_query_failure()
    empty = _query("deps(//:apk) except deps(//:apk)")
    if empty.returncode:
        raise ValueError("planted empty cquery unexpectedly failed:\n{}".format(empty.stdout + empty.stderr))
    try:
        _labels(empty, "planted empty query")
    except ValueError as error:
        if "returned no configured labels" not in str(error):
            raise
        print("PASS: empty successful query is rejected")
    else:
        raise ValueError("graph guard accepted a successful empty cquery")

    try:
        check("deps(//:graph_guard_cross_hub)", SECOND_APP)
    except ValueError as error:
        if "cross-project plugin/pub/Maven labels" not in str(error):
            raise
        print("PASS: planted cross-hub dependency is rejected")
    else:
        raise ValueError("graph guard accepted a planted cross-hub dependency")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--first", default=FIRST_APP)
    parser.add_argument("--second", default=SECOND_APP)
    parser.add_argument("--selftest", action="store_true")
    args = parser.parse_args(argv)

    try:
        if args.selftest:
            selftest()
        check(args.first, args.second)
    except ValueError as error:
        sys.exit("FAIL: {}".format(error))
    return 0


if __name__ == "__main__":
    sys.exit(main())
