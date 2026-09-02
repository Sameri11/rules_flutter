#!/usr/bin/env python3
"""Exercise Android toolchain ownership."""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_WORKSPACE = ROOT / "tests" / "consumer"
DEFAULT_CORE_WORKSPACE = ROOT / "tests" / "core_consumer"
SCENARIOS = (
    "analysis",
    "inventory",
    "compile-probe",
    "core-isolation",
    "missing-ndk",
    "lock-portability",
)
EM_AARCH64 = 183

CORE_FORBIDDEN_MARKERS = (
    "androidndk",
    "rules_android_ndk",
    "android_gmaven",
    "android_tools",
)

# Measured transitive module registrations that remain.
CORE_DEPENDENCY_REGISTRATIONS = (
    "rules_android+",
    "rules_android++android_sdk_repository_extension+androidsdk",
    "rules_foreign_cc+",
    "rules_foreign_cc++tools+cmake_3.31.8_toolchains",
    "rules_foreign_cc++tools+ninja_1.13.0_toolchains",
    "rules_foreign_cc++tools+rules_foreign_cc_framework_toolchains",
    "rules_kotlin+",
    "rules_kotlin++rules_kotlin_extensions+com_github_jetbrains_kotlin",
)

ANDROID_REPO_MARKERS = CORE_FORBIDDEN_MARKERS + (
    "androidsdk",
    "rules_android",
    "rules_foreign_cc",
    "rules_jvm_external",
    "rules_kotlin",
)

# Pre-cutover baseline: e485184^ with Android variables unset.
PRE_CUTOVER_ANDROID_REPOSITORIES = (
    "rules_android++android_sdk_repository_extension+androidsdk.marker",
    "rules_flutter++android_ndk+androidndk.marker",
    "rules_foreign_cc++tools+cmake_3.31.8_toolchains.marker",
    "rules_foreign_cc++tools+ninja_1.13.0_toolchains.marker",
    "rules_foreign_cc++tools+rules_foreign_cc_framework_toolchains.marker",
    "rules_android+",
    "rules_android++android_sdk_repository_extension+androidsdk",
    "rules_android_ndk+",
    "rules_flutter++android_ndk+androidndk",
    "rules_foreign_cc+",
    "rules_foreign_cc++tools+cmake_3.31.8_toolchains",
    "rules_foreign_cc++tools+ninja_1.13.0_toolchains",
    "rules_foreign_cc++tools+rules_foreign_cc_framework_toolchains",
    "rules_kotlin+",
    "rules_kotlin++rules_kotlin_extensions+com_github_jetbrains_kotlin",
)


class ProbeError(RuntimeError):
    """Probe contract failure."""


def _workspace_path(value):
    path = Path(value)
    if not path.is_absolute():
        path = ROOT / path
    return path.resolve()


def _bazel_command(workspace, output_base, args):
    command = ["bazel"]
    if output_base is not None:
        command.append("--output_base={}".format(output_base))
    command.extend(args)
    return command


def _repo_environment_args(environment):
    args = []
    for name in ("ANDROID_HOME", "ANDROID_NDK_HOME"):
        value = environment.get(name, "").strip()
        if value:
            args.append("--repo_env={name}={value}".format(name=name, value=value))
    return args


def _run_bazel(workspace, output_base, args, environment=None):
    bazel_args = list(args)
    process_environment = (
        os.environ.copy() if environment is None else environment.copy()
    )
    command = _bazel_command(
        workspace,
        output_base,
        [bazel_args[0]]
        + _repo_environment_args(process_environment)
        + bazel_args[1:],
    )
    result = subprocess.run(
        command,
        cwd=str(workspace),
        env=process_environment,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    if result.returncode:
        raise ProbeError(
            "Bazel command failed ({}):\n{}".format(" ".join(command), result.stdout)
        )
    return result.stdout


def _labels(output, repository):
    prefix = repository + "//"
    return sorted({line.strip() for line in output.splitlines() if line.strip().startswith(prefix)})


def run_analysis(workspace, output_base):
    _run_bazel(workspace, output_base, ["build", "--nobuild", "//..."])
    return {
        "scenario": "analysis",
        "target": "//...",
        "result": "analyzed",
    }


def _external_repositories(output_base):
    external = output_base / "external"
    if not external.is_dir():
        raise ProbeError("Bazel created no external repository directory at {}".format(external))
    return sorted(path.name for path in external.iterdir())


def _fresh_output_base(output_base):
    output_base.mkdir(parents=True, exist_ok=True)
    if any(output_base.iterdir()):
        raise ProbeError("core-isolation requires a fresh output base: {}".format(output_base))


def run_core_isolation(workspace, output_base):
    environment = os.environ.copy()
    environment.pop("ANDROID_HOME", None)
    environment.pop("ANDROID_NDK_HOME", None)

    temporary = None
    if output_base is None:
        temporary = tempfile.TemporaryDirectory(prefix="android-toolchain-core-")
        output_base = Path(temporary.name)
    else:
        output_base = Path(output_base)

    try:
        _fresh_output_base(output_base)
        _run_bazel(
            workspace,
            output_base,
            ["build", "--lockfile_mode=off", "//:core_action"],
            environment=environment,
        )
        repositories = _external_repositories(output_base)
        materialized = [
            name.lstrip("@").removesuffix(".marker")
            for name in repositories
            if any(marker in name for marker in ANDROID_REPO_MARKERS)
        ]
        forbidden = sorted(
            {
                name
                for name in materialized
                if any(marker in name for marker in CORE_FORBIDDEN_MARKERS)
            },
        )
        if forbidden:
            raise ProbeError(
                "the core Consumer materialised ruleset-registered Android "
                "repositories: {}".format(forbidden),
            )

        unexpected = sorted(set(materialized) - set(CORE_DEPENDENCY_REGISTRATIONS))
        if unexpected:
            raise ProbeError(
                "the core Consumer materialised unrecorded Android-adjacent "
                "repositories: {}".format(unexpected),
            )

        return {
            "scenario": "core-isolation",
            "target": "//:core_action",
            "environment": {
                "ANDROID_HOME": "unset",
                "ANDROID_NDK_HOME": "unset",
            },
            "pre_cutover": {
                "source": (
                    "prototype e485184^, fresh external core Consumer, host cc_binary, "
                    "both Android env vars unset"
                ),
                "android_repository_count": len(PRE_CUTOVER_ANDROID_REPOSITORIES),
                "android_repositories": list(PRE_CUTOVER_ANDROID_REPOSITORIES),
            },
            "post_cutover": {
                "materialized_repository_count": len(repositories),
                "ruleset_registered_android_repositories": forbidden,
                "dependency_registered_repositories": sorted(set(materialized)),
            },
            "result": (
                "no ruleset-registered Android repository; only the recorded "
                "dependency-module toolchain registrations remain"
            ),
        }
    finally:
        if temporary is not None:
            temporary.cleanup()


def run_inventory(workspace, output_base):
    sdk_output = _run_bazel(workspace, output_base, ["query", "@androidsdk//:all"])
    ndk_output = _run_bazel(
        workspace,
        output_base,
        ["query", "kind(toolchain, @androidndk//:all)"],
    )
    sdk_labels = _labels(sdk_output, "@androidsdk")
    ndk_labels = _labels(ndk_output, "@androidndk")

    if not sdk_labels:
        raise ProbeError("configured SDK repository @androidsdk exposed no labels")
    if len(ndk_labels) != 4:
        raise ProbeError(
            "expected exactly four NDK ABI toolchains, got {}: {}".format(
                len(ndk_labels), ndk_labels
            )
        )

    return {
        "scenario": "inventory",
        "sdk_repository": "@androidsdk",
        "sdk_label_count": len(sdk_labels),
        "ndk_repository": "@androidndk",
        "ndk_toolchain_count": len(ndk_labels),
        "ndk_toolchain_labels": ndk_labels,
    }


def _probe_output(workspace):
    output = workspace / "bazel-bin" / "ndk_probe" / "probe"
    if not output.is_file():
        raise ProbeError("Bazel built the probe but no output was found at {}".format(output))
    return output


def _elf_machine(binary):
    data = binary.read_bytes()
    if len(data) < 20 or data[:4] != b"\x7fELF":
        raise ProbeError("{} is not an ELF binary".format(binary))
    elf_class = data[4]
    if elf_class != 2:
        raise ProbeError("{} is not a 64-bit ELF binary".format(binary))
    byteorder = "little" if data[5] == 1 else "big" if data[5] == 2 else None
    if byteorder is None:
        raise ProbeError("{} has an invalid ELF byte order".format(binary))
    machine = int.from_bytes(data[18:20], byteorder=byteorder)
    if machine != EM_AARCH64:
        raise ProbeError("{} is ELF machine {} rather than AArch64".format(binary, machine))


def run_compile_probe(workspace, output_base):
    _run_bazel(
        workspace,
        output_base,
        [
            "build",
            "--platforms=@rules_android//:arm64-v8a",
            "//ndk_probe:probe",
        ],
    )
    binary = _probe_output(workspace)
    _elf_machine(binary)

    file_result = subprocess.run(
        ["file", "--brief", str(binary)],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    if file_result.returncode:
        raise ProbeError("file could not identify {}: {}".format(binary, file_result.stdout))
    description = file_result.stdout.strip()
    if not re.search(r"\bELF\b", description) or not re.search(
        r"aarch64", description, flags=re.IGNORECASE
    ):
        raise ProbeError("expected an AArch64 ELF probe, got: {}".format(description))

    return {
        "scenario": "compile-probe",
        "target": "//ndk_probe:probe",
        "platform": "@rules_android//:arm64-v8a",
        "binary": str(binary),
        "file": description,
        "result": "AArch64 ELF",
    }


def _fetch_diagnostic(output):
    named = [line.strip() for line in output.splitlines() if "ANDROID_NDK_HOME" in line]
    for line in named:
        if "must be set" in line:
            return line
    return named[0]


def run_missing_ndk(workspace, output_base):
    environment = os.environ.copy()
    environment.pop("ANDROID_NDK_HOME", None)

    temporary = None
    if output_base is None:
        temporary = tempfile.TemporaryDirectory(prefix="android-toolchain-missing-ndk-")
        output_base = Path(temporary.name)
    else:
        output_base = Path(output_base)

    try:
        _fresh_output_base(output_base)
        diagnostic = None
        try:
            _run_bazel(
                workspace,
                output_base,
                ["query", "@androidndk//:all"],
                environment=environment,
            )
        except ProbeError as error:
            diagnostic = str(error)

        if diagnostic is None:
            raise ProbeError(
                "@androidndk fetched with ANDROID_NDK_HOME unset; the Consumer "
                "opt-in must fail at the upstream repository rule",
            )
        if "ANDROID_NDK_HOME" not in diagnostic:
            raise ProbeError(
                "upstream NDK fetch failed without naming ANDROID_NDK_HOME or the "
                "path requirement:\n{}".format(diagnostic),
            )

        return {
            "scenario": "missing-ndk",
            "target": "@androidndk//:all",
            "environment": {
                "ANDROID_NDK_HOME": "unset",
            },
            "diagnostic": _fetch_diagnostic(diagnostic),
            "result": "upstream repository fetch failed with an actionable diagnostic",
        }
    finally:
        if temporary is not None:
            temporary.cleanup()


_LOCK_CONSUMER_MODULE = """\
module(
    name = "lock_portability_consumer",
    version = "0.0.1",
)

bazel_dep(name = "rules_flutter", version = "0.1.0")
local_path_override(
    module_name = "rules_flutter",
    path = "{ruleset}",
)

bazel_dep(name = "rules_android", version = "0.7.3")

android_sdk = use_extension(
    "@rules_android//rules/android_sdk_repository:rule.bzl",
    "android_sdk_repository_extension",
)
android_sdk.configure(
    api_level = 36,
    build_tools_version = "36.0.0",
)
use_repo(android_sdk, "androidsdk")
register_toolchains("@androidsdk//:all")

android_ndk = use_extension("@rules_flutter//tools/flutter:ndk.bzl", "android_ndk")
use_repo(android_ndk, "androidndk", "androidndk_cmake")
register_toolchains("@androidndk//:all")
"""


def _lock_consumer(directory):
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "MODULE.bazel").write_text(_LOCK_CONSUMER_MODULE.format(ruleset=ROOT))
    (directory / "BUILD.bazel").write_text("")
    return directory


def _resolved_lock(scratch, name, environment):
    workspace = _lock_consumer(scratch / name)
    output_base = scratch / "{}-output-base".format(name)
    _run_bazel(
        workspace,
        output_base,
        ["mod", "graph", "--lockfile_mode=update"],
        environment=environment,
    )
    lock = workspace / "MODULE.bazel.lock"
    if not lock.is_file():
        raise ProbeError("module resolution wrote no lock at {}".format(lock))
    return lock.read_bytes()


def _first_difference(left, right):
    for offset, (one, other) in enumerate(zip(left, right)):
        if one != other:
            return offset
    return min(len(left), len(right))


def run_lock_portability(workspace, output_base):
    """Compare fresh locks with ANDROID_NDK_HOME unset and set."""
    ndk = os.environ.get("ANDROID_NDK_HOME", "").strip()
    if not ndk:
        raise ProbeError(
            "lock-portability compares set against unset: export ANDROID_NDK_HOME",
        )

    unset_environment = os.environ.copy()
    unset_environment.pop("ANDROID_NDK_HOME", None)

    with tempfile.TemporaryDirectory(prefix="android-toolchain-lock-") as scratch_name:
        scratch = Path(scratch_name)
        unset_lock = _resolved_lock(scratch, "unset", unset_environment)
        set_lock = _resolved_lock(scratch, "set", os.environ.copy())

    if unset_lock != set_lock:
        raise ProbeError(
            "lock bytes changed with ANDROID_NDK_HOME set: unset={} bytes, set={} "
            "bytes, first difference at offset {}".format(
                len(unset_lock),
                len(set_lock),
                _first_difference(unset_lock, set_lock),
            ),
        )

    text = set_lock.decode("utf-8", errors="replace")
    if "ANDROID_NDK_HOME" in text:
        raise ProbeError("the generated lock names the forbidden input ANDROID_NDK_HOME")
    if ndk in text:
        raise ProbeError("the generated lock records the machine-local NDK path {}".format(ndk))

    return {
        "scenario": "lock-portability",
        "resolutions": ["ANDROID_NDK_HOME unset", "ANDROID_NDK_HOME set"],
        "lock_bytes": len(set_lock),
        "lock_sha256": hashlib.sha256(set_lock).hexdigest(),
        "result": "identical lock bytes, no environment input, no machine NDK path",
    }



def _parser():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "scenario",
        nargs="?",
        choices=SCENARIOS,
        help="scenario to run (also accepted as --scenario)",
    )
    parser.add_argument(
        "--scenario",
        dest="scenario_flag",
        choices=SCENARIOS,
        help="scenario to run",
    )
    parser.add_argument(
        "--workspace",
        help=(
            "Consumer module directory "
            "(default: tests/core_consumer for core-isolation; tests/consumer otherwise)"
        ),
    )
    parser.add_argument(
        "--output-base",
        help="optional isolated Bazel output base shared by this scenario",
    )
    return parser


def main(argv=None):
    args = _parser().parse_args(argv)
    if args.scenario and args.scenario_flag and args.scenario != args.scenario_flag:
        raise ProbeError("positional scenario and --scenario disagree")
    scenario = args.scenario or args.scenario_flag
    if scenario is None:
        raise ProbeError("choose one scenario: {}".format(", ".join(SCENARIOS)))

    default_workspace = (
        DEFAULT_CORE_WORKSPACE if scenario == "core-isolation" else DEFAULT_WORKSPACE
    )
    workspace = _workspace_path(args.workspace or default_workspace)
    output_base = Path(args.output_base).expanduser().resolve() if args.output_base else None
    runners = {
        "analysis": run_analysis,
        "inventory": run_inventory,
        "compile-probe": run_compile_probe,
        "core-isolation": run_core_isolation,
        "missing-ndk": run_missing_ndk,
        "lock-portability": run_lock_portability,
    }
    result = runners[scenario](workspace, output_base)
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ProbeError as error:
        print("FAIL: {}".format(error), file=sys.stderr)
        raise SystemExit(1)
