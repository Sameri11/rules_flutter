"""Supported module-extension API for the Android half of Flutter Consumer Modules.

The `flutter` and `pub` extensions load from
`@rules_flutter_core//flutter:extensions.bzl`. Consumers declare the expected
host SDK version with the `flutter.sdk` tag there.
"""

load("//flutter/private:ndk.bzl", _android_ndk = "android_ndk")
load("//flutter/private:plugins.bzl", _flutter_plugins_ext = "flutter_plugins_ext")

# These names are the public extension API consumed by MODULE.bazel.
android_ndk = _android_ndk
flutter_plugins_ext = _flutter_plugins_ext
