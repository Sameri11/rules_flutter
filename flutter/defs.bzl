"""Supported BUILD-file API for Flutter Consumer Modules.

Consumer BUILD files load this one entrypoint rather than the implementation
under ``//flutter/private``. The public names below are the complete contract
exercised by the consumer API fixture; implementation files can move without
another consumer migration.
"""

load("//flutter/private:abis.bzl", _ABIS = "ABIS")
load(
    "//flutter/private:android.bzl",
    _android_native_lib_jar = "android_native_lib_jar",
    _flutter_android_binary = "flutter_android_binary",
    _flutter_android_libs = "flutter_android_libs",
    _jni_lib_jar = "jni_lib_jar",
    _strip_native_libs = "strip_native_libs",
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
    _dart_kernel = "dart_kernel",
    _flutter_aot_library = "flutter_aot_library",
    _flutter_app = "flutter_app",
    _flutter_assets = "flutter_assets",
    _pub_path_deps_check = "pub_path_deps_check",
    _pub_plugins_check = "pub_plugins_check",
)

# Explicit assignments make the curated names exports of this module. Merely
# importing names with load() does not re-export them to downstream BUILD files.
ABIS = _ABIS
android_native_lib_jar = _android_native_lib_jar
dart_kernel = _dart_kernel
flutter_android_binary = _flutter_android_binary
flutter_android_libs = _flutter_android_libs
flutter_aot_library = _flutter_aot_library
flutter_app = _flutter_app
flutter_assets = _flutter_assets
flutter_embedding_library = _flutter_embedding_library
flutter_native_contribution = _flutter_native_contribution
flutter_native_libs = _flutter_native_libs
flutter_pubspec = _flutter_pubspec
jni_lib_jar = _jni_lib_jar
pub_path_deps_check = _pub_path_deps_check
pub_plugins_check = _pub_plugins_check
strip_native_libs = _strip_native_libs
