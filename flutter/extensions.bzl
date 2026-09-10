"""The supported module-extension API for Flutter Consumer Modules.

Consumer Modules load this entrypoint rather than implementation-oriented files
under ``//tools/flutter``. The Flutter SDK/engine provisioning extension remains
private to the Ruleset Module because it supplies the rules' own tool inputs.
"""

load("//tools/flutter:ndk.bzl", _android_ndk = "android_ndk")
load("//tools/flutter:plugins.bzl", _flutter_plugins_ext = "flutter_plugins_ext")

# Explicit assignments make the curated names exports of this module. Merely
# importing names with load() does not re-export them to downstream MODULE files.
android_ndk = _android_ndk
flutter_plugins_ext = _flutter_plugins_ext
