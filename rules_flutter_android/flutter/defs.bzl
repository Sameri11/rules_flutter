"""Supported BUILD-file API for the Android half of Flutter Consumer Modules.

Platform-neutral rules load from `@rules_flutter_core//flutter:defs.bzl`. This
entrypoint adds the Android macros; a Consumer Module that builds an APK loads
both. `flutter_app` and `flutter_assets` are wrapped here so their native build
hooks see the Android SDK by default. `flutter_core` is not wrapped; pass
`@rules_flutter_android//flutter:native_build_env` as its `native_build_env`.
"""

load(
    "@rules_flutter_core//flutter:defs.bzl",
    _core_flutter_app = "flutter_app",
    _core_flutter_assets = "flutter_assets",
)
load(
    "//flutter/private:android.bzl",
    _android_native_lib_jar = "android_native_lib_jar",
    _flutter_android_binary = "flutter_android_binary",
    _flutter_android_manifest = "flutter_android_manifest",
    _flutter_assets_dir = "flutter_assets_dir",
)
load("//flutter/private:android_app.bzl", _flutter_android_app = "flutter_android_app")
load("//flutter/private:android_inputs_rules.bzl", _flutter_android_inputs = "flutter_android_inputs")
load("//flutter/private:apk_check.bzl", _flutter_apk_check = "flutter_apk_check")
load("//flutter/private:embedding.bzl", _flutter_embedding_library = "flutter_embedding_library")
load(
    "//flutter/private:recipe.bzl",
    _flutter_native_contribution = "flutter_native_contribution",
    _flutter_native_libs = "flutter_native_libs",
)

# The Android SDK as the default native build environment. Label() resolves
# against this repository, not the consuming BUILD file's repository.
_ANDROID_NATIVE_BUILD_ENV = Label("//flutter:native_build_env")

def flutter_app(native_build_env = _ANDROID_NATIVE_BUILD_ENV, **kwargs):
    """flutter_app from @rules_flutter_core, with the Android SDK as the default native build environment."""
    _core_flutter_app(native_build_env = native_build_env, **kwargs)

def flutter_assets(native_build_env = _ANDROID_NATIVE_BUILD_ENV, **kwargs):
    """flutter_assets from @rules_flutter_core, with the Android SDK as the default native build environment."""
    _core_flutter_assets(native_build_env = native_build_env, **kwargs)

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

# The consumer-facing app macro: a stock android_binary with Flutter's defaults.
flutter_android_app = _flutter_android_app
