"""Where a Flutter SDK keeps the Dart packages a `source: sdk` lock entry names.

`pubspec.lock` records an SDK package by name only: no archive, no hash. The SDK
lays them out by convention, so no table of names is kept. `@flutter_sdk`
(repo.bzl) discovers the packages that exist and exposes them at the paths below;
the pub hub (pub_lock.bzl) points package configs at the same paths. One function
keeps the two agreeing.
"""

visibility(["//flutter"])

def sdk_package_root(name):
    """SDK-relative directory of the SDK package `name`."""

    # sky_engine ships with the engine artifacts, every other SDK package under
    # `packages/`.
    if name == "sky_engine":
        return "bin/cache/pkg/sky_engine"
    return "packages/" + name
