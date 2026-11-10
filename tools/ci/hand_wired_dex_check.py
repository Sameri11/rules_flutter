#!/usr/bin/env python3
"""Assert the hand-wired app's regular/dev plugins and Maven classes in DEX."""

import argparse
import sys
import zipfile
from pathlib import Path

REGULAR = (
    b"Lcom/example/handwired/regular/RegularPlugin;",
    b"Lcom/google/gson/Gson;",
)
DEV = (
    b"Lcom/example/handwired/dev/DevPlugin;",
    b"Lorg/apache/commons/lang3/StringUtils;",
)


def check(mode, apk):
    apk = Path(apk)
    if not apk.is_file():
        raise ValueError("APK does not exist: {}".format(apk))
    with zipfile.ZipFile(apk) as archive:
        dex_files = [name for name in archive.namelist() if name.startswith("classes") and name.endswith(".dex")]
        if not dex_files:
            raise ValueError("APK contains no DEX files: {}".format(apk))
        contents = b"".join(archive.read(name) for name in dex_files)
    expected = REGULAR + (DEV if mode == "debug" else ())
    absent = [descriptor.decode() for descriptor in expected if descriptor not in contents]
    forbidden = [descriptor.decode() for descriptor in (DEV if mode == "release" else ()) if descriptor in contents]
    if absent or forbidden:
        raise ValueError("{} DEX class mismatch: missing={}, unexpected={}".format(mode, absent, forbidden))
    print("PASS: {} DEX has regular plugin/Gson{}".format(mode, " and dev plugin/Commons Lang" if mode == "debug" else "; dev plugin/Commons Lang absent"))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("debug", "release"))
    parser.add_argument("apk", type=Path)
    args = parser.parse_args(argv)
    check(args.mode, args.apk)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, zipfile.BadZipFile) as error:
        print("FAIL: {}".format(error), file=sys.stderr)
        sys.exit(1)
