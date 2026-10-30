"""Refuse a pubspec that flutter_assets cannot bundle faithfully.

flutter_assets runs `flutter build bundle --release`, and it
does not model two features that change what `flutter build` bundles: deferred
components (split asset loading) and asset transformers (asset processing that
depends on the build mode). A pubspec that declares either would get a bundle
that differs from flutter's, so the build stops and names the feature.

Read line by line inside the top-level `flutter:` block, as read_pubspec.py reads
its keys. pubspec.yaml is YAML, but both keys are plain mapping keys with fixed
spellings, and a parser is not needed to find them.
"""

import argparse
import re
import sys

# Mapping keys refused, each with the feature it names in the failure message.
UNSUPPORTED = (
    ("deferred-components", "deferred components"),
    ("transformers", "asset transformers"),
)


def flutter_block(lines):
    """(line number, line) for each line under the top-level `flutter:` key."""
    inside = False
    for number, line in enumerate(lines, 1):
        if line.strip() == "" or line.lstrip().startswith("#"):
            continue
        if not line[0].isspace():
            inside = re.match(r"^flutter:\s*(#.*)?$", line) is not None
        elif inside:
            yield number, line


def main():
    parser = argparse.ArgumentParser(description = __doc__)
    parser.add_argument("--pubspec", required = True)
    args = parser.parse_args()

    with open(args.pubspec) as handle:
        lines = handle.read().splitlines()

    for number, line in flutter_block(lines):
        for key, feature in UNSUPPORTED:
            if re.match(r"^\s*(-\s+)?{}:".format(re.escape(key)), line):
                sys.exit(
                    "check_bundle_pubspec: {}:{}: {} are not supported by flutter_assets "
                    "(`{}:`), so this bundle would differ from `flutter build`'s. "
                    "Remove the key, or build this app's assets with `flutter build`.".format(
                        args.pubspec,
                        number,
                        feature,
                        key,
                    ),
                )


if __name__ == "__main__":
    main()
