"""Split pubspec.yaml into one file per fact the build consumes.

Every consumer of a fact depends on the file holding *that* fact rather than on
pubspec.yaml, so the blast radius of an edit is the fact it changed: bumping the
version rebuilds the manifest, not the kernel, even though both facts come from
the same source file.

Read as top-level keys rather than with a YAML parser. pubspec.yaml is the only
input and the keys wanted are scalars at column zero, so a nested `name:` or
`version:` belongs to a dependency and must not be picked up.
"""

import argparse
import re
import sys


def fail(message):
    sys.exit("read_pubspec: " + message)


def top_level(path, key):
    """The value of a top-level scalar key, or None."""
    with open(path) as handle:
        for line in handle:
            match = re.match(r"^{}:\s*(\S+)\s*$".format(re.escape(key)), line)
            if match:
                return match.group(1).strip("'\"")
    return None


def package_name(path):
    value = top_level(path, "name")
    if not value:
        fail("{}: no top-level `name:` key.".format(path))

    # Reaching a library as package:<name>/... requires the name pub resolved,
    # so anything the package config cannot spell is refused here.
    if not re.match(r"^[a-z_][a-z0-9_]*$", value):
        fail(
            "{}: package name '{}' is not a valid Dart package name, so no "
            "`package:` URI can address it.".format(path, value),
        )
    return value


def version(path):
    """`version:` as (name, code)."""
    value = top_level(path, "version")
    if not value:
        fail("{}: no top-level `version:` key.".format(path))

    name, sep, code = value.partition("+")
    if not name:
        fail("{}: version '{}' has no name part.".format(path, value))

    # Flutter's own default when the build number is omitted.
    code = code if sep else "1"
    if not code.isdigit():
        fail(
            "{}: build number '{}' is not an integer. Android's versionCode "
            "must be one.".format(path, code),
        )
    return name, code


def write(path, value):
    with open(path, "w") as handle:
        handle.write(value)


def main():
    parser = argparse.ArgumentParser(description = __doc__)
    parser.add_argument("--pubspec", required = True)
    parser.add_argument("--name-out", required = True)
    parser.add_argument("--version-name-out", required = True)
    parser.add_argument("--version-code-out", required = True)
    args = parser.parse_args()

    version_name, version_code = version(args.pubspec)
    write(args.name_out, package_name(args.pubspec))
    write(args.version_name_out, version_name)
    write(args.version_code_out, version_code)


if __name__ == "__main__":
    main()
