"""Supported module-extension API for Flutter Consumer Modules.

Consumer Modules load this entrypoint rather than the implementation under
``//flutter/private``. The Flutter SDK/engine provisioning extension stays
private to the Ruleset Module because it supplies the rules' own tool inputs.
"""

load("//flutter/private:ndk.bzl", _android_ndk = "android_ndk")
load("//flutter/private:plugins.bzl", _flutter_plugins_ext = "flutter_plugins_ext")

# Assigning these names re-exports them to downstream MODULE files.
android_ndk = _android_ndk
flutter_plugins_ext = _flutter_plugins_ext
