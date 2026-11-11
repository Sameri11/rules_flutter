"""Supported module-extension API for Flutter Consumer Modules.

Consumers declare the expected host SDK version with the `flutter.sdk` tag.
The extension stays independent of the host SDK; version validation happens
when the local SDK repository is fetched.

Platform-specific extensions load from their owning ruleset.
"""

load("//flutter/private:pub_lock.bzl", _pub = "pub")
load("//flutter/private:repo.bzl", _flutter = "flutter")

# These names are the public extension API consumed by MODULE.bazel.
flutter = _flutter
pub = _pub
