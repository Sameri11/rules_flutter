#!/usr/bin/env python3
"""Build every example APK and gate on its bytes.

Each example module is built in its own Bazel invocation -- they are separate
modules, so there is no single `//...` that covers them -- and every APK shape
the module declares is hashed twice:

  apk      sha256 of `<target>_unsigned.apk`, the packaging step's own output.
           Signing is excluded on purpose: `rules_android` signs with a debug
           key, and the release path deliberately stops before signing
           (docs_internal/android-packaging.md).
  entries  sha256 of a sorted `<crc> <size> <name>` line per zip entry. This is
           the content digest: it moves when a file in the bundle changes and
           does *not* move when only compression or padding does, so a
           mismatch in `apk` alone localises the change to the zip layout.

`--check` compares both against a recorded table and fails on any difference.
The per-APK entry listings are written under `--manifests` so a red gate can be
diffed against the previous run's uploaded listings, which is the only way to
see *which* entry moved.

The table below is written out rather than globbed: a new example has to be
added here deliberately, the same reason the CI workflow lists them.
"""

from __future__ import annotations

import argparse
import difflib
import hashlib
import subprocess
import sys
import zipfile
from pathlib import Path

# (example name, module directory, APK targets). `flutter_android_binary`
# derives one target per shape -- the fat APK plus `<name>_<abi>` for each ABI
# when more than one is declared -- so demo_app carries four.
EXAMPLES = (
    (
        "demo_app",
        "examples/demo_app",
        (
            "//android/app:demo_app",
            "//android/app:demo_app_arm64-v8a",
            "//android/app:demo_app_x86_64",
            "//android/app:demo_app_armeabi-v7a",
        ),
    ),
    ("no_plugins", "examples/no_plugins", ("//android/app:no_plugins",)),
    ("pub_plugins", "examples/pub_plugins", ("//android/app:pub_plugins",)),
    (
        "local_plugin",
        "examples/local_plugin",
        ("//packages/host_app/android/app:host_app",),
    ),
)

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_GOLDEN = REPO_ROOT / "tools" / "ci" / "example_hashes.txt"
DEFAULT_MANIFESTS = REPO_ROOT / "_ci_hashes"

HEADER = """\
# Recorded APK hashes for every example, one line per APK shape:
#
#   <example> <target> apk=<sha256 of _unsigned.apk> entries=<sha256 of listing>
#
# Regenerate with `tools/ci/example_hashes.py --record` and commit the result in
# the same change that moved the bytes. A diff here with no intended packaging
# change is the gate doing its job.
#
# Recorded on a GitHub Actions runner: absolute paths reach some actions (see
# docs_internal/key-portability-measurement.md), so a local run may legitimately
# disagree. CI is the reference.
"""


def run(argv: list[str], cwd: Path) -> str:
    proc = subprocess.run(
        argv,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=None,
    )
    if proc.returncode != 0:
        sys.exit(
            "FAIL: {} (in {}) exited {}".format(
                " ".join(argv), cwd, proc.returncode
            )
        )
    return proc.stdout


def entry_listing(apk: Path) -> str:
    with zipfile.ZipFile(apk) as zf:
        lines = sorted(
            "{:08x} {} {}".format(info.CRC, info.file_size, info.filename)
            for info in zf.infolist()
        )
    return "\n".join(lines) + "\n"


def unsigned_apk(bazel_bin: Path, target: str) -> Path:
    package, _, name = target.removeprefix("//").partition(":")
    return bazel_bin / package / (name + "_unsigned.apk")


def collect(bazel: str, manifests: Path, build: bool, only: str | None) -> list[str]:
    rows: list[str] = []
    for example, directory, targets in EXAMPLES:
        if only and only != example:
            continue
        module = REPO_ROOT / directory
        if build:
            print("==> building {} ({} APK shapes)".format(example, len(targets)))
            run([bazel, "build", *targets], module)
        bazel_bin = Path(run([bazel, "info", "bazel-bin"], module).strip())
        for target in targets:
            apk = unsigned_apk(bazel_bin, target)
            if not apk.is_file():
                sys.exit(
                    "FAIL: {} {} built, but {} is absent. `android_binary` "
                    "declares it as the packaging step's output; a rename "
                    "upstream means this script needs updating.".format(
                        example, target, apk
                    )
                )
            listing = entry_listing(apk)
            manifests.mkdir(parents=True, exist_ok=True)
            slug = "{}{}".format(example, target.replace("/", "_").replace(":", "_"))
            (manifests / (slug + ".entries.txt")).write_text(listing)
            rows.append(
                "{} {} apk={} entries={}".format(
                    example,
                    target,
                    hashlib.sha256(apk.read_bytes()).hexdigest(),
                    hashlib.sha256(listing.encode()).hexdigest(),
                )
            )
    return rows


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--check",
        action="store_true",
        help="compare against the recorded table and fail on any difference "
        "(default)",
    )
    mode.add_argument(
        "--record",
        action="store_true",
        help="overwrite the recorded table with what this run produced",
    )
    parser.add_argument("--golden", type=Path, default=DEFAULT_GOLDEN)
    parser.add_argument("--manifests", type=Path, default=DEFAULT_MANIFESTS)
    parser.add_argument("--bazel", default="bazel")
    parser.add_argument(
        "--only",
        help="restrict to one example by name, for local iteration",
    )
    parser.add_argument(
        "--no-build",
        action="store_true",
        help="hash what is already in bazel-bin instead of building first",
    )
    args = parser.parse_args()

    rows = collect(args.bazel, args.manifests, not args.no_build, args.only)
    table = HEADER + "\n".join(rows) + "\n"

    if args.record:
        args.golden.write_text(table)
        print("recorded {} APK shapes to {}".format(len(rows), args.golden))
        return 0

    print("\n".join(rows))
    if args.only:
        print(
            "\nnot checked: --only builds a subset, which cannot be compared "
            "against a whole-table record."
        )
        return 0

    if not args.golden.is_file():
        print(
            "\nFAIL: no recorded table at {}. Record the block above with "
            "`tools/ci/example_hashes.py --record`.".format(args.golden),
            file=sys.stderr,
        )
        return 1

    expected = [
        line
        for line in args.golden.read_text().splitlines()
        if line and not line.startswith("#")
    ]
    if expected == rows:
        print("\nOK: {} APK shapes match {}".format(len(rows), args.golden))
        return 0

    print(
        "\nFAIL: example APK bytes differ from {}. Every difference is either a "
        "packaging regression or an intended change that has to be recorded.\n"
        "`entries=` moved means the bundle's contents changed; `apk=` alone "
        "means only the zip layout did. The uploaded entry listings say which "
        "file.\n".format(args.golden),
        file=sys.stderr,
    )
    sys.stderr.writelines(
        difflib.unified_diff(
            [line + "\n" for line in expected],
            [line + "\n" for line in rows],
            fromfile=str(args.golden),
            tofile="this run",
            n=0,
        )
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
