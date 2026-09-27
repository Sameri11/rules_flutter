"""Supported module-extension API for Flutter Consumer Modules.

Consumers declare the expected host SDK version with the `flutter.sdk` tag.
The extension stays independent of the host SDK; version validation happens
when the local SDK repository is fetched.
"""

load("//flutter/private:ndk.bzl", _android_ndk = "android_ndk")
load("//flutter/private:plugins.bzl", _flutter_plugins_ext = "flutter_plugins_ext")
load("//flutter/private:repo.bzl", _flutter = "flutter")

# These names are the public extension API consumed by MODULE.bazel.
flutter = _flutter
android_ndk = _android_ndk
flutter_plugins_ext = _flutter_plugins_ext
