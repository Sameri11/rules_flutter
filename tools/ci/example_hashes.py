#!/usr/bin/env python3
"""Build example APKs and gate on their recorded digests.

Each module is queried before building: `EXAMPLES` must exactly name every
`flutter_android_binary`-generated Android target. Each target records raw
unsigned APK bytes and a canonical ZIP entry listing; together they distinguish
bundle-content changes from ZIP-layout changes.
"""

from __future__ import annotations

import argparse
import difflib
import hashlib
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

# Exact (example, module, declared Flutter APK targets) inventory, checked against query.
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
DEFAULT_GOLDEN = REPO_ROOT / "tools" / "ci" / "example_hashes_macos.txt"
DEFAULT_MANIFESTS = REPO_ROOT / "_ci_hashes"

HEADER = """\
# Recorded APK hashes, one line per declared APK:
#
#   <example> <target> apk=<unsigned APK sha256> entries=<canonical entry-listing sha256>
#
# Regenerate with `tools/ci/example_hashes.py --record` and commit intentional byte changes.
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


def unsigned_apks(
        bazel: str, module: Path, targets: tuple[str, ...]) -> dict[str, Path]:
    suffixes = {}
    output_labels = []
    for target in targets:
        package, _, name = target.removeprefix("//").partition(":")
        suffixes[target] = Path(package) / (name + "_unsigned.apk")
        output_labels.append("//{}:{}_unsigned.apk".format(package, name))

    outputs = [
        Path(line)
        for line in run(
            [bazel, "cquery", "--output=files", "set({})".format(
                " ".join(output_labels)
            )],
            module,
        ).splitlines()
    ]
    execution_root = Path(run([bazel, "info", "execution_root"], module).strip())
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


def declared_apk_targets(bazel: str, module: Path) -> set[str]:
    """Return every Android binary a Flutter APK macro generated in `module`.

    `generator_function` is target-graph metadata Bazel records for rules
    emitted by a macro. Querying it is resilient to formatting, aliases, and
    generated per-ABI names; parsing BUILD source would not be.

    Queries the macro's public `_flutter_apk` wrapper, not its private
    `android_binary`.
    """
    query = (
        'attr("generator_function", "^flutter_android_binary$", '
        'kind("_flutter_apk rule", //...))'
    )
    return set(run([bazel, "query", "--output=label", query], module).splitlines())


def assert_target_inventory(
        example: str, configured: tuple[str, ...], declared: set[str]) -> None:
    """Fail unless configured labels are the declared Flutter APK target set."""
    configured_set = set(configured)
    missing = sorted(declared - configured_set)
    stale = sorted(configured_set - declared)
    if missing or stale:
        problems = []
        if missing:
            problems.append(
                "EXAMPLES is missing declared Flutter APK target(s): {}".format(
                    ", ".join(missing)
                )
            )
        if stale:
            problems.append(
                "EXAMPLES lists stale Flutter APK target(s): {}".format(
                    ", ".join(stale)
                )
            )
        sys.exit("FAIL: {}: {}.".format(example, "; ".join(problems)))


def collect(bazel: str, manifests: Path, build: bool, only: str | None) -> list[str]:
    rows: list[str] = []
    for example, directory, targets in EXAMPLES:
        if only and only != example:
            continue
        module = REPO_ROOT / directory
        assert_target_inventory(
            example, targets, declared_apk_targets(bazel, module)
        )
        if build:
            print("==> building {} ({} APK shapes)".format(example, len(targets)))
            run([bazel, "build", *targets], module)
        apks = unsigned_apks(bazel, module, targets)
        for target in targets:
            apk = apks[target]
            if not apk.is_file():
                sys.exit(
                    "FAIL: {} {} built, but configured output {} is absent. "
                    "`_flutter_apk` declares this sibling output.".format(
                        example, target, apk
                    )
                )
            listing = entry_listing(apk)
            manifests.mkdir(parents=True, exist_ok=True)
            slug = "{}{}".format(example, target.replace("/", "_").replace(":", "_"))
            (manifests / (slug + ".entries.txt")).write_text(listing)
            shutil.copyfile(apk, manifests / (slug + ".apk"))
            rows.append(
                "{} {} apk={} entries={}".format(
                    example,
                    target,
                    hashlib.sha256(apk.read_bytes()).hexdigest(),
                    hashlib.sha256(listing.encode()).hexdigest(),
                )
            )
    return rows


def row_key(row: str) -> tuple[str, str]:
    example, target = row.split(" ")[:2]
    return example, target


def recorded_rows(golden: Path) -> list[str]:
    return [
        line
        for line in golden.read_text().splitlines()
        if line and not line.startswith("#")
    ]


def configured_row_keys() -> list[tuple[str, str]]:
    return [
        (example, target)
        for example, _, targets in EXAMPLES
        for target in targets
    ]


def validate_only(only: str) -> None:
    names = [example for example, _, _ in EXAMPLES]
    if only not in names:
        sys.exit(
            "FAIL: --only {!r} is not a configured example; expected one of: {}."
            .format(only, ", ".join(names))
        )


def validate_subset_baseline(
        existing: list[str] | None, only: str, golden: Path) -> list[str]:
    """Require a subset record to start from every unselected configured row."""
    if existing is None:
        sys.exit(
            "FAIL: cannot `--record --only {}`: no existing whole-repository "
            "golden at {}. First record every example with "
            "`tools/ci/example_hashes.py --record` (without `--only`).".format(
                only, golden
            )
        )

    order = configured_row_keys()
    present = {row_key(row) for row in existing}
    unknown = sorted(present - set(order))
    if unknown:
        sys.exit(
            "FAIL: cannot `--record --only {}`: {} has rows this script does "
            "not know how to build: {}. Re-record the whole table first."
            .format(only, golden, unknown)
        )

    missing = [
        key for key in order if key[0] != only and key not in present
    ]
    if missing:
        sys.exit(
            "FAIL: cannot `--record --only {}`: {} lacks configured row(s) "
            "outside the selected example: {}. First record every example "
            "with `tools/ci/example_hashes.py --record` (without `--only`)."
            .format(
                only,
                golden,
                ", ".join("{} {}".format(*key) for key in missing),
            )
        )
    return existing


def merge(existing: list[str], fresh: list[str]) -> list[str]:
    """Replace the rows `fresh` covers, keep the rest, emit in table order.

    A subset record may do this only after `validate_subset_baseline()` proves
    the existing table already covers every other configured APK shape.
    """
    order = configured_row_keys()
    merged = {row_key(row): row for row in existing}
    merged.update({row_key(row): row for row in fresh})

    unknown = sorted(set(merged) - set(order))
    if unknown:
        sys.exit(
            "FAIL: the recorded table has rows this script does not know how to "
            "build: {}. EXAMPLES and the table disagree, so a merge would guess "
            "at what to keep; re-record the whole table instead.".format(unknown)
        )
    return [merged[key] for key in order if key in merged]


def selftest() -> int:
    """Check the hermetic logic that protects the recorded APK inventory.

    In-process and hermetic: no Bazel, no APKs, no filesystem. Run by
    //tools/ci:example_hashes_selftest. It prevents a bad `--only` value from
    reaching Bazel, a subset record from creating or retaining a partial table,
    and an APK shape declared by `flutter_android_binary` from being omitted
    from `EXAMPLES`.

    A self-check rather than a py_test: this repository does not depend on
    rules_python and Bazel 9 has no native py_binary (tools/flutter/defs.bzl).
    """
    first = EXAMPLES[0][0]
    a0, a1 = EXAMPLES[0][2][0], EXAMPLES[0][2][1]
    second, _, second_targets = EXAMPLES[1]
    b0 = second_targets[0]
    golden = Path("example_hashes.txt")

    existing = [
        "{} {} apk=old-{} entries=old-{}".format(
            example, target, example, target
        )
        for example, _, targets in EXAMPLES
        for target in targets
    ]
    fresh = [
        "{} {} apk=new-{} entries=new-{}".format(first, target, first, target)
        for target in EXAMPLES[0][2]
    ]

    # A complete baseline admits a subset update, preserves every unrelated
    # row, and returns to EXAMPLES' canonical order.
    validate_subset_baseline(existing, first, golden)
    merged = merge(existing, fresh)
    assert len(merged) == len(existing), merged
    assert all(
        row.startswith("{} ".format(first)) and "apk=new-" in row
        for row in merged[:len(fresh)]
    ), merged
    assert merged[len(fresh):] == existing[len(fresh):], merged
    assert merge(list(reversed(existing)), fresh) == merged

    # An unknown selection fails before it can enter collect().
    try:
        validate_only("demo_ap")
    except SystemExit as exit_:
        assert "demo_ap" in str(exit_) and "configured example" in str(exit_), exit_
    else:
        raise AssertionError("an unknown --only selection was silently accepted")

    # A subset record cannot create a new partial table or fill a different
    # partial table: all unselected configured rows are mandatory.
    try:
        validate_subset_baseline(None, first, golden)
    except SystemExit as exit_:
        assert "no existing" in str(exit_) and str(golden) in str(exit_), exit_
    else:
        raise AssertionError("an absent subset baseline was silently accepted")
    incomplete = [row for row in existing if row_key(row) != (second, b0)]
    try:
        validate_subset_baseline(incomplete, first, golden)
    except SystemExit as exit_:
        assert second in str(exit_) and b0 in str(exit_), exit_
    else:
        raise AssertionError("an incomplete unrelated baseline was silently accepted")

    # A row the script cannot rebuild must stop a subset record rather than
    # vanish when merging.
    try:
        validate_subset_baseline(
            existing + ["ghost //a:b apk=x entries=x"], first, golden
        )
    except SystemExit as exit_:
        assert "ghost" in str(exit_), exit_
    else:
        raise AssertionError("an unknown baseline row was silently accepted")

    # The configured set must be exact: an omitted declared ABI shape and a
    # stale configured target both name the example and offending label.
    declared = {a0, a1}
    try:
        assert_target_inventory(first, (a0,), declared)
    except SystemExit as exit_:
        assert first in str(exit_) and a1 in str(exit_), exit_
    else:
        raise AssertionError("a missing declared target passed")
    try:
        assert_target_inventory(first, (a0, "//ghost:apk"), {a0})
    except SystemExit as exit_:
        assert first in str(exit_) and "//ghost:apk" in str(exit_), exit_
    else:
        raise AssertionError("a stale configured target passed")

    print(
        "OK: subset records require a complete baseline and APK inventory is exact"
    )
    return 0


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
        help="write what this run produced into the recorded table; `--record "
        "--only` requires an existing complete golden for every other example "
        "and replaces only that example's rows",
    )
    mode.add_argument(
        "--selftest",
        action="store_true",
        help="check subset-record preconditions and configured-APK-inventory "
        "logic in-process; builds nothing",
    )
    parser.add_argument("--golden", type=Path, default=DEFAULT_GOLDEN)
    parser.add_argument("--manifests", type=Path, default=DEFAULT_MANIFESTS)
    parser.add_argument("--bazel", default="bazel")
    parser.add_argument(
        "--only",
        help="restrict to one configured example by name; `--record --only` "
        "requires an existing complete golden for all other examples",
    )
    parser.add_argument(
        "--no-build",
        action="store_true",
        help="hash configured outputs without building first",
    )
    args = parser.parse_args()

    if args.selftest:
        return selftest()

    if args.only:
        validate_only(args.only)

    baseline = None
    if args.record and args.only:
        if args.golden.is_file():
            baseline = recorded_rows(args.golden)
        baseline = validate_subset_baseline(baseline, args.only, args.golden)

    rows = collect(args.bazel, args.manifests, not args.no_build, args.only)

    if args.record:
        # Subset preconditions are checked before collect(), so failures cannot
        # query/build Bazel or modify a golden. The validated baseline contains
        # every unselected configured row; merge replaces only the selection.
        written = rows
        if args.only:
            written = merge(baseline, rows)
        args.golden.write_text(HEADER + "\n".join(written) + "\n")
        print(
            "recorded {} of {} APK shapes to {}".format(
                len(rows), len(written), args.golden
            )
        )
        return 0

    print("\n".join(rows))

    # The recorded table is whole-repo, so --only compares against the subset
    # belonging to that example. An empty subset fails rather than passes: it
    # means the name is wrong, or the example was never recorded.
    if not args.golden.is_file():
        print(
            "\nFAIL: no recorded table at {}. Record the block above with "
            "`tools/ci/example_hashes.py --record`.".format(args.golden),
            file=sys.stderr,
        )
        return 1

    expected = recorded_rows(args.golden)
    if args.only:
        expected = [line for line in expected if line.split(" ", 1)[0] == args.only]
        if not expected:
            print(
                "\nFAIL: {} records nothing for example {!r}.".format(
                    args.golden, args.only
                ),
                file=sys.stderr,
            )
            return 1

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
