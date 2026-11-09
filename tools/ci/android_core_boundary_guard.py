#!/usr/bin/env python3
"""Reject Android source references to rules_flutter_core private targets."""

import argparse
import sys
import tempfile
from pathlib import Path


def check(root):
    root = Path(root)
    if not root.is_dir():
        raise ValueError("missing Android source root: {}".format(root))
    files = sorted(root.rglob("*.bzl"))
    if not files:
        raise ValueError("empty Android source root: {}".format(root))
    needle = "@rules_flutter_core//flutter/private:"
    for path in files:
        for line_number, line in enumerate(path.read_text().splitlines(), 1):
            if needle in line:
                raise ValueError("{}:{} references a core private target".format(path, line_number))


def selftest():
    with tempfile.TemporaryDirectory(prefix="flutter-core-boundary-") as temp:
        root = Path(temp)
        (root / "android.bzl").write_text('load("@rules_flutter_core//flutter:composition.bzl", "x")\n')
        check(root)
        (root / "android.bzl").write_text('load("@rules_flutter_core//flutter/private:secret.bzl", "x")\n')
        try:
            check(root)
        except ValueError as error:
            if "core private target" not in str(error):
                raise
        else:
            raise ValueError("Android source guard accepted a planted private-core reference")
        (root / "android.bzl").unlink()
        try:
            check(root)
        except ValueError as error:
            if "empty" not in str(error):
                raise
        else:
            raise ValueError("Android source guard accepted an empty source root")
    print("PASS: Android source guard rejects planted and empty inputs")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", nargs="?", default="rules_flutter_android/flutter")
    parser.add_argument("--selftest", action="store_true")
    args = parser.parse_args(argv)
    if args.selftest:
        selftest()
    check(args.root)
    print("PASS: Android source has no core private references")


if __name__ == "__main__":
    try:
        sys.exit(main())
    except ValueError as error:
        print("FAIL: {}".format(error), file=sys.stderr)
        sys.exit(1)
