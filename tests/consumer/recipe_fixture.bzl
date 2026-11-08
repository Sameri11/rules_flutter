"""Compile recipe fixture plugins against resolved Maven coordinates."""

load("@rules_flutter_android//flutter:defs.bzl", "flutter_native_contribution")
load("@rules_kotlin//kotlin:android.bzl", "kt_android_library")

def recipe_fixture(name, info):
    kt_android_library(
        name = name,
        srcs = info.android_srcs,
        custom_package = info.namespace,
        deps = [info.embedding] + info.plugin_deps + info.coordinates,
    )
    flutter_native_contribution(
        name = name + "_flutter_native",
        libraries = {},
        empty = True,
    )
