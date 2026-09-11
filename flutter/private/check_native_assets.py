"""Fail the build if an ABI is missing a library the app will look for.

Two failures, one script: both are answered by the same two inputs -- the
bundle's `NativeAssetsManifest.json` and the jars whose `lib/<abi>/` entries
become the APK's native libraries.

**A code asset with no library behind it.** A package with a Dart build hook --
`sqlite3`, `objective_c`, anything using `package:hooks` -- declares an asset id;
the Dart VM resolves it to a filename through the manifest and `dlopen`s that,
expecting `lib/<abi>/`. Nothing else connects the halves: the manifest comes from
flutter_tools, the library only from a package recipe. Without one, every step is
green and the app dies on its first FFI call with

    dlopen failed: library "libsqlite3.so" not found

**A jar in the wrong ABI's slot.** What makes a jar an ABI's is the `lib/<abi>/`
prefix inside it, not the label it was reached by, so handing the arm64 jar to
the x86_64 slot resolves and builds and ships an empty ABI.

The manifest is therefore checked per ABI, against the key that ABI's engine
reads, rather than by comparing filenames globally. A merged manifest carries
keys for ABIs this APK does not ship; those are ignored.
"""

import argparse
import json
import os
import sys
import zipfile


def manifest_entries(path):
    """{manifest key: [(asset id, filename)]} for every bundled code asset.

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

    found = {}
    for target, assets in (manifest.get("native-assets") or {}).items():
        entries = []
        for asset_id, path_entry in assets.items():
            if not path_entry or path_entry[0] != "absolute":
                continue
            # The value is a bare filename on Android: the loader finds it in
            # lib/<abi>/ inside the APK.
            entries.append((asset_id, os.path.basename(path_entry[1])))
        found[target] = entries
    return found


def libraries(abi, kind, jar):
    """Basenames of the .so a jar contributes to lib/<abi>/.

    Exits if the jar carries a library under any other ABI: that is the jar
    having been declared for an ABI that is not its own.
    """
    found = []
    misplaced = []
    with zipfile.ZipFile(jar) as z:
        for name in z.namelist():
            if not name.endswith(".so"):
                continue
            if os.path.dirname(name) == os.path.join("lib", abi):
                found.append(os.path.basename(name))
            else:
                misplaced.append(name)

    if misplaced:
        sys.exit(
            "\n".join(
                [
                    "The '{}' contribution for {} carries libraries that are "
                    "not that ABI's.".format(kind, abi),
                    "",
                    "  jar: {}".format(jar),
                    "",
                    "Android loads native libraries from lib/<abi>/ inside the "
                    "APK, so what makes",
                    "a library this ABI's is the prefix inside the jar. These "
                    "are under another:",
                    "",
                ]
                + ["  {}".format(name) for name in sorted(misplaced)]
                + [
                    "",
                    "Either the jar was built for a different ABI, or it was "
                    "supplied for the wrong",
                    "one. Both produce an APK that installs and then finds "
                    "nothing on {}.".format(abi),
                ]
            )
        )
    return found


def missing_recipes(abi, entries, packaged):
    """The manifest's code assets for one ABI that no jar supplies."""
    return [(asset_id, name) for asset_id, name in entries if name not in packaged]


def report_missing(abi, missing, packaged):
    lines = [
        "This app declares Dart code assets that no package recipe supplies "
        "for {}.".format(abi),
        "",
        "The asset bundle's NativeAssetsManifest.json names these libraries,",
        "and the Dart VM will dlopen them by exactly these filenames:",
        "",
    ]
    for asset_id, filename in sorted(missing):
        lines.append("  {}".format(asset_id))
        lines.append("    -> {}   MISSING".format(filename))
    lines += [
        "",
        "None of them reached lib/{}/ in the APK, so the app will build,".format(abi),
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
        "See docs/package-recipes.md. Libraries the recipes did supply for "
        "{}: {}".format(abi, ", ".join(sorted(packaged)) if packaged else "(none)"),
    ]
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True,
                        help="NativeAssetsManifest.json from the asset bundle")
    parser.add_argument("--abi", action="append", default=[], metavar="ABI=KEY",
                        help="An ABI this bundle ships, and the manifest key "
                             "its engine reads.")
    parser.add_argument("--jar", action="append", default=[],
                        metavar="ABI=KIND=PATH",
                        help="A jar of lib/<abi>/*.so, and which contribution "
                             "it is.")
    parser.add_argument("--require", action="append", default=[],
                        metavar="KIND",
                        help="A contribution every ABI must have a library "
                             "from.")
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    keys = {}
    for entry in args.abi:
        abi, _, key = entry.partition("=")
        keys[abi] = key

    # {abi: {kind: [soname]}}. The jar walk catches a mis-declared ABI, so it
    # runs whether or not there is a manifest to check afterwards.
    packaged = {abi: {} for abi in keys}
    for entry in args.jar:
        abi, _, rest = entry.partition("=")
        kind, _, jar = rest.partition("=")
        if abi not in packaged:
            sys.exit("--jar names {}, which is not one of --abi {}.".format(
                abi, sorted(keys)))
        packaged[abi].setdefault(kind, []).extend(libraries(abi, kind, jar))

    for abi in sorted(packaged):
        for kind in args.require:
            if not packaged[abi].get(kind):
                sys.exit(
                    "The '{}' contribution supplies no library for {}.\n"
                    "An APK claiming that ABI without one installs and then "
                    "fails to start on it.".format(kind, abi)
                )

    # No manifest at all means no package in this app produced a code asset,
    # which is the common case and is not an error.
    if not os.path.exists(args.manifest):
        open(args.out, "w").close()
        return

    entries = manifest_entries(args.manifest)

    checked = []
    for abi in sorted(packaged):
        key = keys[abi]

        # An empty manifest is an app with no code assets. A populated one
        # missing a shipped ABI's slot is a bundle built for a different ABI
        # set than the APK.
        if entries and key not in entries:
            sys.exit(
                "The asset bundle has no '{}' entry, which is the key the {} "
                "engine reads.\n"
                "It carries {}. The bundle and the APK disagree about which "
                "ABIs this app ships:\n"
                "give flutter_assets the same `abis` as "
                "flutter_android_libs.".format(key, abi, sorted(entries))
            )

        supplied = set()
        for names in packaged[abi].values():
            supplied.update(names)

        missing = missing_recipes(abi, entries.get(key, []), supplied)
        if missing:
            sys.exit(report_missing(abi, missing, supplied))

        for asset_id, filename in sorted(entries.get(key, [])):
            checked.append("{} {} {}".format(key, asset_id, filename))

    with open(args.out, "w") as f:
        for line in checked:
            f.write(line + "\n")


if __name__ == "__main__":
    main()
