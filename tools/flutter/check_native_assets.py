"""Fail the build if a Dart code asset has no library behind it.

A package that produces a *code asset* through a Dart build hook -- `sqlite3`,
`objective_c`, anything using `package:hooks` -- declares an asset id, and the
Dart VM resolves that id to a filename through `NativeAssetsManifest.json`, which
`flutter build bundle` writes into the asset bundle. The VM then `dlopen`s that
filename, expecting to find it in `lib/<abi>/` inside the APK.

Nothing else in this build connects those two halves. The manifest is produced by
flutter_tools from the hook's output; the library reaches `lib/<abi>/` only if
someone wrote a package recipe for it. When they have not, every step is green --
the manifest is well-formed, the bundle is byte-identical to the reference, the
APK installs and launches -- and the app dies on the first FFI call with

    dlopen failed: library "libsqlite3.so" not found

This compares the two directly: every filename the manifest names must be present
in the jar of recipe-contributed libraries.
"""

import argparse
import json
import os
import sys
import zipfile


def manifest_entries(path):
    """(asset id, filename) for every bundled code asset in the manifest.

    Shape, from _toNativeAssetsJsonFile in flutter_tools:

        {"format-version": [1, 0, 0],
         "native-assets": {"android_arm64": {"<id>": ["absolute", "<file>"]}}}

    Only `absolute` entries name a file this build has to supply. The other path
    types -- `system`, `process`, `executable` -- resolve to something already
    present at runtime and are deliberately ignored.
    """
    with open(path) as f:
        manifest = json.load(f)

    version = manifest.get("format-version")
    if version and version[0] != 1:
        sys.exit(
            "NativeAssetsManifest.json is format-version {}, and this check only "
            "understands 1.x. Bump it deliberately after re-reading "
            "_toNativeAssetsJsonFile in flutter_tools.".format(version)
        )

    found = []
    for target, assets in (manifest.get("native-assets") or {}).items():
        for asset_id, path_entry in assets.items():
            if not path_entry or path_entry[0] != "absolute":
                continue
            # The value is a bare filename on Android: the loader finds it in
            # lib/<abi>/ inside the APK.
            found.append((target, asset_id, os.path.basename(path_entry[1])))
    return found


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True,
                        help="NativeAssetsManifest.json from the asset bundle")
    parser.add_argument("--jar", required=True,
                        help="Jar of recipe-contributed lib/<abi>/*.so")
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    # No manifest at all means no package in this app produced a code asset,
    # which is the common case and is not an error.
    if not os.path.exists(args.manifest):
        open(args.out, "w").close()
        return

    entries = manifest_entries(args.manifest)

    packaged = set()
    with zipfile.ZipFile(args.jar) as z:
        for name in z.namelist():
            if name.endswith(".so"):
                packaged.add(os.path.basename(name))

    missing = [(t, i, f) for t, i, f in entries if f not in packaged]
    if missing:
        lines = [
            "This app declares Dart code assets that no package recipe supplies.",
            "",
            "The asset bundle's NativeAssetsManifest.json names these libraries,",
            "and the Dart VM will dlopen them by exactly these filenames:",
            "",
        ]
        for target, asset_id, filename in sorted(missing):
            lines.append("  {}  {}".format(target, asset_id))
            lines.append("    -> {}   MISSING".format(filename))
        lines += [
            "",
            "None of them reached lib/<abi>/ in the APK, so the app will build,",
            "install and launch, then fail on the first call into that package.",
            "",
            "Fix by giving the package a recipe in MODULE.bazel:",
            "",
            '    plugins.package(',
            '        name = "<pub package>",',
            '        bzl_file = "//bazel/flutter:<package>.bzl",',
            '        macro = "<package>_recipe",',
            '    )',
            "",
            "See docs/package-recipes.md. Libraries the recipes did supply: {}".format(
                ", ".join(sorted(packaged)) if packaged else "(none)"
            ),
        ]
        sys.exit("\n".join(lines))

    with open(args.out, "w") as f:
        for target, asset_id, filename in sorted(entries):
            f.write("{} {} {}\n".format(target, asset_id, filename))


if __name__ == "__main__":
    main()
