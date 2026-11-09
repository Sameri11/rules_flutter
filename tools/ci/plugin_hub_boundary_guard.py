#!/usr/bin/env python3
"""Reject generated plugin hubs that load ruleset-private modules."""

import argparse
import subprocess
import sys
import tempfile
from pathlib import Path


def check(build_file):
    path = Path(build_file)
    if not path.is_file():
        raise ValueError("missing generated hub BUILD file: {}".format(path))
    text = path.read_text()
    if not text.strip():
        raise ValueError("empty generated hub BUILD file: {}".format(path))
    for line_number, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("load(") and "/private" in line:
            raise ValueError("{}:{} loads a private module: {}".format(path, line_number, line.strip()))


def _hub_build(label):
    result = subprocess.run(
        ["bazel", "query", "--output=location", label],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    if result.returncode:
        raise ValueError("hub query failed for {}:\n{}".format(label, result.stdout))
    locations = [line.rsplit(":", 2)[0] for line in result.stdout.splitlines() if line.endswith("BUILD.bazel:1:1")]
    if len(locations) != 1:
        raise ValueError("hub query for {} returned no unique BUILD location:\n{}".format(label, result.stdout))
    return locations[0]


def selftest():
    with tempfile.TemporaryDirectory(prefix="flutter-hub-boundary-") as temp:
        build = Path(temp) / "BUILD.bazel"
        build.write_text('load("@rules_flutter_android//flutter/private:x.bzl", "x")\n')
        try:
            check(build)
        except ValueError as error:
            if "private module" not in str(error):
                raise
        else:
            raise ValueError("hub guard accepted a planted private load")
        build.write_text("\n")
        try:
            check(build)
        except ValueError as error:
            if "empty" not in str(error):
                raise
        else:
            raise ValueError("hub guard accepted an empty BUILD file")
        build.unlink()
        try:
            check(build)
        except ValueError as error:
            if "missing" not in str(error):
                raise
        else:
            raise ValueError("hub guard accepted a missing BUILD file")
    print("PASS: generated-hub guard rejects planted private, empty and missing inputs")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("labels", nargs="*", help="Bazel labels in generated plugin repositories")
    parser.add_argument("--selftest", action="store_true")
    args = parser.parse_args(argv)
    if args.selftest:
        selftest()
    for label in args.labels:
        path = _hub_build(label)
        check(path)
        print("PASS: {} loads no private module ({})".format(label, path))
    if not args.selftest and not args.labels:
        parser.error("provide hub labels or --selftest")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except ValueError as error:
        print("FAIL: {}".format(error), file=sys.stderr)
        sys.exit(1)
