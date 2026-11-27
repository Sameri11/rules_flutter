"""Supported module-extension API for Flutter Consumer Modules.

Consumers declare the expected Flutter SDK version with the `flutter.sdk` tag.
Downloads support stable Flutter 3.47.0 or newer. Pre-release versions are not
supported. The extension checks the download minimum during evaluation and
validates the installed SDK when its repository is fetched.

Platform-specific extensions load from their owning ruleset.
"""

load("//flutter/private:pub_lock.bzl", _pub = "pub")
load("//flutter/private:sdk_pins.bzl", _flutter = "flutter_sdk_extension")

# These names are the public extension API consumed by MODULE.bazel.
flutter = _flutter
pub = _pub
