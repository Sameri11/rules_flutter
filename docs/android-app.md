# Android apps

This guide describes the current checkout API for composing Flutter artifacts
with Android Bazel rules. For installation and a standalone archive starter, see
[Installing rules_flutter](install.md); the archive example predates the current
platform descriptor API, so do not combine its files with this configuration.

## Core and Android app targets

Declare `flutter_core` once for the app package and name the Android platform
descriptor. The Android app target composes those artifacts with the native
Android app configuration. The plugin-free example
[`examples/no_plugins`](../examples/no_plugins/) has the complete current
configuration, including the module setup.

At the package root, load `FLUTTER_ANDROID` and `flutter_core` and configure the
platform explicitly:

```python
load("@rules_flutter_android//flutter:defs.bzl", "FLUTTER_ANDROID")
load("@rules_flutter_core//flutter:defs.bzl", "flutter_core")

flutter_core(
    name = "core",
    assets = [],
    platforms = [FLUTTER_ANDROID],
    pub = "@pub",
    visibility = ["//android/app:__pkg__"],
)
```

When production sources include a staged `hook/build.dart`, set
`native_build_env = "@rules_flutter_android//flutter:native_build_env"` on
`flutter_core`. The Android descriptor supplies no native build environment by
default. See [Native assets](native-assets.md) for build hooks and recipes.

For an existing Android project, preserve its manifest and source layout. In
`android/app/BUILD.bazel`, define the app target with
`flutter_android_app`, point it at `//:core`, provide the app's
`applicationId` through `manifest_values`, and wire the existing `MainActivity`
source as an Android library dependency. The
[`examples/no_plugins/android/app/BUILD.bazel`](../examples/no_plugins/android/app/BUILD.bazel)
file is the concrete configuration: it defines `flutter_android_inputs`, passes
that target as `inputs` to the app rule, and has the native activity depend on
`:no_plugins_inputs`.

An app with no pub plugins can set `plugins = None` on `flutter_android_inputs`.
For plugin resolution and package-specific Android wiring, see
[Plugins](plugins.md). Consumers own their Maven dependency installation; do
not copy a generated Maven classpath from an example. See
[Android builds](android-builds.md) for release/debug modes and ABI selection.

## Hand-wired packaging

The convenience Android app rule is optional. A consumer can compose the core
output groups with stock Android rules, such as `android_binary`, when it needs
its own packaging graph. The checked
[`tests/consumer/hand_wired_app`](../tests/consumer/hand_wired_app/BUILD.bazel)
fixture illustrates plugin, Java, and Maven wiring; it is not a complete APK.
For a composed APK example, see
[`tests/consumer/composed_app`](../tests/consumer/composed_app/).

The core output groups `flutter_assets` and `flutter_aot` (empty in debug mode)
are available to hand-wired consumers. Android engine libraries and embedding
are owned by the Android ruleset. Use its public targets and helpers rather than
reconstructing or copying generated dependency lists.

## Existing app configuration notes

- Keep `MainActivity` in the Android app's native source graph and declare its
  source explicitly in the Bazel target.
- Use one `flutter_core` declaration per app package; host tests can share it.
- Keep `pubspec.lock` committed and declare consumer path dependencies through
  `path_deps`.
- The app's Android SDK/NDK toolchains, Maven graph, and Flutter/pub setup belong
  to the consumer module. See [installation](install.md).
- The Android backend is the only implemented app platform. Signing release
  APKs is outside Bazel; see [compatibility](compatibility.md).
