# Pub plugins and generated state

For a standard Android plugin project, add the plugin to `pubspec.yaml`, run:

`bazel run @rules_flutter_core//flutter -- pub get`

Commit the updated `pubspec.lock`. Configure the rules and Android toolchains as
described in [installation](install.md), then define one
plugin hub for the pub lock in the Consumer Module's Android config. The
[pub_plugins example](../examples/pub_plugins/) shows a complete working setup.

```python
plugins = use_extension(
    "@rules_flutter_android//flutter:extensions.bzl",
    "flutter_plugins_ext",
)
plugins.project(
    name = "flutter_plugins",
    abis = ["arm64-v8a", "x86_64", "armeabi-v7a"],
    pub = "@pub",
    maven_repo = "@flutter_maven//:pin",
)
use_repo(plugins, "flutter_plugins")
```

`abis` declares native-plugin build coverage; it does not choose the APK ABIs.
Select APK ABIs with `--android_platforms` as described in
[Android apps](android-app.md).

If lower-level wiring is needed, pass both metadata labels from the same pub hub
instead of `pub`:

```python
plugins.project(
    name = "flutter_plugins",
    abis = ["arm64-v8a", "x86_64", "armeabi-v7a"],
    metadata = "@pub//:plugins_metadata.json",
    package_config = "@pub//:package_config.json",
    maven_repo = "@flutter_maven//:pin",
)
```

## Generated state and Maven wiring

A plugin graph uses two generated files:

- `plugin_deps.MODULE.bazel` is the generated Maven dependency segment.
- `lib/dart_plugin_registrant.dart` is the Dart registrant consumed by
  `flutter_core`.

Create either placeholder only if absent before the first generation. After
setting `dart_plugin_registrant` on `flutter_core`, update it before the first
build:

```sh
test -e plugin_deps.MODULE.bazel || touch plugin_deps.MODULE.bazel
test -e lib/dart_plugin_registrant.dart || touch lib/dart_plugin_registrant.dart
bazel run //<package-path>:dart_registrant_update
```

Replace `<package-path>` with the Bazel package containing the core. Commit the
generated state. Builds validate the committed Dart registrant; see
[Android app setup](android-app.md) for core configuration.

Include the generated Maven segment from the root `MODULE.bazel` after declaring
the `flutter_maven` repository mapping, replacing the plugin-free install of
that name rather than defining a second install:

```python
maven = use_extension("@rules_jvm_external//:extensions.bzl", "maven")
use_repo(maven, "flutter_maven")
include("//:plugin_deps.MODULE.bazel")
```

The segment supplies plugin and embedding coordinates and must be included in
the Android configuration fragment used by the root module. It also provides
`@flutter_plugins//maven:<artifact>` aliases for plugin dependencies, the
embedding, and `extra_artifacts`. Add other Maven artifacts needed by consumer
Android code to `extra_artifacts`. Plugin libraries compile against a
mode-correct, compile-only Flutter embedding; the hub handles it, so do not add
a second embedding `java_import` or pass an embedding target to `plugins.project`.

Load the standalone Maven guards once in the root `BUILD.bazel`:

```python
load("@rules_flutter_android//flutter:defs.bzl", "flutter_plugin_deps_guards")
flutter_plugin_deps_guards(plugins = "@flutter_plugins")
```

These targets check/update the generated segment and test consistency of the
per-project guards. Dev-only plugins are present in debug but omitted from
release; their Maven dependencies use a debug-only install and are not resolved
for release. Generated Java registrants are also mode-specific.

## Generation limits and package recipes

Automatic generation supports ordinary Java/Kotlin and CMake plugin Android
halves. It does not support `ndk-build` or prebuilt-JNI plugins. Use
`plugins.package(artifacts = [...])` when a Maven coordinate cannot be inferred,
or to replace a scraped coordinate with a fixed version. This can pin dynamic
coordinates such as `androidx.test:runner:1.2+`; dev-only pins remain in the
debug install.

The generator supplies package-scoped `BuildConfig` values for ordinary
source-built plugins, but does not evaluate Gradle `buildConfigField`
declarations. Declare custom primitive or String fields with repeated
`plugins.build_config_field` tags in the Consumer Module's plugin extension
configuration:

```python
plugins.build_config_field(
    package = "cloud_firestore",
    name = "LIBRARY_NAME",
    type = "String",
    value = "flutter-fire-fst",
)
plugins.build_config_field(
    package = "cloud_firestore",
    name = "LIBRARY_VERSION",
    type = "String",
    value_from = "package_version",
)
```

Supported types are `String`, `boolean`, `byte`, `short`, `int`, `long`, `float`,
and `double`. Strings are plain text, booleans are `true` or `false`, and
numbers are decimal literals. Specify exactly one of `value` and `value_from`;
the only supported `value_from` source is `package_version`. Build logic that
needs Gradle evaluation or arbitrary expressions belongs in a Package Recipe.

See [the demo app](../examples/demo_app/) for recipes and
the [pub plugin example](../examples/pub_plugins/) for generated plugin setup.

