"""Supported module-extension API for Flutter Consumer Modules.

Consumers declare the expected Flutter SDK version with the `flutter.sdk` tag.
Downloads support stable Flutter 3.47.0 or newer. The extension validates the
declared version during evaluation and assembles its repositories lazily.

Platform-specific extensions load from their owning ruleset.
"""

load("//flutter/private:pub_lock.bzl", _pub = "pub")
load("//flutter/private:sdk_pins.bzl", _flutter = "flutter_sdk_extension")

# These names are the public extension API consumed by MODULE.bazel.
flutter = _flutter
pub = _pub
