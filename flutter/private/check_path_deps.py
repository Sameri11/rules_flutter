"""Fail the build when a `path:` dependency is not declared as a build input.

Hosted packages are pinned by a sha256 in pubspec.lock, so their content is
observable in the action key. Path dependencies are not: they carry no hash and
a version nobody bumps. An undeclared one produces a silently stale artifact,
and with a shared remote cache that artifact is served to everyone.

This compares the `source: path` entries in pubspec.lock against the files
actually declared via `path_deps`, and fails if any is uncovered.
"""

import argparse
import os
import re
import sys

# pubspec.lock is YAML, but the subset needed here is a fixed shape and the
# stdlib has no YAML parser, so match it directly rather than take a dependency.
_PACKAGE = re.compile(r"^  ([A-Za-z_][A-Za-z0-9_]*):\s*$")
_PATH = re.compile(r"^      path:\s*\"?([^\"\n]+)\"?\s*$")
_SOURCE = re.compile(r"^    source:\s*(\S+)\s*$")


def path_dependencies(lock_text):
    """Yield (package_name, path) for every path-sourced package."""
    current, path = None, None
    for line in lock_text.splitlines():
        matched = _PACKAGE.match(line)
        if matched:
            current, path = matched.group(1), None
            continue
        matched = _PATH.match(line)
        if matched:
            path = matched.group(1)
            continue
        matched = _SOURCE.match(line)
        if matched and matched.group(1) == "path" and current and path:
            yield current, path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--lock", required=True)
    parser.add_argument("--package-dir", required=True,
                        help="Bazel package of the app, e.g. 'app'.")
    parser.add_argument("--declared", nargs="*", default=[],
                        help="Files declared via path_deps, execroot-relative.")
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    with open(args.lock) as handle:
        deps = list(path_dependencies(handle.read()))

    missing = []
    for name, raw in deps:
        # pubspec.lock paths are relative to the app; declared files are
        # execroot-relative, so rebase before comparing.
        rooted = os.path.normpath(os.path.join(args.package_dir, raw))
        covered = any(
            os.path.normpath(f).startswith(rooted + os.sep)
            for f in args.declared
        )
        if not covered:
            missing.append((name, raw, rooted))

    if missing:
        lines = [
            "",
            "Undeclared path: dependencies -- these are invisible to the action key.",
            "Editing one would silently produce a stale artifact, and a shared",
            "remote cache would serve it to every other machine.",
            "",
        ]
        for name, raw, rooted in missing:
            lines.append("  {} (path: {})".format(name, raw))
            lines.append("      expected declared files under: {}/".format(rooted))
        lines += [
            "",
            "Add a filegroup in the dependency's package and declare it:",
            "",
            "  # {}/BUILD.bazel".format(missing[0][2]),
            '  filegroup(name = "srcs", srcs = glob(["lib/**/*.dart"]))',
            "",
            "  # this package",
            '  path_deps = ["//{}:srcs"]'.format(missing[0][2]),
            "",
        ]
        sys.stderr.write("\n".join(lines))
        return 1

    with open(args.out, "w") as handle:
        handle.write("checked {} path dependencies\n".format(len(deps)))
        for name, raw in deps:
            handle.write("  {} -> {}\n".format(name, raw))
    return 0


if __name__ == "__main__":
    sys.exit(main())
