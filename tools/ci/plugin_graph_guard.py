#!/usr/bin/env python3
"""Require two consumer app graphs to be nonempty and hub-isolated."""

import argparse
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CONSUMER = ROOT / "tests/consumer"
BAZEL = os.environ.get("BAZEL", "bazel")
FIRST_HUB = "composed_plugins"
SECOND_HUB = "composed_override_plugins"
FIRST_APP = "deps(//composed_app:apk)"
SECOND_APP = "deps(//composed_app:apk_override)"

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
        stderr=subprocess.STDOUT,
        text=True,
    )


def _labels(result, name):
    if result.returncode:
        raise ValueError("{} cquery failed:\n{}".format(name, result.stdout))
    labels = {
        line.strip().split(" ", 1)[0]
        for line in result.stdout.splitlines()
        if line.strip()
    }
    if not labels:
        raise ValueError("{} cquery returned no configured labels".format(name))
    return labels


def _in_hub(label, hub):
    return hub in label.split("//", 1)[0]


def check(first, second):
    first_labels = _labels(_query(first), "first app graph")
    second_labels = _labels(_query(second), "second app graph")
    first_hub = sorted(label for label in first_labels if _in_hub(label, FIRST_HUB))
    second_hub = sorted(label for label in second_labels if _in_hub(label, SECOND_HUB))

    if not first_hub:
        raise ValueError("first app graph does not contain its {} hub".format(FIRST_HUB))
    if not second_hub:
        raise ValueError("second app graph does not contain its {} hub".format(SECOND_HUB))

    first_cross = sorted(label for label in first_labels if _in_hub(label, SECOND_HUB))
    second_cross = sorted(label for label in second_labels if _in_hub(label, FIRST_HUB))
    if first_cross or second_cross:
        raise ValueError(
            "cross-hub plugin labels: first graph references {}; second graph references {}".format(
                ", ".join(first_cross) or "none",
                ", ".join(second_cross) or "none",
            )
        )
    print(
        "PASS: plugin-hub isolation; first app labels={} own_hub_labels={}, "
        "second app labels={} own_hub_labels={}, cross-hub plugin labels=0 "
        "(shared SDK/toolchain labels are permitted)".format(
            len(first_labels),
            len(first_hub),
            len(second_labels),
            len(second_hub),
        )
    )


def selftest():
    planted_failure = _query("//:plugin_graph_guard_missing_target")
    if planted_failure.returncode == 0 or "plugin_graph_guard_missing_target" not in planted_failure.stdout:
        raise ValueError("planted missing-target cquery did not fail with its label")
    try:
        _labels(planted_failure, "planted query")
    except ValueError:
        print("PASS: planted cquery failure is rejected")
    else:
        raise ValueError("graph guard accepted a failed cquery")

    try:
        check(
            "deps(//composed_app:apk + @composed_override_plugins//:all)",
            SECOND_APP,
        )
    except ValueError as error:
        if "cross-hub plugin labels" not in str(error):
            raise
        print("PASS: planted cross-hub reference is rejected")
    else:
        raise ValueError("graph guard accepted a planted cross-hub reference")


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
