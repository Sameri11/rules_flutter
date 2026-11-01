"""Supported BUILD-file API for Flutter Consumer Modules.

Consumer BUILD files load this one entrypoint rather than the implementation
under ``//flutter/private``. Every name here is either written by hand in a
Consumer Module or named by a BUILD file these rules generate; nothing is
exported merely because it exists. Rules composed by the macros below --
``dart_aot_kernel``, ``dart_jit_kernel`` and ``dart_test_kernel`` stay private,
so their attributes remain free to change without a consumer migration. The
ABI names are public through ``@rules_flutter_core//flutter:abis.bzl``, which
re-exports the consumer-facing subset.

The Android macros load from `@rules_flutter_android//flutter:defs.bzl`.
"""

load(
    "//flutter/private:core.bzl",
    _FlutterArtifactInfo = "FlutterArtifactInfo",
    _flutter_core = "flutter_core",
)
load(
    "//flutter/private:flutter_test.bzl",
    _flutter_test = "flutter_test",
    _flutter_test_suite = "flutter_test_suite",
)
load("//flutter/private:pubspec.bzl", _FlutterPubspecInfo = "FlutterPubspecInfo", _flutter_pubspec = "flutter_pubspec")
load(
    "//flutter/private:rules.bzl",
    _FlutterNativeBuildEnvInfo = "FlutterNativeBuildEnvInfo",
    _dart_test_deps = "dart_test_deps",
    _flutter_assets = "flutter_assets",
    _flutter_package = "flutter_package",
    _pub_path_deps_check = "pub_path_deps_check",
    _pub_plugins_check = "pub_plugins_check",
)

# Explicit assignments make the curated names exports of this module. Merely
# importing names with load() does not re-export them to downstream BUILD files.
#
# Written by hand in a Consumer Module.
flutter_package = _flutter_package
flutter_test = _flutter_test
flutter_test_suite = _flutter_test_suite

# Named by the BUILD files the pub hub generates, so they are loaded across a
# repository boundary and have to resolve from this entrypoint.
dart_test_deps = _dart_test_deps

# The package-level build rules.
flutter_pubspec = _flutter_pubspec
flutter_assets = _flutter_assets
pub_path_deps_check = _pub_path_deps_check
pub_plugins_check = _pub_plugins_check

# The platform-composed artifact. An Android binary consumes it through
# rules_flutter_android's flutter_android_inputs.
flutter_core = _flutter_core
FlutterArtifactInfo = _FlutterArtifactInfo

# Read by rules_flutter_android for the version an APK declares.
FlutterPubspecInfo = _FlutterPubspecInfo

# What a native build environment rule returns, for the `native_build_env`
# attribute of flutter_core and flutter_assets.
FlutterNativeBuildEnvInfo = _FlutterNativeBuildEnvInfo
