#!/usr/bin/env python3
"""Check that the APK hash gate rejects an app it does not list.

Plants an extra `flutter_android_app` in demo_app's Android package, requires
the real Bazel query to discover it, then runs `example_hashes.py --check`
through a Bazel wrapper that logs each command. The gate must fail naming the
planted label after the query and before any build. The BUILD file is restored
afterwards.
"""

from __future__ import annotations

import argparse
import importlib.util
import shlex
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "tools" / "ci" / "example_hashes.py"
MODULE = ROOT / "examples" / "demo_app"
BUILD = MODULE / "android" / "app" / "BUILD.bazel"
LABEL = "//android/app:inventory_probe"
PLANT = b'''
flutter_android_app(
    name = "inventory_probe",
    core = "//:app",
    plugins = "@flutter_plugins",
    manifest_values = {"applicationId": "com.example.inventory_probe"},
    deps = [":main_activity"],
)
'''


def load_example_hashes():
    spec = importlib.util.spec_from_file_location("example_hashes", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def check(bazel, golden):
    if LABEL not in load_example_hashes().declared_apk_targets(bazel, MODULE):
        sys.exit("The planted app was not discovered by the actual Bazel query")
    with tempfile.TemporaryDirectory() as temporary:
        directory = Path(temporary)
        calls = directory / "calls"
        wrapper = directory / "bazel"
        wrapper.write_text(
            '#!/usr/bin/env bash\nprintf "%s\\n" "$1" >> ' + shlex.quote(str(calls))
            + "\nexec " + shlex.quote(bazel) + ' "$@"\n'
        )
        wrapper.chmod(0o755)
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--check", "--only", "demo_app",
             "--bazel", str(wrapper), "--manifests", str(directory / "captures"),
             "--golden", str(golden)],
            capture_output=True, text=True,
        )
        invoked = calls.read_text().splitlines() if calls.exists() else []
    if result.returncode == 0 or invoked != ["query"] or LABEL not in result.stderr:
        sys.exit(f"Inventory rejection failed: calls={invoked}\n{result.stdout}\n{result.stderr}")
    print(f"Unlisted app rejected before any build: {LABEL}")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--golden", type=Path, required=True)
    golden = parser.parse_args().golden.resolve()
    bazel = shutil.which("bazel")
    if not bazel:
        sys.exit("Bazel is unavailable for the inventory rejection check")
    original = BUILD.read_bytes()
    try:
        BUILD.write_bytes(original + PLANT)
        check(bazel, golden)
    finally:
        BUILD.write_bytes(original)


if __name__ == "__main__":
    main()
