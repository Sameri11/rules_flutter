#!/usr/bin/env python3
"""Record and compare this project's APK digests across rules_flutter changes.

Two digests per APK: the unsigned APK's bytes, and a sorted
`<CRC> <size> <name>` listing of its ZIP entries. The pair distinguishes a
content change from a pure ZIP-layout change. Signing happens outside Bazel, so
the unsigned artifact is the comparable one.

The APK targets are discovered from the build graph rather than configured, so
an ABI shape that appears or disappears shows up as a row difference.

    bazel/apk_digest.py --record    # after an intended change
    bazel/apk_digest.py             # compare; non-zero exit on any difference

Digests are host-specific: gen_snapshot, the NDK toolchain and gzip differ
between machines and operating systems, so a table recorded here is only
meaningful against the same machine.
"""

from __future__ import annotations

import argparse
import difflib
import hashlib
import subprocess
import sys
import zipfile
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[1]
RECORD = Path(__file__).resolve().parent / "apk_hashes.txt"

QUERY = (
    'attr("generator_function", "^flutter_android_binary$", '
    'kind("_flutter_apk rule", //...))'
)

HEADER = """\
# Recorded APK digests, one line per declared APK:
#
#   <target> apk=<unsigned APK sha256> entries=<canonical entry-listing sha256>
#
# Regenerate with `bazel/apk_digest.py --record`; compare with the same command
# and no flag. Host-specific -- see the module docstring.
"""


def run(argv: list[str]) -> str:
    proc = subprocess.run(argv, cwd=PROJECT, text=True, stdout=subprocess.PIPE)
    if proc.returncode != 0:
        sys.exit("FAIL: {} exited {}".format(" ".join(argv), proc.returncode))
    return proc.stdout


def entry_listing(apk: Path) -> str:
    with zipfile.ZipFile(apk) as zf:
        lines = sorted(
            "{:08x} {} {}".format(info.CRC, info.file_size, info.filename)
            for info in zf.infolist()
        )
    return "\n".join(lines) + "\n"


def unsigned_apks(bazel: str, targets: list[str]) -> dict[str, Path]:
    suffixes = {}
    labels = []
    for target in targets:
        package, _, name = target.removeprefix("//").partition(":")
        suffixes[target] = Path(package) / (name + "_unsigned.apk")
        labels.append("//{}:{}_unsigned.apk".format(package, name))

    outputs = [
        Path(line)
        for line in run(
            [bazel, "cquery", "--output=files", "set({})".format(" ".join(labels))]
        ).splitlines()
    ]
    execution_root = Path(run([bazel, "info", "execution_root"]).strip())

    resolved = {}
    for target, suffix in suffixes.items():
        matches = [
            output
            for output in outputs
            if output.parts[-len(suffix.parts):] == suffix.parts
        ]
        if len(matches) != 1:
            sys.exit(
                "FAIL: {} resolves to {} unsigned APK outputs: {}".format(
                    target, len(matches), matches
                )
            )
        resolved[target] = execution_root / matches[0]
    return resolved


def collect(bazel: str, build: bool) -> list[str]:
    targets = sorted(run([bazel, "query", "--output=label", QUERY]).split())
    if not targets:
        sys.exit("FAIL: no flutter_android_binary APK target in this project.")
    if build:
        print("==> building {} APK shapes".format(len(targets)))
        run([bazel, "build", *targets])

    rows = []
    apks = unsigned_apks(bazel, targets)
    for target in targets:
        apk = apks[target]
        if not apk.is_file():
            sys.exit("FAIL: {} built, but {} is absent.".format(target, apk))
        listing = entry_listing(apk)
        rows.append(
            "{} apk={} entries={}".format(
                target,
                hashlib.sha256(apk.read_bytes()).hexdigest(),
                hashlib.sha256(listing.encode()).hexdigest(),
            )
        )
    return rows


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--record", action="store_true", help="write the digests instead of comparing"
    )
    parser.add_argument("--bazel", default="bazel")
    parser.add_argument(
        "--no-build", action="store_true", help="hash existing outputs without building"
    )
    args = parser.parse_args()

    rows = collect(args.bazel, not args.no_build)

    if args.record:
        RECORD.write_text(HEADER + "\n".join(rows) + "\n")
        print("recorded {} APK shapes to {}".format(len(rows), RECORD))
        return 0

    print("\n".join(rows))

    if not RECORD.is_file():
        print(
            "\nFAIL: nothing recorded at {}. Record the block above with "
            "`--record`.".format(RECORD),
            file=sys.stderr,
        )
        return 1

    expected = [
        line
        for line in RECORD.read_text().splitlines()
        if line and not line.startswith("#")
    ]
    if expected == rows:
        print("\nOK: {} APK shapes match {}".format(len(rows), RECORD))
        return 0

    print(
        "\nFAIL: APK bytes differ from {}. `entries=` moved means the bundle's "
        "contents changed; `apk=` alone means only the zip layout did.\n".format(RECORD),
        file=sys.stderr,
    )
    sys.stderr.writelines(
        difflib.unified_diff(
            [line + "\n" for line in expected],
            [line + "\n" for line in rows],
            fromfile=str(RECORD),
            tofile="this run",
            n=0,
        )
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
