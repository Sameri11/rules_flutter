"""Recipe fixture that consumes Maven labels supplied by the plugin hub."""

load("@rules_flutter_android//flutter:defs.bzl", "flutter_native_contribution")

def recipe_fixture(name, info):
    native.alias(
        name = name,
        actual = info.coordinates[0],
    )
    flutter_native_contribution(
        name = name + "_flutter_native",
        libraries = {},
        empty = True,
    )
