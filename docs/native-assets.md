# Dart native assets

Dart build hooks can produce native libraries that are separate from Flutter's
asset bundle. For Android, a native asset library such as `.so` must be packaged
under APK `lib/<abi>/`; placing it in the Flutter asset tree is not sufficient.
Keep the native libraries and Flutter bundle as distinct Android inputs, and
retain the native-assets manifest in the bundle so Dart can resolve the asset
at runtime.

If an app or one of its dependencies contains a package-level `hook/build.dart`,
the build needs a native build environment to execute that hook. Android has no
default environment, so set it explicitly on `flutter_core`:

```python
flutter_core(
    name = "app",
    native_build_env = "@rules_flutter_android//flutter:native_build_env",
    platforms = [FLUTTER_ANDROID],
    pub = "@pub",
)
```

The [demo app BUILD file](../examples/demo_app/BUILD.bazel) shows this
configuration. The environment provides Android build tools to hooks; it does
not replace the recipe's responsibility to supply native libraries for APK
packaging.

Use a consumer-authored Package Recipe for packages that need native-asset
preparation or metadata the standard generator cannot derive. A recipe can
provide ABI-keyed libraries and native dependency metadata. The APK includes
only the ABIs selected with `--android_platforms`; recipe inputs can declare
additional ABI coverage when preparation requires it. Other packages' automatic
CMake contributions remain available.

The [demo app](../examples/demo_app/) demonstrates this with `sqlite3`, which
is not a Flutter plugin: the module declares ABI-specific library repositories,
and its recipe uses `flutter_native_contribution` to associate libraries with
Dart code assets and filenames expected by `NativeAssetsManifest`. The same
example also includes a recipe for `rive_native`. See
[plugin recipes](plugins.md#generation-limits-and-package-recipes) for recipe
registration and dependency rules, and [Android app setup](android-app.md) for
ABI selection and packaging.
