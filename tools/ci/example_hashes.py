#!/usr/bin/env python3
"""Build example APKs and gate on their recorded digests.

EXAMPLES lists every Flutter-generated Android APK label. Each configured
row records its mode and selected ABI set. Unsigned APK hashes and canonical ZIP
entry hashes distinguish bytes from content/layout changes.
Baselines require the CI toolchain, including RECORDED_NDK for native libraries.
"""

from __future__ import annotations

import argparse
import difflib
import hashlib
import json
import os
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

# Each row is (example, module, target, mode, ABI selection, Bazel flags).
ANDROID_ABIS = ("arm64-v8a", "x86_64", "armeabi-v7a")
DEMO_TARGET = "//android/app:demo_app"
DEMO_RELEASE_FLAGS = (
    "-c", "opt", "--@rules_flutter_core//flutter:mode=release",
)
DEMO_DEBUG_FLAGS = (
    "-c", "fastbuild", "--@rules_flutter_core//flutter:mode=debug",
)


def demo_rows(example: str, mode: str, flags: tuple[str, ...]):
    return tuple(
        (example, "examples/demo_app", DEMO_TARGET, mode, abi, flags + platform)
        for abi, platform in (
            ("fat", (
                "--android_platforms=@rules_android//:arm64-v8a,"
                "@rules_android//:x86_64,@rules_android//:armeabi-v7a",
            )),
            ("arm64-v8a", ("--android_platforms=@rules_android//:arm64-v8a",)),
            ("x86_64", ("--android_platforms=@rules_android//:x86_64",)),
            ("armeabi-v7a", ("--android_platforms=@rules_android//:armeabi-v7a",)),
        )
    )


EXAMPLES = (
    *demo_rows("demo_app", "release", DEMO_RELEASE_FLAGS),
    *demo_rows("demo_app_debug", "debug", DEMO_DEBUG_FLAGS),
    ("no_plugins", "examples/no_plugins", "//android/app:no_plugins",
     "release", "arm64-v8a",
     DEMO_RELEASE_FLAGS + ("--android_platforms=@rules_android//:arm64-v8a",)),
    ("pub_plugins", "examples/pub_plugins", "//android/app:pub_plugins",
     "release", "arm64-v8a",
     DEMO_RELEASE_FLAGS + ("--android_platforms=@rules_android//:arm64-v8a",)),
    ("local_plugin", "examples/local_plugin",
     "//packages/host_app/android/app:host_app", "release", "arm64-v8a",
     DEMO_RELEASE_FLAGS + ("--android_platforms=@rules_android//:arm64-v8a",)),
)


REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_GOLDEN = REPO_ROOT / "tools" / "ci" / "example_hashes_macos.txt"
DEFAULT_MANIFESTS = REPO_ROOT / "_ci_hashes"

# The NDK CI records the rows with; keep equal to the one selected in
# .github/actions/flutter-bazel/action.yml.
RECORDED_NDK = "28.2.13676358"

HEADER = """\
# Recorded APK hashes by example, target, build mode and selected ABIs:
#   <example> <target> mode=<release|debug> abi=<fat|ABI> apk=<sha256> entries=<sha256>
#
# Valid for Android NDK 28.2.13676358, CI's: another NDK changes every
# NDK-compiled library. See the docstring of tools/ci/example_hashes.py.
#
# Regenerate with `tools/ci/example_hashes.py --record` and commit intentional byte changes.
"""
BAZEL_LOCKFILE_MODE = os.environ.get("BAZEL_LOCKFILE_MODE", "error")
if BAZEL_LOCKFILE_MODE not in ("error", "update"):
    sys.exit("FAIL: BAZEL_LOCKFILE_MODE must be error or update.")


def run(argv: list[str], cwd: Path) -> str:
    if len(argv) > 1 and argv[1] in ("aquery", "build", "cquery", "info", "query"):
        if not any(arg.startswith("--lockfile_mode=") for arg in argv[2:]):
            argv.insert(2, "--lockfile_mode=" + BAZEL_LOCKFILE_MODE)
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


def ndk_revision() -> str | None:
    """Return `Pkg.Revision` of the NDK at ANDROID_NDK_HOME, or None."""
    home = os.environ.get("ANDROID_NDK_HOME")
    if not home:
        return None
    try:
        lines = (Path(home) / "source.properties").read_text().splitlines()
    except OSError:
        return None
    for line in lines:
        key, _, value = line.partition("=")
        if key.strip() == "Pkg.Revision":
            return value.strip()
    return None


def entry_listing(apk: Path) -> str:
    with zipfile.ZipFile(apk) as zf:
        lines = sorted(
            "{:08x} {} {}".format(info.CRC, info.file_size, info.filename)
            for info in zf.infolist()
        )
    return "\n".join(lines) + "\n"


def unsigned_apk(
        bazel: str, module: Path, target: str,
        flags: tuple[str, ...]) -> Path:
    package, _, name = target.removeprefix("//").partition(":")
    output_label = "//{}:{}_unsigned.apk".format(package, name)
    outputs = run(
        [bazel, "cquery", *flags, "--output=files", output_label],
        module,
    ).splitlines()
    matches = [
        Path(output) for output in outputs
        if Path(output).name == name + "_unsigned.apk"
    ]
    if len(matches) != 1:
        sys.exit(
            "FAIL: {} resolves to {} unsigned APK outputs: {}".format(
                target, len(matches), matches
            )
        )
    execution_root = Path(run([bazel, "info", "execution_root"], module).strip())
    return execution_root / matches[0]


def declared_apk_targets(bazel: str, module: Path) -> set[str]:
    """Return every APK target generated by the Flutter app helper."""
    result = run(
        [bazel, "query", "--output=label",
         'attr("generator_function", "^flutter_android_app$", kind("android_binary rule", //...))'],
        module,
    )
    return set(result.splitlines())


def expected_abis(selection: str) -> set[str]:
    return set(ANDROID_ABIS if selection == "fat" else (selection,))


def apk_abis(apk: Path) -> set[str]:
    with zipfile.ZipFile(apk) as zf:
        return {
            path.split("/")[1]
            for path in zf.namelist()
            if path.startswith("lib/") and path.endswith(".so")
        }


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
    configured_row_keys()
    selected = [row for row in EXAMPLES if not only or row[0] == only]
    inventories = {}
    for example, directory in dict.fromkeys(
            (row[0], row[1]) for row in selected):
        module = REPO_ROOT / directory
        labels = tuple(row[2] for row in selected if row[0] == example)
        key = (example, module)
        if key not in inventories:
            inventories[key] = declared_apk_targets(bazel, module)
        assert_target_inventory(example, labels, inventories[key])

    for example, directory, target, mode, abi, flags in selected:
        module = REPO_ROOT / directory
        slug = "{}_{}_{}_{}".format(
            example, target.replace("/", "_").replace(":", "_"), mode, abi
        )
        manifests.mkdir(parents=True, exist_ok=True)
        execution_log = manifests / (slug + ".execution.json")
        print("==> {} {} {} ({})".format(example, target, mode, abi))
        if build:
            run(
                [bazel, "build",
                 "--execution_log_json_file={}".format(execution_log),
                 *flags, target],
                module,
            )
        apk = unsigned_apk(bazel, module, target, flags)
        if not apk.is_file():
            sys.exit(
                "FAIL: {} {} {} {} built, but configured output {} is absent."
                .format(example, target, mode, abi, apk)
            )
        captured_apk = manifests / (slug + ".apk")
        shutil.copyfile(apk, captured_apk)
        actual_abis = apk_abis(captured_apk)
        wanted_abis = expected_abis(abi)
        listing = entry_listing(captured_apk)
        apk_bytes = captured_apk.read_bytes()
        apk_digest = hashlib.sha256(apk_bytes).hexdigest()
        entries_digest = hashlib.sha256(listing.encode()).hexdigest()
        (manifests / (slug + ".entries.txt")).write_text(listing)
        (manifests / (slug + ".meta.txt")).write_text(
            "example={}\ntarget={}\nmode={}\nabi={}\n"
            "android_platforms={}\nabis={}\napk_sha256={}\nentries_sha256={}\n".format(
                example, target, mode, abi,
                next((flag.split("=", 1)[1] for flag in flags
                      if flag.startswith("--android_platforms=")), "default"),
                ",".join(sorted(actual_abis)), apk_digest, entries_digest,
            )
        )
        if actual_abis != wanted_abis:
            sys.exit(
                "FAIL: {} {} {} APK ABI inventory is {}; expected {}."
                .format(example, target, abi, sorted(actual_abis), sorted(wanted_abis))
            )
        if example == "demo_app" and mode == "release":
            expression = (
                'mnemonic("DartAotKernel|FlutterAssetBundle|DartAotElf|'
                'FlutterEngineStrip|AndroidNativeLibStrip|CcCmakeMakeRule", '
                'deps({}))'.format(target)
            )
            graph = run(
                [bazel, "aquery", *flags, expression, "--output=jsonproto"],
                module,
            )
            graph_path = manifests / (slug + ".aquery.json")
            graph_path.write_text(graph)
            if not json.loads(graph).get("actions"):
                sys.exit(
                    "FAIL: {} {} aquery returned no shared Flutter/native actions."
                    .format(example, abi)
                )
        rows.append(
            "{} {} mode={} abi={} apk={} entries={}".format(
                example, target, mode, abi, apk_digest, entries_digest
            )
        )

    return rows


def row_key(row: str) -> tuple[str, str, str, str]:
    parts = row.split(" ")
    if len(parts) < 5 or not parts[0] or not parts[1]:
        raise ValueError("malformed hash row: {}".format(row))
    fields = dict(part.split("=", 1) for part in parts[2:] if "=" in part)
    return parts[0], parts[1], fields["mode"], fields["abi"]


def assert_row_coverage(
        rows: list[str], expected: list[tuple[str, str, str, str]],
        source: Path) -> None:
    try:
        keys = [row_key(row) for row in rows]
    except (KeyError, ValueError) as error:
        sys.exit("FAIL: {} contains a malformed configured row: {}.".format(
            source, error
        ))
    duplicates = sorted({key for key in keys if keys.count(key) > 1})
    missing = [key for key in expected if key not in keys]
    unknown = sorted(set(keys) - set(expected))
    if duplicates or missing or unknown:
        sys.exit(
            "FAIL: {} configured row coverage is invalid; duplicates={}, "
            "missing={}, unknown={}.".format(source, duplicates, missing, unknown)
        )


def recorded_rows(golden: Path) -> list[str]:
    return [
        line
        for line in golden.read_text().splitlines()
        if line and not line.startswith("#")
    ]


def configured_row_keys() -> list[tuple[str, str, str, str]]:
    keys = [(example, target, mode, abi)
            for example, _, target, mode, abi, _ in EXAMPLES]
    if len(keys) != 11:
        sys.exit("FAIL: EXAMPLES must contain all 11 configured APK rows.")
    if len(keys) != len(set(keys)):
        sys.exit("FAIL: EXAMPLES contains duplicate configured APK rows.")
    invalid = [
        (example, mode, abi)
        for example, _, _, mode, abi, _ in EXAMPLES
        if mode not in ("release", "debug")
        or abi not in ("fat", *ANDROID_ABIS)
    ]
    if invalid:
        sys.exit("FAIL: EXAMPLES contains invalid mode/ABI keys: {}.".format(invalid))
    for example, _, _, mode, abi, flags in EXAMPLES:
        expected_build = ("-c", "opt") if mode == "release" else ("-c", "fastbuild")
        if flags[:2] != expected_build:
            sys.exit("FAIL: {} {} row has the wrong Bazel compilation mode.".format(
                example, mode
            ))
        expected_flutter_mode = (
            "--@rules_flutter_core//flutter:mode=" + mode
        )
        flutter_modes = [
            flag for flag in flags
            if flag.startswith("--@rules_flutter_core//flutter:mode=")
        ]
        if flutter_modes != [expected_flutter_mode]:
            sys.exit("FAIL: {} {} row has Flutter mode flags {}.".format(
                example, mode, flutter_modes
            ))
        selected_abis = ANDROID_ABIS if abi == "fat" else (abi,)
        expected_platforms = "--android_platforms=" + ",".join(
            "@rules_android//:" + selected_abi for selected_abi in selected_abis
        )
        platform_flags = [
            flag for flag in flags if flag.startswith("--android_platforms=")
        ]
        if platform_flags != [expected_platforms]:
            sys.exit("FAIL: {} {} row selects {} but has platform flags {}.".format(
                example, abi, expected_platforms, platform_flags
            ))
    return keys


def validate_only(only: str) -> None:
    names = list(dict.fromkeys(example for example, _, _, _, _, _ in EXAMPLES))
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
    assert_row_coverage(existing, order, golden)
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
    and an APK target declared by the Flutter app helper from being omitted
    from `EXAMPLES`.

    A self-check rather than a py_test: this repository does not depend on
    rules_python and Bazel 9 has no native py_binary (flutter/private/rules.bzl).
    """
    first = EXAMPLES[0][0]
    first_targets = tuple(row[2] for row in EXAMPLES if row[0] == first)
    second = next(example for example, *_ in EXAMPLES if example != first)
    second_key = next(key for key in configured_row_keys() if key[0] == second)
    golden = Path("example_hashes.txt")

    existing = [
        "{} {} mode={} abi={} apk=old entries=old".format(*key)
        for key in configured_row_keys()
    ]
    fresh = [
        "{} {} mode={} abi={} apk=new entries=new".format(*key)
        for key in configured_row_keys() if key[0] == first
    ]
    # A complete baseline admits a subset update, preserves every unrelated
    # row, and returns to EXAMPLES' canonical order.
    validate_subset_baseline(existing, first, golden)
    merged = merge(existing, fresh)
    assert len(merged) == len(existing), merged
    assert all(
        row.startswith("{} ".format(first)) and "apk=new " in row
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
    incomplete = [row for row in existing if row_key(row) != second_key]
    try:
        validate_subset_baseline(incomplete, first, golden)
    except SystemExit as exit_:
        assert second in str(exit_) and second_key[1] in str(exit_), exit_
    else:
        raise AssertionError("an incomplete unrelated baseline was silently accepted")

    # A row the script cannot rebuild must stop a subset record rather than
    # vanish when merging.
    try:
        validate_subset_baseline(
            existing + ["ghost //a:b mode=release abi=fat apk=x entries=x"],
            first, golden,
        )
    except SystemExit as exit_:
        assert "ghost" in str(exit_), exit_
    else:
        raise AssertionError("an unknown baseline row was silently accepted")

    # The configured set must be exact: an omitted declared ABI shape and a
    # stale configured target both name the example and offending label.
    declared = {first_targets[0], "//android/app:extra"}
    try:
        assert_target_inventory(first, tuple(set(first_targets)), declared)
    except SystemExit as exit_:
        assert first in str(exit_) and "//android/app:extra" in str(exit_), exit_
    else:
        raise AssertionError("an unlisted declared target passed")
    try:
        assert_target_inventory(
            first, tuple(set(first_targets) | {"//ghost:apk"}), set(first_targets)
        )
    except SystemExit as exit_:
        assert first in str(exit_) and "//ghost:apk" in str(exit_), exit_
    else:
        raise AssertionError("a stale configured target passed")

    keys = configured_row_keys()
    assert len(keys) == 11 and len(set(keys)) == 11, keys
    assert_row_coverage(existing, keys, golden)
    try:
        assert_row_coverage(existing[:-1], keys, golden)
    except SystemExit as exit_:
        assert "missing=" in str(exit_), exit_
    else:
        raise AssertionError("a missing mode/ABI row passed")
    miskeyed = existing.copy()
    miskeyed[0] = miskeyed[0].replace("abi=fat", "abi=unknown")
    try:
        assert_row_coverage(miskeyed, keys, golden)
    except SystemExit as exit_:
        assert "unknown=" in str(exit_) and "missing=" in str(exit_), exit_
    else:
        raise AssertionError("a mis-keyed mode/ABI row passed")
    try:
        assert_row_coverage(existing + [existing[0]], keys, golden)
    except SystemExit as exit_:
        assert "duplicates=" in str(exit_), exit_
    else:
        raise AssertionError("a duplicate mode/ABI row passed")

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
        assert_row_coverage(
            expected,
            [key for key in configured_row_keys() if key[0] == args.only],
            args.golden,
        )
    else:
        assert_row_coverage(expected, configured_row_keys(), args.golden)

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
    revision = ndk_revision()
    if revision != RECORDED_NDK:
        print(
            "\nnote: ANDROID_NDK_HOME is NDK {}, but the rows are recorded with "
            "NDK {}; a difference confined to NDK-compiled libraries "
            "(librive_text.so, libdartjni.so) is expected. Re-run with the "
            "recorded NDK before treating it as a regression.".format(
                revision or "unknown", RECORDED_NDK
            ),
            file=sys.stderr,
        )
    return 1


if __name__ == "__main__":
    sys.exit(main())
