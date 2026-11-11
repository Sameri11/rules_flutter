#!/usr/bin/env python3
"""Check that each debug test APK packages its declared kernel and assets."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
import zipfile
from pathlib import Path


def run(bazel: str, module: Path, args: list[str], bazel_args: list[str]) -> str:
    result = subprocess.run(
        [bazel, *args[:1], *bazel_args, *args[1:]], cwd=module, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
    )
    if result.returncode:
        raise RuntimeError("{} failed:\n{}".format(" ".join(args), result.stderr))
    return result.stdout


def outputs(bazel: str, module: Path, label: str, bazel_args: list[str]) -> list[Path]:
    paths = [module / path for path in run(
        bazel, module, ["cquery", "--lockfile_mode=error", "--output=files", label], bazel_args
    ).splitlines() if path and not path.startswith("INFO:")]
    unique = {}
    for path in paths:
        unique.setdefault(path.resolve(), path)
    return list(unique.values())


def apk_path(bazel: str, module: Path, label: str, bazel_args: list[str]) -> Path:
    files = [path for path in outputs(bazel, module, label, bazel_args) if path.name == label.rsplit(":", 1)[-1] + ".apk"]
    if len(files) != 1 or not files[0].is_file():
        raise RuntimeError("{} has no unique built APK: {}".format(label, files))
    return files[0]


# Kernel artifacts are named by the core rule's private platform-specific output target.
def kernel_path(bazel: str, module: Path, label: str, bazel_args: list[str]) -> Path:
    kernel_label = label + "_kernel_android"
    files = [path for path in outputs(bazel, module, kernel_label, bazel_args) if path.suffix == ".dill" and path.is_file()]
    unique = {}
    for path in files:
        unique.setdefault(hashlib.sha256(path.read_bytes()).digest(), path)
    if len(unique) != 1:
        raise RuntimeError("{} has no unique built Android kernel contents: {}".format(label, files))
    return next(iter(unique.values()))


def input_paths(data: dict) -> set[str]:
    fragments = {item["id"]: item for item in data.get("pathFragments", [])}

    def fragment_path(identifier):
        item = fragments[identifier]
        parent = item.get("parentId")
        return (fragment_path(parent) + "/" if parent else "") + item["label"]

    artifact_by_id = {
        item["id"]: fragment_path(item["pathFragmentId"])
        for item in data.get("artifacts", [])
    }
    depsets = {item["id"]: item for item in data.get("depSetOfFiles", [])}
    cache: dict[int, set[str]] = {}

    def visit(identifier: int) -> set[str]:
        if identifier in cache:
            return cache[identifier]
        entry = depsets[identifier]
        paths = {artifact_by_id[item] for item in entry.get("directArtifactIds", [])}
        for child in entry.get("transitiveDepSetIds", []):
            paths |= visit(child)
        cache[identifier] = paths
        return paths

    paths = set()
    for action in data.get("actions", []):
        for identifier in action.get("inputDepSetIds", []):
            paths |= visit(identifier)
    return paths


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bazel", default="bazel")
    parser.add_argument("--module", type=Path, default=Path.cwd())
    parser.add_argument("--bazel-arg", action="append", default=[])
    parser.add_argument("--app-core", required=True)
    parser.add_argument("--app-apk", required=True)
    parser.add_argument("--test", action="append", required=True, metavar="APK=CORE")
    args = parser.parse_args()
    try:
        module = args.module.resolve()
        app_apk = apk_path(args.bazel, module, args.app_apk, args.bazel_arg)
        if not app_apk.is_file():
            raise RuntimeError("app APK is missing: {}".format(app_apk))
        app_assets = [path for path in outputs(args.bazel, module, args.app_core, args.bazel_arg) if path.is_dir() and path.name == "flutter_assets"]
        if not app_assets:
            raise RuntimeError("{} has no Flutter asset tree".format(args.app_core))
        app_bundles = {path.relative_to(module).as_posix() for path in app_assets}
        for item in args.test:
            apk_label, core_label = item.split("=", 1)
            apk = apk_path(args.bazel, module, apk_label, args.bazel_arg)
            kernel = kernel_path(args.bazel, module, core_label, args.bazel_arg)
            with zipfile.ZipFile(apk) as archive:
                embedded = archive.read("assets/flutter_assets/kernel_blob.bin")
            if embedded != kernel.read_bytes():
                raise RuntimeError("{} kernel_blob.bin differs from {}_kernel_android".format(apk_label, core_label))
            graph = json.loads(run(args.bazel, module, [
                "aquery", "--lockfile_mode=error", "--output=jsonproto",
                "deps({})".format(apk_label),
            ], args.bazel_arg))
            all_inputs = input_paths(graph)
            app_assets_in_inputs = sorted(app_bundle for app_bundle in app_bundles if app_bundle in all_inputs)
            if app_assets_in_inputs:
                raise RuntimeError("{} packages the app core's Flutter assets {}".format(apk_label, app_assets_in_inputs))
            asset_copy = "{}_assets/flutter_assets".format(apk_label.rsplit(":", 1)[-1])
            if not any(path.endswith(asset_copy) for path in all_inputs):
                raise RuntimeError("{} does not consume its test-core FlutterAssetCopy output {}".format(apk_label, asset_copy))
            print("{}: kernel matches {}; app asset tree absent from APK inputs; test asset copy present".format(apk_label, core_label))
        return 0
    except (RuntimeError, OSError, KeyError, ValueError, zipfile.BadZipFile) as error:
        print("FAIL: {}".format(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
