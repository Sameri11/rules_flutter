"""Supported BUILD-file API for the Android half of Flutter Consumer Modules.

Platform-neutral rules load from `@rules_flutter_core//flutter:defs.bzl`. This
entrypoint adds the Android macros; a Consumer Module that builds an APK loads
both. The `native_build_env` target lives in this package: pass
`@rules_flutter_android//flutter:native_build_env` as the `native_build_env` of a
flutter_app or flutter_core whose native build hooks need the Android SDK.
"""

load(
    "//flutter/private:android.bzl",
    _android_native_lib_jar = "android_native_lib_jar",
    _flutter_android_binary = "flutter_android_binary",
    _flutter_android_manifest = "flutter_android_manifest",
    _flutter_assets_dir = "flutter_assets_dir",
)
load("//flutter/private:android_inputs_rules.bzl", _flutter_android_inputs = "flutter_android_inputs")
load("//flutter/private:apk_check.bzl", _flutter_apk_check = "flutter_apk_check")
load("//flutter/private:embedding.bzl", _flutter_embedding_library = "flutter_embedding_library")
load(
    "//flutter/private:recipe.bzl",
    _flutter_native_contribution = "flutter_native_contribution",
    _flutter_native_libs = "flutter_native_libs",
)

# Explicit assignments make the curated names exports of this module. Merely
# importing names with load() does not re-export them to downstream BUILD files.
#
# Written by hand in a Consumer Module.
flutter_android_binary = _flutter_android_binary
flutter_embedding_library = _flutter_embedding_library
flutter_native_contribution = _flutter_native_contribution

# Named by the BUILD files the plugin extension generates, so they are loaded
# across a repository boundary and have to resolve from this entrypoint.
android_native_lib_jar = _android_native_lib_jar
flutter_native_libs = _flutter_native_libs

# The composition route: one android_inputs and apk_check per Android binary,
# and the composed android_binary's assets_dir and manifest.
flutter_android_inputs = _flutter_android_inputs
flutter_apk_check = _flutter_apk_check
flutter_android_manifest = _flutter_android_manifest
flutter_assets_dir = _flutter_assets_dir
