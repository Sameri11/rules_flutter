"""Supported convenience BUILD API for Flutter Android consumer modules."""

load("@rules_flutter_core//flutter:composition.bzl", _core_flutter_assets = "flutter_assets")
load("@rules_flutter_core//flutter:defs.bzl", _flutter_platform = "flutter_platform")
load("//flutter:abis.bzl", "ABIS")
load("//flutter/private:abis.bzl", "bazel_platform")
load("//flutter/private:android_app.bzl", _FLUTTER_DEBUG_UNCOMPRESSED_ASSETS = "FLUTTER_DEBUG_UNCOMPRESSED_ASSETS", _flutter_android_app = "flutter_android_app")
load("//flutter/private:plugin_deps_guards.bzl", _flutter_plugin_deps_guards = "flutter_plugin_deps_guards")
load("//flutter/private:recipe.bzl", _flutter_native_contribution = "flutter_native_contribution")

FLUTTER_ANDROID = _flutter_platform(
    name = "android",
    target_platforms = [bazel_platform(abi) for abi in ABIS],
    constraint = Label("@platforms//os:android"),
)

_ANDROID_NATIVE_BUILD_ENV = Label("//flutter:native_build_env")

def flutter_assets(native_build_env = _ANDROID_NATIVE_BUILD_ENV, **kwargs):
    """Declares flutter_assets with the Android SDK native build environment."""
    _core_flutter_assets(native_build_env = native_build_env, **kwargs)

flutter_android_app = _flutter_android_app

flutter_plugin_deps_guards = _flutter_plugin_deps_guards
flutter_native_contribution = _flutter_native_contribution
FLUTTER_DEBUG_UNCOMPRESSED_ASSETS = _FLUTTER_DEBUG_UNCOMPRESSED_ASSETS
