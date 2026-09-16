#!/usr/bin/env python3
"""Run isolated Bzlmod repository-generation probes for BuildConfig validation.

Run explicitly with:

    python3 tests/consumer/build_config_probe.py

Each case copies the checked-in consumer fixture into a temporary module, changes
only its build_config_field tags, and runs a fresh `bazel query @flutter_plugins//:all`.
A separate output base makes every repository-generation failure independently observable.
"""

from __future__ import annotations

import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT / "tests" / "consumer"

CASES = {
    "absent_package": (
        [
            'package = "missing_build_config_package", name = "MISSING_VALUE", type = "String", value = "x"',
        ],
        "missing_build_config_package.MISSING_VALUE",
    ),
    "duplicate_field": (
        [
            'package = "build_config_plugin", name = "DUPLICATE_VALUE", type = "String", value = "one"',
            'package = "build_config_plugin", name = "DUPLICATE_VALUE", type = "String", value = "two"',
        ],
        "build_config_plugin.DUPLICATE_VALUE",
    ),
    "built_in_collision": (
        [
            'package = "build_config_plugin", name = "DEBUG", type = "boolean", value = "true"',
        ],
        "build_config_plugin.DEBUG",
    ),
    "unsupported_type": (
        [
            'package = "build_config_plugin", name = "UNSUPPORTED_VALUE", type = "char", value = "x"',
        ],
        "build_config_plugin.UNSUPPORTED_VALUE",
    ),
    "invalid_typed_value": (
        [
            'package = "build_config_plugin", name = "INVALID_VALUE", type = "int", value = "1.5"',
        ],
        "build_config_plugin.INVALID_VALUE",
    ),
    "out_of_range_value": (
        [
            'package = "build_config_plugin", name = "OUT_OF_RANGE", type = "float", value = "3.5e38"',
        ],
        "build_config_plugin.OUT_OF_RANGE",
    ),
    "both_sources": (
        [
            'package = "build_config_plugin", name = "BOTH_VALUE", type = "String", value = "x", value_from = "package_version"',
        ],
        "build_config_plugin.BOTH_VALUE",
    ),
    "neither_source": (
        [
            'package = "build_config_plugin", name = "NEITHER_VALUE", type = "String"',
        ],
        "build_config_plugin.NEITHER_VALUE",
    ),
    "unsupported_value_from": (
        [
            'package = "build_config_plugin", name = "UNSUPPORTED_SOURCE", type = "String", value_from = "environment"',
        ],
        "build_config_plugin.UNSUPPORTED_SOURCE",
    ),
}


def tag(declaration: str) -> str:
    attrs = [part.strip() for part in declaration.split(", ")]
    return "plugins.build_config_field(\n" + "\n".join(
        "    " + part + "," for part in attrs
    ) + "\n)\n"


def replace_tags(config: str, declarations: list[str]) -> str:
    pattern = re.compile(r"plugins\.build_config_field\(\n.*?\n\)\n", re.DOTALL)
    config = pattern.sub("", config)
    insertion = "\n".join(tag(declaration) for declaration in declarations)
    return config.replace("plugins.project(\n", insertion + "\nplugins.project(\n", 1)


def run_case(name: str, declarations: list[str], expected: str) -> None:
    with tempfile.TemporaryDirectory(prefix="rules-flutter-build-config-") as tmp:
        workspace = Path(tmp) / "consumer"
        shutil.copytree(
            FIXTURE,
            workspace,
            ignore=shutil.ignore_patterns(
                "bazel-*",
                "MODULE.bazel.lock",
                "*.checked",
                ".dart_tool",
            ),
        )
        module = workspace / "MODULE.bazel"
        module.write_text(
            module.read_text().replace(
                'path = "../.."',
                'path = "{}"'.format(ROOT),
            ),
        )
        (workspace / ".bazelrc").write_text("common --enable_bzlmod\n")
        config_path = workspace / "android" / "config.MODULE.bazel"
        config_path.write_text(replace_tags(config_path.read_text(), declarations))
        output_root = Path(tmp) / "output-user-root"
        command = [
            "bazel",
            "--output_user_root=" + str(output_root),
            "query",
            "--lockfile_mode=update",
            "--noshow_progress",
            "--noshow_loading_progress",
            "@flutter_plugins//:all",
        ]
        result = subprocess.run(
            command,
            cwd=workspace,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
        if result.returncode == 0:
            raise AssertionError("{} unexpectedly succeeded".format(name))
        if expected not in result.stdout:
            raise AssertionError(
                "{} diagnostic did not contain {!r}:\n{}".format(
                    name,
                    expected,
                    result.stdout,
                ),
            )
        print("{}: rejected with {}".format(name, expected))


def main() -> int:
    for name, (declarations, expected) in CASES.items():
        run_case(name, declarations, expected)
    return 0


if __name__ == "__main__":
    sys.exit(main())
