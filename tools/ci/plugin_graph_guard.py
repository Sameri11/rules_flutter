#!/usr/bin/env python3
"""Require two generated plugin graphs to be queryable and label-isolated."""

import argparse
import os
import subprocess
import sys
from pathlib import Path
 

ROOT = Path(__file__).resolve().parents[2]
CONSUMER = ROOT / "tests/consumer"
BAZEL = os.environ.get("BAZEL", "bazel")


def _query(expression):
    return subprocess.run(
        [BAZEL, "cquery", "--lockfile_mode=error", "--output=label", expression],
        cwd=CONSUMER,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )


def _graph_labels(result, marker, name):
    if result.returncode:
        raise ValueError("{} cquery failed:\n{}".format(name, result.stdout))
    labels = {line.strip().split(" ", 1)[0] for line in result.stdout.splitlines() if line.strip()}
    if not labels:
        raise ValueError("{} cquery returned no configured labels".format(name))
    owned = {
        label
        for label in labels
        if marker in label.split("//", 1)[0]
    }
    if not owned:
        raise ValueError("{} cquery returned no labels owned by {}".format(name, marker))
    return owned


def check(first, second):
    first_labels = _graph_labels(_query(first), "composed_plugins", "first graph")
    second_labels = _graph_labels(_query(second), "composed_override_plugins", "second graph")
    overlap = sorted(first_labels & second_labels)
    if overlap:
        raise ValueError("plugin graphs share labels: {}".format(", ".join(overlap)))
    print("PASS: both plugin graphs are nonempty; 0 cross-graph labels")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--first", default="deps(@composed_plugins//:all)")
    parser.add_argument("--second", default="deps(@composed_override_plugins//:all)")
    parser.add_argument("--selftest", action="store_true", help="plant a cquery failure and require fail-closed behavior")
    args = parser.parse_args(argv)

    if args.selftest:
        planted = _query("//:plugin_graph_guard_missing_target")
        if planted.returncode == 0 or "plugin_graph_guard_missing_target" not in planted.stdout:
            sys.exit("FAIL: missing-target cquery did not produce the planted failure:\n" + planted.stdout)
        try:
            _graph_labels(planted, "plugin_graph_guard_missing_target", "planted graph")
        except ValueError:
            print("PASS: planted cquery failure is rejected")
        else:
            sys.exit("FAIL: graph guard accepted a failed cquery")

    try:
        check(args.first, args.second)
    except ValueError as error:
        sys.exit("FAIL: {}".format(error))
    return 0


if __name__ == "__main__":
    sys.exit(main())
