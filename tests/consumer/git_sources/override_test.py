#!/usr/bin/env python3
import json
import pathlib
import sys

config = pathlib.Path(sys.argv[1])
replacement_pubspec = pathlib.Path(sys.argv[2]).resolve()
data = json.loads(config.read_text())
package = next(
    item for item in data["packages"]
    if item["name"] == "openfoodfacts_flutter_lints"
)
root = (config.parent / package["rootUri"]).resolve()
if root != replacement_pubspec.parent:
    raise SystemExit(
        f"package_config points at {root}, not replacement {replacement_pubspec.parent}"
    )
