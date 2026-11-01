"""Supported BUILD-file API for the Android half of Flutter Consumer Modules.

Platform-neutral rules load from `@rules_flutter_core//flutter:defs.bzl`. This
entrypoint adds Android packaging and native contribution rules.
"""

load(
    "@rules_flutter_core//flutter:defs.bzl",
    _core_flutter_assets = "flutter_assets",
)
load("//flutter/private:android.bzl", _flutter_android_manifest = "flutter_android_manifest", _flutter_assets_dir = "flutter_assets_dir")
load("//flutter/private:android_app.bzl", _flutter_android_app = "flutter_android_app")
load("//flutter/private:android_inputs_rules.bzl", _flutter_android_inputs = "flutter_android_inputs")
load("//flutter/private:apk_check.bzl", _flutter_apk_check = "flutter_apk_check")
load("//flutter/private:recipe.bzl", _flutter_native_contribution = "flutter_native_contribution")

_ANDROID_NATIVE_BUILD_ENV = Label("//flutter:native_build_env")

def flutter_assets(native_build_env = _ANDROID_NATIVE_BUILD_ENV, **kwargs):
    """Declares flutter_assets with the Android SDK native build environment."""
    _core_flutter_assets(native_build_env = native_build_env, **kwargs)

# Explicit assignments form the curated module API.
flutter_native_contribution = _flutter_native_contribution
flutter_android_inputs = _flutter_android_inputs
flutter_apk_check = _flutter_apk_check
flutter_android_manifest = _flutter_android_manifest
flutter_assets_dir = _flutter_assets_dir
flutter_android_app = _flutter_android_app
