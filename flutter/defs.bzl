"""Supported BUILD-file API for Flutter Consumer Modules.

Consumer BUILD files load this one entrypoint rather than the implementation
under ``//flutter/private``. Every name here is either written by hand in a
Consumer Module or named by a BUILD file these rules generate; nothing is
exported merely because it exists. Rules composed by the macros below --
``dart_kernel``, ``flutter_android_libs``, ``jni_lib_jar``,
``strip_native_libs`` -- and the ``ABIS`` table stay private, so their
attributes remain free to change without a consumer migration.
"""

load(
    "//flutter/private:android.bzl",
    _android_native_lib_jar = "android_native_lib_jar",
    _flutter_android_binary = "flutter_android_binary",
)
load(
    "//flutter/private:embedding.bzl",
    _flutter_embedding_library = "flutter_embedding_library",
)
load("//flutter/private:pubspec.bzl", _flutter_pubspec = "flutter_pubspec")
load(
    "//flutter/private:recipe.bzl",
    _flutter_native_contribution = "flutter_native_contribution",
    _flutter_native_libs = "flutter_native_libs",
)
load(
    "//flutter/private:rules.bzl",
    _flutter_aot_library = "flutter_aot_library",
    _flutter_app = "flutter_app",
    _flutter_assets = "flutter_assets",
    _pub_path_deps_check = "pub_path_deps_check",
    _pub_plugins_check = "pub_plugins_check",
)

# Explicit assignments make the curated names exports of this module. Merely
# importing names with load() does not re-export them to downstream BUILD files.
#
# Written by hand in a Consumer Module.
flutter_app = _flutter_app
flutter_android_binary = _flutter_android_binary
flutter_embedding_library = _flutter_embedding_library
flutter_native_contribution = _flutter_native_contribution

# Named by the BUILD files the plugin extension generates, so they are loaded
# across a repository boundary and have to resolve from this entrypoint.
android_native_lib_jar = _android_native_lib_jar
flutter_native_libs = _flutter_native_libs

# The Dart half on its own, for an app whose Dart layout `flutter_app` refuses.
flutter_pubspec = _flutter_pubspec
flutter_aot_library = _flutter_aot_library
flutter_assets = _flutter_assets
pub_path_deps_check = _pub_path_deps_check
pub_plugins_check = _pub_plugins_check
