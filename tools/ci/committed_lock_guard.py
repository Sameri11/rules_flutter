#!/usr/bin/env python3
"""Guard that committed module locks record no local NDK input.

Bazel writes module-extension inputs into `MODULE.bazel.lock`. While the NDK
module extension read `ANDROID_NDK_HOME`, every lock recorded either that
variable's machine-local value or the toolchain-less stub that stood in for a
missing NDK. Both are gone; this guard keeps them gone.

`--selftest` exercises the detection logic in-process, which is what the
hermetic Bazel target runs. The real scan reads the committed locks, which live
in five separate Bazel modules and therefore cannot be genrule inputs.
"""

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

# Every committed lock: the ruleset root, the four examples, and the public
# consumer fixture. Listed rather than globbed so a new module's lock is an
# explicit decision instead of a silent omission.
COMMITTED_LOCKS = (
    "MODULE.bazel.lock",
    "examples/demo_app/MODULE.bazel.lock",
    "examples/local_plugin/MODULE.bazel.lock",
    "examples/no_plugins/MODULE.bazel.lock",
    "examples/pub_plugins/MODULE.bazel.lock",
    "tests/consumer/MODULE.bazel.lock",
)

# The extension input and the stub repository that recorded it.
FORBIDDEN_SUBSTRINGS = (
    "ENV:ANDROID_NDK_HOME",
    "_stub_ndk_repository",
)

# An installed NDK is always addressed through one of these path segments:
# `$ANDROID_HOME/ndk/<version>` for the SDK manager layout, `ndk-bundle` for
# the legacy one. Matching path segments rather than home prefixes keeps the
# check meaningful on any runner.
NDK_PATH_SEGMENTS = (
    "/ndk/",
    "/ndk-bundle",
)


def _recorded_strings(data):
    """Yield every string a lock records as a module-extension input or spec."""
    if isinstance(data, dict):
        for key, value in data.items():
            yield str(key)
            for item in _recorded_strings(value):
                yield item
    elif isinstance(data, list):
        for value in data:
            for item in _recorded_strings(value):
                yield item
    elif isinstance(data, str):
        yield data


def check_lock(name, content):
    """Return every violation the given lock content contains."""
    violations = []
    for substring in FORBIDDEN_SUBSTRINGS:
        if substring in content:
            violations.append("{}: records forbidden input {}".format(name, substring))

    try:
        data = json.loads(content)
    except json.JSONDecodeError as error:
        return violations + ["{}: is not valid JSON: {}".format(name, error)]

    for value in _recorded_strings(data):
        for segment in NDK_PATH_SEGMENTS:
            if segment in value:
                violations.append(
                    "{}: records a machine-local NDK path: {}".format(name, value)
                )
                break
    return violations


def _selftest():
    clean = json.dumps(
        {
            "moduleExtensions": {
                "//tools/flutter:ndk.bzl%android_ndk": {
                    "general": {
                        "recordedInputs": [
                            "REPO_MAPPING:rules_flutter+,rules_android_ndk rules_android_ndk+",
                        ],
                        "generatedRepoSpecs": {
                            "androidndk": {
                                "repoRuleId": "@@rules_android_ndk+//:rules.bzl%android_ndk_repository",
                                "attributes": {},
                            },
                        },
                    },
                },
            },
        },
    )
    if check_lock("clean", clean):
        raise SystemExit("FAIL: selftest rejected a portable lock")

    captured = clean.replace(
        '"REPO_MAPPING:rules_flutter+,rules_android_ndk rules_android_ndk+"',
        '"ENV:ANDROID_NDK_HOME /Users/someone/Library/Android/sdk/ndk/28.2.13676358"',
    )
    findings = check_lock("captured", captured)
    if len(findings) != 2:
        raise SystemExit(
            "FAIL: selftest expected the environment input and the NDK path, got {}".format(
                findings,
            ),
        )

    stubbed = clean.replace("android_ndk_repository", "_stub_ndk_repository")
    if not check_lock("stubbed", stubbed):
        raise SystemExit("FAIL: selftest accepted a stub NDK repository")

    if not check_lock("malformed", "{"):
        raise SystemExit("FAIL: selftest accepted an unparseable lock")

    print("OK: committed lock guard detects captured inputs, NDK paths and stubs")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=str(ROOT), help="repository root to scan")
    parser.add_argument(
        "--selftest",
        action="store_true",
        help="check the detection logic without reading committed locks",
    )
    args = parser.parse_args(argv)

    if args.selftest:
        _selftest()
        return 0

    root = Path(args.root).resolve()
    violations = []
    for name in COMMITTED_LOCKS:
        lock = root / name
        if not lock.is_file():
            violations.append("{}: committed lock is missing".format(name))
            continue
        violations.extend(check_lock(name, lock.read_text()))

    if violations:
        for violation in violations:
            print("FAIL: {}".format(violation))
        return 1

    print("OK: {} committed locks record no local NDK input".format(len(COMMITTED_LOCKS)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
