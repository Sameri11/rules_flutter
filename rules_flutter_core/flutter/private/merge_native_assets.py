"""Merge asset bundles for one platform and reject inconsistent slice outputs.

Each slice can emit a different NativeAssetsManifest.json entry, while all
other bundle files must be byte-identical. Verify that contract before merging
the manifests so one slice's assets are never silently used by another.

Manifest keys are sorted, keeping the output byte-stable across runs.
"""

import argparse
import filecmp
import hashlib
import json
import os
import sys

MANIFEST = "NativeAssetsManifest.json"


def tree(root):
    """Relative paths of every file under `root`."""
    found = set()
    for dirpath, _dirnames, filenames in os.walk(root):
        for name in filenames:
            full = os.path.join(dirpath, name)
            found.add(os.path.relpath(full, root))
    return found


def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def compare(base_slice, base, other_slice, other):
    """Every difference between two bundles, ignoring the manifest."""
    problems = []

    only_base = sorted((tree(base) - tree(other)) - {MANIFEST})
    only_other = sorted((tree(other) - tree(base)) - {MANIFEST})
    for name in only_base:
        problems.append("  {} has {}, {} does not".format(base_slice, name, other_slice))
    for name in only_other:
        problems.append("  {} has {}, {} does not".format(other_slice, name, base_slice))

    for name in sorted((tree(base) & tree(other)) - {MANIFEST}):
        a, b = os.path.join(base, name), os.path.join(other, name)
        # shallow=False: same size and mtime is not the same bytes, and these
        # are produced seconds apart by the same tool.
        if not filecmp.cmp(a, b, shallow=False):
            problems.append("  {} differs: {} vs {}".format(
                name,
                digest(a)[:12],
                digest(b)[:12],
            ))
    return problems


def merge(manifests):
    """One manifest carrying every bundle's native-assets keys."""
    merged = None
    assets = {}
    for target_slice, path in manifests:
        with open(path) as handle:
            raw = handle.read()
        try:
            loaded = json.loads(raw)
        except ValueError as err:
            sys.exit("{} ({}) is not valid JSON: {}\nContents: {!r}".format(
                path, target_slice, err, raw[:200]))

        version = loaded.get("format-version")
        if merged is None:
            merged = version
        elif version != merged:
            sys.exit(
                "NativeAssetsManifest.json format-version differs across target slices: "
                "{} vs {}. Merging them would be a guess.".format(merged, version)
            )

        for key, value in loaded.get("native-assets", {}).items():
            if key in assets and assets[key] != value:
                sys.exit(
                    "Two bundles disagree about native-assets key "
                    "{!r} (seen again in {}).".format(key, target_slice)
                )
            assets[key] = value

    return {
        "format-version": merged,
        # Sorted so the tree artifact is byte-stable across runs.
        "native-assets": {k: assets[k] for k in sorted(assets)},
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--bundle",
        action="append",
        default=[],
        metavar="TARGET_SLICE=DIR",
        help="A bundle slice to merge. The first is the one written into.",
    )
    args = parser.parse_args()

    bundles = []
    for entry in args.bundle:
        target_slice, _, path = entry.partition("=")
        bundles.append((target_slice, path))
    if not bundles:
        sys.exit("--bundle is required")

    base_slice, base = bundles[0]
    problems = []
    for target_slice, path in bundles[1:]:
        problems += compare(base_slice, base, target_slice, path)

    if problems:
        sys.exit(
            "Asset bundles differ between target slices in files other than "
            "{}:\n{}\n\nThe merged bundle is only correct while every target slice "
            "produces the same assets. Something now varies by "
            "target.".format(MANIFEST, "\n".join(problems))
        )

    manifests = [(target_slice, os.path.join(path, MANIFEST)) for target_slice, path in bundles]
    manifests = [(target_slice, path) for target_slice, path in manifests if os.path.exists(path)]
    if not manifests:
        return

    # Merged before the file is opened: the base bundle's manifest is both an
    # input and the destination, and `open(..., "w")` truncates it.
    merged = merge(manifests)
    with open(os.path.join(base, MANIFEST), "w") as handle:
        json.dump(merged, handle, separators=(",", ":"), sort_keys=False)


if __name__ == "__main__":
    main()
