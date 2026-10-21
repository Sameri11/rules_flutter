#!/usr/bin/env python3
"""Compare two measurement manifests.

A manifest line is `<sha256>  <path>`; lines starting with `#` are ignored.
Exit 0 when both hold the same entries, 1 on any difference, 2 on bad input.
"""

from __future__ import annotations

import sys
from pathlib import Path


def load(path):
    entries = {}
    for number, line in enumerate(Path(path).read_text().splitlines(), 1):
        if not line.strip() or line.startswith("#"):
            continue
        digest, sep, rel = line.partition("  ")
        if not sep or not digest or not rel:
            raise ValueError("%s:%d: malformed line" % (path, number))
        if rel in entries:
            raise ValueError("%s:%d: duplicate path %s" % (path, number, rel))
        entries[rel] = digest
    if not entries:
        raise ValueError("%s: no entries" % path)
    return entries


def main(argv):
    if len(argv) != 2:
        print("usage: compare_manifests.py FIRST SECOND", file=sys.stderr)
        return 2
    try:
        first = load(argv[0])
        second = load(argv[1])
    except (OSError, ValueError) as err:
        print("compare_manifests: %s" % err, file=sys.stderr)
        return 2
    only_first = sorted(set(first) - set(second))
    only_second = sorted(set(second) - set(first))
    changed = sorted(p for p in set(first) & set(second) if first[p] != second[p])
    if not (only_first or only_second or changed):
        print("manifests match: %d entries" % len(first))
        return 0
    for rel in only_first:
        print("only in first: %s" % rel)
    for rel in only_second:
        print("only in second: %s" % rel)
    for rel in changed:
        print("changed: %s" % rel)
    print(
        "manifests differ: %d only in first, %d only in second, %d changed"
        % (len(only_first), len(only_second), len(changed))
    )
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
