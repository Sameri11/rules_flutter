#!/usr/bin/env python3
"""Verifies native jar producers re-execute to identical bytes.

APK hashes do not observe jar timestamps after SingleJar normalization.
"""

from __future__ import annotations

import argparse
import hashlib
import re
import subprocess
import sys
from pathlib import Path

# Share the hash gate's example inventory.
sys.path.insert(0, str(Path(__file__).resolve().parent))

from example_hashes import EXAMPLES, REPO_ROOT  # noqa: E402

# Native-jar action mnemonics; their labels are generated.
MNEMONICS = (
    "JniLibJar",
    "AndroidNativeLibJar",
    "StripNativeLibs",
    "FlutterNativeLibs",
)

_OUTPUTS = re.compile(r"^  Outputs: \[(.*)\]$", re.M)


def run(argv: list[str], cwd: Path) -> str:
    proc = subprocess.run(argv, cwd=cwd, text=True, stdout=subprocess.PIPE)
    if proc.returncode != 0:
        sys.exit("FAIL: {} (in {}) exited {}".format(" ".join(argv), cwd, proc.returncode))
    return proc.stdout


def producer_outputs(bazel: str, module: Path, targets: tuple, execroot: Path) -> list:
    query = 'mnemonic("{}", deps({}))'.format("|".join(MNEMONICS), " + ".join(targets))
    text = run([bazel, "aquery", "--output=text", query], module)
    paths = []
    for match in _OUTPUTS.finditer(text):
        paths += [execroot / p.strip() for p in match.group(1).split(",") if p.strip()]
    return sorted(set(paths))


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def check(example: str, bazel: str) -> int:
    module, targets = next(
        (REPO_ROOT / directory, apks)
        for name, directory, apks in EXAMPLES
        if name == example
    )

    execroot = Path(run([bazel, "info", "execution_root"], module).strip())
    run([bazel, "build"] + list(targets), module)

    outputs = producer_outputs(bazel, module, targets, execroot)
    if not outputs:
        sys.exit(
            "FAIL: {} declares no native jar producer action. Either the "
            "mnemonics moved or the example stopped packaging native "
            "libraries; both make this gate silently vacuous.".format(example)
        )

    before = {path: digest(path) for path in outputs}
    for path in outputs:
        path.unlink()

    # Do not fetch deleted outputs from the remote cache.
    run([bazel, "build", "--remote_cache="] + list(targets), module)

    moved = []
    for path, was in before.items():
        if not path.exists():
            moved.append((path, was, "missing"))
        else:
            now = digest(path)
            if now != was:
                moved.append((path, was, now))

    print("{}: {} producer outputs re-executed".format(example, len(before)))
    if moved:
        for path, was, now in moved:
            print("  {}\n    before {}\n    after  {}".format(
                path.relative_to(execroot), was, now))
        print(
            "FAIL: a native jar producer is not reproducible. Its consumers' "
            "input digests move on every re-execution, so the desugar/dex/"
            "package actions cannot hit the cache. See "
            "tools/flutter/archive.bzl."
        )
        return 1

    print("OK: {} jars byte-identical across forced re-execution".format(len(before)))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--only",
        required=True,
        choices=[name for name, _, _ in EXAMPLES],
        help="the configured example to check",
    )
    parser.add_argument("--bazel", default="bazel")
    args = parser.parse_args()
    return check(args.only, args.bazel)


if __name__ == "__main__":
    raise SystemExit(main())
