#!/usr/bin/env python3
"""Re-baselines the conformance oracles from `flutter test`.

For each fixture, runs `flutter test --reporter json` in this package (the
pubspec directory) and writes `<fixture>.expected.json`: per run, the exit code
and each case's outcome, in run order. Bazel does not run this; `bazel test`
checks the host_test launcher against these files (check.py).

    python3 tests/flutter_test_conformance/rebaseline.py          # rewrite
    python3 tests/flutter_test_conformance/rebaseline.py --check  # exit 1 on drift

The Flutter CLI is $FLUTTER if set, otherwise `flutter` from PATH. Its version
must be the one the root MODULE.bazel declares (flutter_dev.sdk), so the
baselines always come from the SDK the rules build against.

Naming and outcomes are the CLI's, mapped to the driver's vocabulary:
  * `loading <path>` is the CLI's suite-load case; a failing load is `load`.
    A passing load is hidden by the CLI and is not a case.
  * result `success` -> pass, `skipped` -> skip, `failure` -> fail,
    `error` -> error. Hidden rows (successful hooks) are not cases.
Hooks are named `<group> (setUpAll)` / `<group> (tearDownAll)` by both.
"""

import argparse
import difflib
import json
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))


class Run:
    """One invocation of a fixture: the env the driver sees, and the CLI args
    that select the same tests."""

    def __init__(self, name, env=None, cli=None):
        self.name = name
        self.env = env or {}
        self.cli = cli or []


def _shard(total, index):
    return {"TEST_TOTAL_SHARDS": str(total), "TEST_SHARD_INDEX": str(index)}, [
        "--total-shards",
        str(total),
        "--shard-index",
        str(index),
    ]


def _c13_runs():
    runs = [Run("default")]
    runs.append(
        Run("name_beta", {"TESTBRIDGE_TEST_ONLY": "filter beta"}, ["--name", "filter beta"])
    )
    for total in (2, 3):
        for index in range(total):
            env, cli = _shard(total, index)
            runs.append(Run("shard_{}_of_{}".format(index, total), env, cli))
    env, cli = _shard(2, 0)
    runs.append(
        Run(
            "name_alpha_gamma_shard_0_of_2",
            dict(env, TESTBRIDGE_TEST_ONLY="filter (alpha|gamma)"),
            ["--name", "filter (alpha|gamma)"] + cli,
        )
    )
    env, cli = _shard(2, 1)
    runs.append(
        Run(
            "name_alpha_gamma_shard_1_of_2",
            dict(env, TESTBRIDGE_TEST_ONLY="filter (alpha|gamma)"),
            ["--name", "filter (alpha|gamma)"] + cli,
        )
    )
    return runs


FIXTURES = {
    "c1_lifecycle": [Run("default")],
    "c3_timeout": [Run("default")],
    "c4_names": [Run("default")],
    "c5_expect_async": [Run("default")],
    "c6_async_errors": [Run("default")],
    "c7_teardown": [Run("default")],
    "c8_config": [Run("default")],
    "c9_platform_tags": [Run("default")],
    "c10_reporting": [Run("default")],
    "c11_widgets": [Run("default")],
    "c12_retry": [Run("default")],
    "c13_filter": _c13_runs(),
    "c14_async_main": [Run("default")],
    "c2_skip": [Run("default")],
}


def declared_sdk_version():
    with open(os.path.join(ROOT, "MODULE.bazel")) as f:
        match = re.search(r'flutter_dev\.sdk\(\s*version\s*=\s*"([^"]+)"', f.read())
    if not match:
        raise SystemExit("error: MODULE.bazel does not declare flutter_dev.sdk(version)")
    return match.group(1)


def flutter_path():
    flutter = os.environ.get("FLUTTER") or shutil.which("flutter")
    if not flutter:
        raise SystemExit("error: set FLUTTER or put `flutter` on PATH")
    return flutter


def sdk_version(flutter):
    out = subprocess.run(
        [flutter, "--version", "--machine"], capture_output=True, text=True, check=True
    ).stdout
    return json.loads(out)["frameworkVersion"]


def outcome_of(event_result, skipped):
    if skipped:
        return "skip"
    return {"success": "pass", "failure": "fail", "error": "error"}[event_result]


def cli_cases(flutter, fixture, run):
    """Runs the CLI for one run; returns (exit_code, cases) with cases in run order."""
    cmd = [flutter, "test", "--reporter", "json"] + run.cli + [
        os.path.join("test", fixture + "_test.dart")
    ]
    proc = subprocess.run(cmd, cwd=HERE, capture_output=True, text=True)
    names = {}
    cases = {}
    for line in proc.stdout.splitlines():
        if not line.strip():
            continue
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if event.get("type") == "testStart":
            names[event["test"]["id"]] = event["test"]["name"]
        elif event.get("type") == "testDone":
            name = names.get(event["testID"], "")
            if event.get("hidden"):
                continue
            if name.startswith("loading "):
                if event["result"] != "success":
                    cases["load"] = "error"
                continue
            cases[name] = outcome_of(event["result"], event.get("skipped", False))
    return proc.returncode, cases


def build(flutter, version, fixture, runs):
    out = {"fixture": fixture, "flutter": version, "runs": []}
    for run in runs:
        code, cases = cli_cases(flutter, fixture, run)
        out["runs"].append(
            {"name": run.name, "env": run.env, "exit_code": code, "cases": cases}
        )
    return json.dumps(out, indent=2) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    parser.add_argument("--check", action="store_true", help="fail on drift instead of rewriting")
    parser.add_argument("--fixture", action="append", help="only this fixture (repeatable)")
    args = parser.parse_args()

    flutter = flutter_path()
    version = sdk_version(flutter)
    declared = declared_sdk_version()
    if version != declared:
        raise SystemExit(
            "error: Flutter {} at {}, but MODULE.bazel declares {}".format(
                version, flutter, declared
            )
        )

    failed = False
    for fixture, runs in FIXTURES.items():
        if args.fixture and fixture not in args.fixture:
            continue
        text = build(flutter, version, fixture, runs)
        path = os.path.join(HERE, fixture + ".expected.json")
        if args.check:
            existing = open(path).read() if os.path.exists(path) else ""
            if existing != text:
                failed = True
                sys.stdout.writelines(
                    difflib.unified_diff(
                        existing.splitlines(True),
                        text.splitlines(True),
                        fromfile=path,
                        tofile="regenerated",
                    )
                )
            else:
                print("ok {}".format(fixture))
        else:
            with open(path, "w") as f:
                f.write(text)
            print("wrote {}".format(os.path.relpath(path, ROOT)))
    if failed:
        print("error: expected files drifted from `flutter test`; rerun without --check", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
