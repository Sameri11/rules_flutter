#!/usr/bin/env python3
"""Write a Dart entrypoint importing external package roots found in sources."""

import json
import os
import re
import sys
from pathlib import Path
from urllib.parse import unquote, urlparse


def main(argv):
    package_config = Path(argv[1])
    output = Path(argv[2])
    sources = [Path(path) for path in argv[3:]]
    config = json.loads(package_config.read_text())
    external_root = Path(os.path.abspath("external"))
    packages = {}
    for package in config["packages"]:
        root_uri = urlparse(package["rootUri"])
        root = Path(unquote(root_uri.path)) if root_uri.scheme == "file" else package_config.parent / unquote(package["rootUri"])
        root = Path(os.path.abspath(root))
        try:
            root.absolute().relative_to(external_root)
        except ValueError:
            continue
        packages[package["name"]] = package

    directive = re.compile(r"\b(?:import|export)\b[^;]*;", re.S)
    uri_pattern = re.compile(r"['\"](package:[^'\"]+)['\"]")
    roots = set()
    for source in sources:
        try:
            text = source.read_text()
        except (OSError, UnicodeError):
            continue
        for statement in directive.findall(text):
            for uri in uri_pattern.findall(statement):
                name = uri.split(":", 1)[1].split("/", 1)[0]
                if name in packages:
                    roots.add(uri)

    output.write_text("// Generated external package roots.\n" + "".join("import '{}';\n".format(uri) for uri in sorted(roots)) + "void main() {}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
