#!/usr/bin/env bash
set -euo pipefail

python3 - "$1" "$2" <<'PY'
import json
import os
import pathlib
import sys

config = pathlib.Path(sys.argv[1])
replacement_pubspec = pathlib.Path(sys.argv[2])
data = json.loads(config.read_text())
package = next(
    item for item in data["packages"]
    if item["name"] == "openfoodfacts_flutter_lints"
)
root = config.parent / package["rootUri"]
expected = root / "pubspec.yaml"
if not os.path.samefile(expected, replacement_pubspec):
    raise SystemExit(
        f"package_config points at {expected}, not replacement {replacement_pubspec}"
    )
PY
