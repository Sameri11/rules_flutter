#!/usr/bin/env python3
"""Reject generated plugin hubs that load ruleset-private modules."""

import argparse
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from unittest.mock import patch


def check(build_file):
    path = Path(build_file)
    if not path.is_file():
        raise ValueError("missing generated hub BUILD file: {}".format(path))
    text = path.read_text()
    if not text.strip():
        raise ValueError("empty generated hub BUILD file: {}".format(path))
    for match in re.finditer(r"load\s*\(\s*[\"']([^\"']+)[\"']", text, re.DOTALL):
        label = match.group(1)
        if "/private" in label:
            raise ValueError("{} loads a private module: {}".format(path, label))


def _hub_build(label):
    result = subprocess.run(
        ["bazel", "query", "--output=location", label],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    if result.returncode:
        raise ValueError("hub query failed for {}:\n{}".format(label, result.stdout))
    locations = []
    for line in result.stdout.splitlines():
        match = re.match(r"^(.+?BUILD(?:\.bazel)?):\d+:\d+:", line)
        if match:
            locations.append(match.group(1))
    if len(locations) != 1:
        raise ValueError("hub query for {} returned no unique BUILD location:\n{}".format(label, result.stdout))
    return locations[0]


def selftest():
    label = "@flutter_plugins//:generated_plugin_registrant_src"
    with tempfile.TemporaryDirectory(prefix="flutter-hub-boundary-") as temp:
        build = Path(temp) / "BUILD.bazel"
        location = "{}:7:1: flutter_plugin_registrant rule {}".format(build, label)

        def run_main(content, expected, query_output=None, returncode=0):
            if content is None:
                build.unlink(missing_ok=True)
            else:
                build.write_text(content)
            result = subprocess.CompletedProcess(
                ["bazel", "query"],
                returncode,
                stdout=(location + "\n") if query_output is None else query_output,
            )
            with patch("subprocess.run", return_value=result):
                try:
                    main([label])
                except ValueError as error:
                    if expected not in str(error):
                        raise
                else:
                    raise ValueError("hub guard accepted input expected to fail: {}".format(expected))

        run_main(
            'load(\n    "@rules_flutter_android//flutter/private:x.bzl",\n    "x",\n)\n',
            "private module",
        )
        run_main("\n", "empty")
        run_main(None, "missing")
        run_main("filegroup(name = 'target')\n", "query failed", returncode=1, query_output="query error")
        run_main("filegroup(name = 'target')\n", "no unique BUILD location", query_output="")
    print("PASS: hub entrypoint rejects private, missing, empty, query-error and empty-result inputs")


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
