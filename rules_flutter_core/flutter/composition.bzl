"""Public building blocks for hand-wired Flutter targets."""

load("//flutter/private:core.bzl", _FlutterArtifactInfo = "FlutterArtifactInfo")
load("//flutter/private:debug_core.bzl", _flutter_debug_core = "flutter_debug_core")
load("//flutter/private:integration_test.bzl", _FlutterIntegrationTestInfo = "FlutterIntegrationTestInfo")
load("//flutter/private:pubspec.bzl", _FlutterPubspecInfo = "FlutterPubspecInfo", _flutter_pubspec = "flutter_pubspec")
load("//flutter/private:rules.bzl", _FlutterNativeBuildEnvInfo = "FlutterNativeBuildEnvInfo", _dart_test_deps = "dart_test_deps", _flutter_assets = "flutter_assets", _pub_path_deps_check = "pub_path_deps_check", _pub_plugins_check = "pub_plugins_check")

FlutterArtifactInfo = _FlutterArtifactInfo
FlutterPubspecInfo = _FlutterPubspecInfo
FlutterIntegrationTestInfo = _FlutterIntegrationTestInfo
FlutterNativeBuildEnvInfo = _FlutterNativeBuildEnvInfo
flutter_debug_core = _flutter_debug_core
flutter_pubspec = _flutter_pubspec
flutter_assets = _flutter_assets
pub_path_deps_check = _pub_path_deps_check
pub_plugins_check = _pub_plugins_check
dart_test_deps = _dart_test_deps
