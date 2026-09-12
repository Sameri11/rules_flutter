"""Supported module-extension API for Flutter Consumer Modules.

Consumer Modules load this entrypoint, not ``//tools/flutter``. SDK/engine
provisioning stays private because it supplies the Ruleset Module's tool inputs.
"""

load("//tools/flutter:ndk.bzl", _android_ndk = "android_ndk")
load("//tools/flutter:plugins.bzl", _flutter_plugins_ext = "flutter_plugins_ext")

# Assigning these names re-exports them to downstream MODULE files.
android_ndk = _android_ndk
flutter_plugins_ext = _flutter_plugins_ext
