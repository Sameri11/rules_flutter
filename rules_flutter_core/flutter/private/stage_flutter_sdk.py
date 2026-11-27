#!/usr/bin/env python3
"""Stages the pinned Flutter SDK layout required by flutter_tools."""

import argparse
import json
import os
import pathlib


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--sdk-root", required=True)
    parser.add_argument("--layout", required=True)
    parser.add_argument("--root", required=True)
    parser.add_argument("--package-config", required=True)
    parser.add_argument("--execroot", required=True)
    args = parser.parse_args()

    sdk_root = pathlib.Path(args.sdk_root)
    root = pathlib.Path(args.root)
    with open(args.layout, encoding="utf-8") as stream:
        entries = json.load(stream)
    for entry in entries:
        destination = root / entry["destination"]
        source = sdk_root / "pieces" / entry["source"]
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.symlink_to(source)

    config_path = pathlib.Path(args.package_config)
    with config_path.open(encoding="utf-8") as stream:
        config = json.load(stream)
    for package in config["packages"]:
        package_path = os.path.normpath(os.path.join(config_path.parent, package["rootUri"]))
        if not os.path.isabs(package_path):
            package_path = os.path.join(args.execroot, package_path)
        package["rootUri"] = pathlib.Path(package_path).as_uri()
    target = root / "packages/flutter_tools/.dart_tool/package_config.json"
    target.parent.mkdir(parents=True, exist_ok=True)
    with target.open("w", encoding="utf-8") as stream:
        json.dump(config, stream, separators=(",", ":"))


if __name__ == "__main__":
    main()
