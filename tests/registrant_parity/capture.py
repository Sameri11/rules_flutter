#!/usr/bin/env python3
"""Capture Android GeneratedPluginRegistrant goldens from the real Flutter SDK.

For every case directory next to this file, copies the fixture into a scratch
tree, scaffolds the Android host project with `flutter create`, and captures:

  expected/debug/GeneratedPluginRegistrant.java    dev-only plugins included
  expected/release/GeneratedPluginRegistrant.java  dev-only plugins removed
  app/pubspec.lock                                 from `flutter pub get --offline`

Usage:
  python3 capture.py                  regenerate goldens and locks in the repo
  python3 capture.py --check          capture into a temp dir; exit 1 with a diff on mismatch
  python3 capture.py --case NAME ...  limit to the named case(s) (repeatable)

The Flutter CLI is $FLUTTER if set, otherwise `flutter` from PATH.
Only the contract files are written into the repo; all Flutter work happens in
a temp directory that is removed on success (kept and reported on failure).
"""

from __future__ import annotations

import argparse
import difflib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
REGISTRANT_NAME = "GeneratedPluginRegistrant.java"
REGISTRANT_REL = Path("android/app/src/main/java/io/flutter/plugins") / REGISTRANT_NAME
LOCK_REL = Path("app/pubspec.lock")
# mode -> `flutter build apk` flag. Both run regeneratePlatformSpecificTooling
# with the matching releaseMode; `flutter pub get` does the same for debug but
# only when the app depends on the flutter SDK, which these fixtures avoid.
MODE_FLAGS = {"debug": "--debug", "release": "--release"}


class CaptureError(RuntimeError):
    pass


def discover_cases() -> list[str]:
    return sorted(p.parent.parent.name for p in HERE.glob("*/app/pubspec.yaml"))


def resolve_flutter() -> str:
    flutter = os.environ.get("FLUTTER") or shutil.which("flutter")
    if not flutter:
        raise SystemExit("error: set FLUTTER or put `flutter` on PATH")
    return flutter


def run(cmd: list[str], cwd: Path, env: dict[str, str]) -> str:
    proc = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True)
    if proc.returncode != 0:
        tail = (proc.stdout + proc.stderr)[-4000:]
        raise CaptureError(f"`{' '.join(cmd)}` failed in {cwd} (rc={proc.returncode}):\n{tail}")
    return proc.stdout


def scaffold_android(flutter: str, case: str, scratch: Path, env: dict[str, str]) -> Path:
    """Let Flutter generate the Android host project; only its android/ and lib/ are reused."""
    scaffold = scratch / "scaffold" / case
    scaffold.parent.mkdir(parents=True, exist_ok=True)
    run(
        [
            flutter,
            "create",
            "--platforms=android",
            "--project-name",
            f"registrant_parity_{case}",
            "--org",
            "dev.parity",
            "--no-pub",
            str(scaffold),
        ],
        cwd=scratch,
        env=env,
    )
    return scaffold


def prepare_tree(case_dir: Path, scaffold: Path, tree: Path) -> Path:
    """Copy the fixture into `tree` and graft the Flutter-generated Android host onto its app."""
    tree.mkdir(parents=True)
    app = tree / "app"
    shutil.copytree(case_dir / "app", app)
    if (case_dir / "packages").is_dir():
        shutil.copytree(case_dir / "packages", tree / "packages")
    shutil.copytree(scaffold / "android", app / "android")
    shutil.copytree(scaffold / "lib", app / "lib")
    return app


def capture_mode(
    flutter: str, env: dict[str, str], case: str, mode: str, scratch: Path, scaffold: Path
) -> tuple[str, str]:
    """Return (registrant text, pubspec.lock text) for one mode of one case."""
    app = prepare_tree(HERE / case, scaffold, scratch / case / mode)
    run([flutter, "pub", "get", "--offline"], cwd=app, env=env)
    registrant = app / REGISTRANT_REL
    registrant.unlink(missing_ok=True)
    run([flutter, "build", "apk", "--config-only", MODE_FLAGS[mode]], cwd=app, env=env)
    if not registrant.is_file():
        raise CaptureError(f"[{case}/{mode}] flutter did not write {REGISTRANT_REL}")
    return registrant.read_bytes().decode("utf-8"), (app / "pubspec.lock").read_bytes().decode("utf-8")


def capture_case(flutter: str, env: dict[str, str], case: str, scratch: Path) -> dict[Path, str]:
    """Return {repo-relative path inside the case dir: captured text}."""
    scaffold = scaffold_android(flutter, case, scratch, env)
    outputs: dict[Path, str] = {}
    locks: dict[str, str] = {}
    for mode in MODE_FLAGS:
        registrant, lock = capture_mode(flutter, env, case, mode, scratch, scaffold)
        outputs[Path("expected") / mode / REGISTRANT_NAME] = registrant
        locks[mode] = lock
    if locks["debug"] != locks["release"]:
        raise CaptureError(f"[{case}] pubspec.lock differs between debug and release captures")
    outputs[LOCK_REL] = locks["debug"]
    return outputs


def read_committed(path: Path) -> str:
    return path.read_bytes().decode("utf-8") if path.is_file() else ""


def compare_case(case: str, outputs: dict[Path, str]) -> bool:
    """Print a unified diff for each mismatching file; return True if the case matches."""
    matches = True
    for rel, captured in outputs.items():
        target = HERE / case / rel
        committed = read_committed(target)
        if committed == captured:
            continue
        matches = False
        label = "missing" if not target.is_file() else "differs"
        print(f"--- [{case}] {rel}: {label}", file=sys.stderr)
        sys.stdout.writelines(
            difflib.unified_diff(
                committed.splitlines(keepends=True),
                captured.splitlines(keepends=True),
                fromfile=f"{case}/{rel} (committed)",
                tofile=f"{case}/{rel} (captured)",
            )
        )
    return matches


def write_case(case: str, outputs: dict[Path, str]) -> None:
    for rel, text in outputs.items():
        target = HERE / case / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(text.encode("utf-8"))
        print(f"wrote {case}/{rel}", file=sys.stderr)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument(
        "--check",
        action="store_true",
        help="capture into a temp dir and compare with committed goldens; exit 1 on any difference",
    )
    parser.add_argument(
        "--case",
        action="append",
        dest="cases",
        metavar="NAME",
        help="limit to this case (repeatable); default: all cases",
    )
    args = parser.parse_args(argv)

    known = discover_cases()
    cases = args.cases or known
    unknown = sorted(set(cases) - set(known))
    if unknown:
        parser.error(f"unknown case(s): {', '.join(unknown)} (known: {', '.join(known)})")

    flutter = resolve_flutter()
    env = os.environ.copy()
    info = json.loads(run([flutter, "--version", "--machine"], cwd=HERE, env=env))
    print(f"flutter: {flutter} ({info['frameworkVersion']} {info['channel']}, engine {info['engineRevision']})", file=sys.stderr)

    scratch = Path(tempfile.mkdtemp(prefix="registrant_parity_"))
    all_match = True
    try:
        for case in cases:
            started = time.monotonic()
            outputs = capture_case(flutter, env, case, scratch)
            print(f"[{case}] captured in {time.monotonic() - started:.1f}s", file=sys.stderr)
            if args.check:
                all_match &= compare_case(case, outputs)
            else:
                write_case(case, outputs)
    except CaptureError as err:
        print(f"error: {err}\nscratch kept for inspection: {scratch}", file=sys.stderr)
        return 2

    shutil.rmtree(scratch)
    if args.check:
        if all_match:
            print(f"ok: {len(cases)} case(s) match committed goldens", file=sys.stderr)
            return 0
        print("mismatch: committed goldens are stale; run capture.py to refresh", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
