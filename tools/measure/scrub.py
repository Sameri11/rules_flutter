#!/usr/bin/env python3
"""Replace the cache token in a measurement tree, in place.

  scrub.py --tree DIR

The cache token lives in the rc file and in the BEP and profile output. Gzip files are
decompressed for the replacement and recompressed. The tree is rewritten in place: a copy
would double the disk use of a run whose execution logs alone reach several GB. Symlinks
are skipped.
"""

from __future__ import annotations

import argparse
import gzip
import os
import sys
from pathlib import Path

TOKEN_ENV = "BAZEL_CACHE_TOKEN_RW"
MIN_TOKEN_LEN = 8
GZIP_MAGIC = b"\x1f\x8b"


def cache_token():
    token = os.environ.get(TOKEN_ENV, "")
    if not token:
        raise SystemExit("scrub: %s is not set; refusing to upload unscrubbed files" % TOKEN_ENV)
    if len(token) < MIN_TOKEN_LEN:
        raise SystemExit("scrub: %s is too short to scrub reliably" % TOKEN_ENV)
    return token.encode("utf-8")


def walk_files(root):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for name in sorted(filenames):
            path = Path(dirpath) / name
            if not path.is_symlink():
                yield path


def scrub_file(path, token):
    raw = path.read_bytes()
    gz = raw[:2] == GZIP_MAGIC
    body = gzip.decompress(raw) if gz else raw
    if token not in body:
        return False
    body = body.replace(token, b"<redacted>")
    path.write_bytes(gzip.compress(body) if gz else body)
    return True


def scrub_tree(root, token):
    root = Path(root)
    if not root.is_dir():
        raise SystemExit("scrub: not a directory: %s" % root)
    scrubbed = 0
    for path in walk_files(root):
        if scrub_file(path, token):
            scrubbed += 1
    print("scrub: replaced the cache token in %d file(s)" % scrubbed)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tree", required=True)
    args = parser.parse_args(argv)
    scrub_tree(args.tree, cache_token())
    return 0


if __name__ == "__main__":
    sys.exit(main())
