# rules_flutter consumer quickstart

This guide is for an Android Flutter application built directly by Bazel. Read the
[README](README.md) for the rationale and current limitations; use this guide to
choose a consumer layout and create the files it needs.

## Choose a shape first

| Shape | Use it when | Canonical example |
| --- | --- | --- |
| Plugin-free root app | The Flutter app is at the module root and has no Android plugin graph. | [`examples/no_plugins`](examples/no_plugins/) |
| Root app with pub plugins | The app is at the module root and pub resolves one or more Flutter plugins. | [`examples/pub_plugins`](examples/pub_plugins/) |
| Monorepo app with a local path plugin | The Bazel module is a monorepo, the app is in a subpackage, and a `path:` dependency is a Flutter plugin. | [`examples/local_plugin`](examples/local_plugin/) |
| Consumer recipes and native assets | A package cannot be described by the standard generator, such as a plugin that downloads native libraries or a Dart native-asset package. | [`examples/demo_app`](examples/demo_app/) |

Start with the smallest matching shape. A normal CMake Android plugin belongs in
**Root app with pub plugins**; it is generated automatically. Recipes are for a
package the normal graph cannot describe, not a replacement for the normal
plugin setup.

## Common prerequisites and conventions

### Versions and local tools

The supported, verified toolchain is:

| Tool | Required version or setup | Why it is load-bearing |
| --- | --- | --- |
| Flutter SDK | Flutter **3.44.2** / Dart **3.12.2** | The rules invoke this SDK's frontend server, `gen_snapshot`, and bundle tooling. |
| Bazel | **9.2.0** (Bazelisk recommended) | The module extension and generated repositories use Bzlmod. |
| Android SDK | A recent SDK with `ANDROID_HOME` set | `rules_android` discovers Android build tools and `aapt2` through it. |
| Android NDK | **28 or newer** with `ANDROID_NDK_HOME` set | NDK 28+ produces native libraries usable on 16 KB-page Android devices. |

Either set `FLUTTER_ROOT` or put `flutter` on `PATH`; set the Android locations
before building an APK:

```sh
export FLUTTER_ROOT=/path/to/flutter-3.44.2
export PATH="$FLUTTER_ROOT/bin:$PATH"
export ANDROID_HOME="$HOME/Library/Android/sdk"
export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/<your 28+ version>"
```

`flutter pub get` is required before the first Bazel build and after every pub
change. It creates `.dart_tool/package_config.json`, which the Dart compiler
uses; it also refreshes `.flutter-plugins-dependencies` and Flutter's Android
registrant when a plugin graph exists. Skipping it usually fails with an
otherwise unhelpful missing-file error.

Until `rules_flutter` is published to the Bazel Central Registry, create a
consumer as a sibling of a checkout and retain a development override:

```python
bazel_dep(name = "rules_flutter", version = "0.1.0")
local_path_override(
    module_name = "rules_flutter",
    path = "../rules_flutter",
)
```

The `path = "../.."` spelling in the canonical examples is specific to their
location two levels below this checkout. An outside sibling consumer normally
uses `path = "../rules_flutter"`; change the path only to match your layout.

Pin Bazel with `.bazelversion`:

```
9.2.0
```

Use this complete `.bazelrc` in an outside consumer (the examples import the
```
common --enable_bzlmod

build:android --merge_android_manifest_permissions
build:android --tool_java_language_version=17 --tool_java_runtime_version=remotejdk_17
build:android --java_language_version=17 --java_runtime_version=remotejdk_17
common --config=android
```

The Android configuration enables the Android toolchain, uses the JDK 17 toolchain required by `rules_android`, and preserves permissions declared by plugin manifests. The rules provide their own JDK 17; no local JDK selection is needed. The `ANDROID_NDK_HOME` environment variable will be read at repository-fetch time when a target requires Android toolchains; if unset, the repository fetch will fail with a diagnostic naming the variable and the NDK path requirement.

### Generated state, assets, labels, and ABIs

- Add `/bazel-*` to the Flutter-generated `.gitignore`; do **not** ignore
  `MODULE.bazel.lock`. Commit the lockfile. It is machine-independent: the NDK
  module extension records no NDK path, so the same lock bytes are produced with
  `ANDROID_NDK_HOME` set or unset. In a plugin graph, also commit the generated
  `plugin_deps.MODULE.bazel` and `lib/dart_plugin_registrant.dart`. Their guards
  intentionally fail when pub state changes.
- If the project declares no assets, set `assets = []` in `flutter_app()`: the
  default `glob(["assets/**"])` deliberately rejects an empty directory. Once
  the app declares files under `assets/` in `pubspec.yaml`, omit that override
  (or provide the matching asset inputs).
- `abis` is explicit everywhere. Use the same ordered list in
  `plugins.project()`, `flutter_app()`, and `flutter_android_binary()`. Supported
  Android ABI names are `arm64-v8a`, `x86_64`, and `armeabi-v7a`.
- A Flutter app at the module root must be named `app = "//:app"` in
  `flutter_android_binary()`. `app = "//"` has no target name and is invalid.
  An app in a named package can use its package label, for example
  `app = "//packages/host_app"`.

## Plugin-free root app

Use this shape for a flat Android Flutter project with no Android plugin graph.
The complete working fixture is
[`examples/no_plugins`](examples/no_plugins/).

### Prepare the project

From the existing Flutter project root, populate the pub-generated state that
the Bazel build consumes:

```sh
flutter pub get
```

The module root should contain `pubspec.yaml`, `lib/`, and `android/`.
Flutter also writes an empty
`android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java`;
compile it even though this app has no plugins so the engine does not report a
misleading missing-registrant message.

### Add the module and Dart target

After adding the common `.bazelversion` and `.bazelrc` above, create this root
`MODULE.bazel`. The Maven install is required even without plugins because the
Flutter embedding depends on AndroidX.

```python
module(name = "hello_bazel", version = "0.0.1")

bazel_dep(name = "rules_flutter", version = "0.1.0")
local_path_override(
    module_name = "rules_flutter",
    path = "../rules_flutter",
)

bazel_dep(name = "rules_android", version = "0.7.3")
bazel_dep(name = "rules_kotlin", version = "2.4.0")
bazel_dep(name = "rules_jvm_external", version = "7.1")

# Android toolchains are owned by this Consumer Module.
android_sdk = use_extension(
    "@rules_android//rules/android_sdk_repository:rule.bzl",
    "android_sdk_repository_extension",
)
android_sdk.configure(
    api_level = 36,
    build_tools_version = "36.0.0",
)
use_repo(android_sdk, "androidsdk")
register_toolchains("@androidsdk//:all")

android_ndk = use_extension("@rules_flutter//tools/flutter:ndk.bzl", "android_ndk")
use_repo(android_ndk, "androidndk", "androidndk_cmake")
register_toolchains("@androidndk//:all")

maven = use_extension("@rules_jvm_external//:extensions.bzl", "maven")
maven.install(
    name = "flutter_maven",
    artifacts = [
        "androidx.lifecycle:lifecycle-common:2.7.0",
        "androidx.lifecycle:lifecycle-common-java8:2.7.0",
        "androidx.lifecycle:lifecycle-process:2.7.0",
        "androidx.lifecycle:lifecycle-runtime:2.7.0",
        "androidx.fragment:fragment:1.7.1",
        "androidx.annotation:annotation:1.8.1",
        "androidx.tracing:tracing:1.2.0",
        "androidx.core:core:1.13.1",
        "androidx.window:window-java:1.2.0",
        "androidx.window:window:1.2.0",
        "androidx.exifinterface:exifinterface:1.4.1",
        "com.getkeepsafe.relinker:relinker:1.4.5",
    ],
    repositories = ["https://maven.google.com", "https://repo1.maven.org/maven2"],
    version_conflict_policy = "pinned",
)
use_repo(maven, "flutter_maven")
```

Create the root `BUILD.bazel`. This walkthrough intentionally builds both an
arm64 device slice and an x86_64 emulator slice; use one identical list in all
three locations if you choose a different supported set.

```python
load("@rules_flutter//tools/flutter:defs.bzl", "flutter_app")

package(default_visibility = ["//visibility:public"])

flutter_app(
    abis = ["arm64-v8a", "x86_64"],
    plugin_deps = None,
    assets = [],
)
```

`plugin_deps = None` is the deliberate no-plugin-graph opt-out. It removes the
plugin repository and generated registrant guards; it is not appropriate once
the app has a pub or path plugin.

### Add the Android target

Find Flutter's generated activity path first; the organization and project name
control it:

```sh
find android/app/src/main/kotlin -name MainActivity.kt
```

Create `android/app/BUILD.bazel`, replacing the application ID and Kotlin source
path with the ones Flutter generated for your app:

```python
load("@rules_android//rules:rules.bzl", "android_library")
load("@rules_flutter//tools/flutter:android.bzl", "flutter_android_binary")
load("@rules_flutter//tools/flutter:embedding.bzl", "flutter_embedding_library")
load("@rules_kotlin//kotlin:android.bzl", "kt_android_library")

package(default_visibility = ["//visibility:public"])

flutter_embedding_library(name = "flutter_embedding")

flutter_android_binary(
    name = "hello_bazel",
    abis = ["arm64-v8a", "x86_64"],
    app = "//:app",
    manifest_values = {"applicationId": "com.example.hello_bazel"},
    plugins = None,
    registrant = ":generated_plugin_registrant",
    deps = [":main_activity"],
)

android_library(
    name = "generated_plugin_registrant",
    srcs = ["src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java"],
    deps = [
        ":flutter_embedding",
        "@flutter_maven//:androidx_annotation_annotation_jvm",
    ],
)

kt_android_library(
    name = "main_activity",
    srcs = ["src/main/kotlin/com/example/hello_bazel/MainActivity.kt"],
    deps = [":flutter_embedding"],
)
```

The explicit annotation dependency is needed because the embedding's imported
Java dependencies are not re-exported to this registrant's compile classpath.

### Build, install, and run

Release is the default mode. The APK target already depends on the Dart/AOT and
asset targets, so Bazel builds them transitively:

```sh
export ANDROID_HOME="$HOME/Library/Android/sdk"
export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/<your 28+ version>"
bazel build //android/app:hello_bazel
ls bazel-bin/android/app/
adb install -r bazel-bin/android/app/<name>.apk
bazel test //:guards_test
```

Use the name discovered under `bazel-bin/android/app/` instead of guessing an
APK filename. Open the installed app on the emulator or device; a fresh project
should show Flutter's counter application and respond to its button. A green
build does not prove that the APK launches.

To build the debug-shaped APK, select debug mode on the APK target:

```sh
bazel build //android/app:hello_bazel --@rules_flutter//tools/flutter:mode=debug
```

#### Hot reload with `flutter run`

The preferred development path is to let `flutter run` install the Bazel-built
debug APK, launch it, and attach the Flutter tool in one command. Supplying the
prebuilt APK prevents Flutter from invoking Gradle:

```sh
flutter devices
flutter run -d <device-id> --debug \
  --use-application-binary=bazel-bin/android/app/hello_bazel.apk
```

Run the command from the Flutter project root and replace the APK path with the
actual Bazel output. While attached, press `r` for hot reload, `R` for hot
restart, and `q` to stop. Hot reload applies Dart source changes; rebuild the
Bazel APK and run the command again after changing assets, native/plugin code,
dependencies, manifests, or other packaging inputs.

For a separately managed application process, use
`flutter install --use-application-binary`, then `flutter attach`. Direct
`adb install`/launch followed by `flutter attach` is the lower-level fallback;
neither is the normal development path.

Do not select debug mode for `//:app_arm64-v8a`: that is an AOT target and is
release-only.

| Symptom | Fix |
| --- | --- |
| `no such target '@androidsdk//:aapt2'` | Set `ANDROID_HOME` to the Android SDK before the Android build. |
| An empty `assets/` glob fails in a new app | Keep `assets = []` until `pubspec.yaml` declares real asset files. |
| An error refers to an invalid empty target name | Use `app = "//:app"`, never `app = "//"`, for a root app. |
| Package config, plugin metadata, or registrant files are absent | Run `flutter pub get` from the Flutter project root. |

## Root app with pub plugins

Use this shape when the flat root app gains a pub plugin. The canonical
working fixture is [`examples/pub_plugins`](examples/pub_plugins/); the steps
below contain the complete first-plugin transition.
The fixture's one-ABI APK label is `//android/app:pub_plugins`; the transition
below uses `hello_bazel` as a placeholder, so substitute your own Android target
name consistently.

### Add and exercise `path_provider`

Starting from the plugin-free root app, add this under `dependencies:` in
`pubspec.yaml` and regenerate pub state:

```yaml
  path_provider: ^2.1.6
```

```sh
flutter pub get
grep -A3 '"android"' .flutter-plugins-dependencies
```

`path_provider` resolves `path_provider_android`, whose Android module is the
native plugin part that the generator reads. Do not stop at registration: call
it from the application and display or log the resulting path. For example,
add the import and invoke `_checkDocumentsDirectory()` from a state object's
`initState()`:

```dart
import 'package:path_provider/path_provider.dart';

String _documentsDirectory = 'pending';

@override
void initState() {
  super.initState();
  _checkDocumentsDirectory();
}

Future<void> _checkDocumentsDirectory() async {
  try {
    final directory = await getApplicationDocumentsDirectory();
    if (mounted) {
      setState(() => _documentsDirectory = directory.path);
    }
  } catch (error) {
    if (mounted) {
      setState(() => _documentsDirectory = 'failed: $error');
    }
  }
}
```

This is the runtime assertion: after installation it must resolve a directory,
not report `MissingPluginException`.

### Seed generated state before changing the module graph

The ordering is required. First create the Dart registrant placeholder, but do
**not** create an empty `plugin_deps.MODULE.bazel`:

```sh
touch lib/dart_plugin_registrant.dart
# NOT `touch plugin_deps.MODULE.bazel`.
```

Move the complete `maven = use_extension(...)` through
`use_repo(maven, "flutter_maven")` block from the plugin-free `MODULE.bazel`
above into `plugin_deps.MODULE.bazel` unchanged. It is a valid seed for the
module include; an empty included file does not create `@flutter_maven`, so
`plugins.project(maven_repo = "@flutter_maven//:pin")` cannot resolve.

Then remove that Maven block from `MODULE.bazel` and replace it with the real
plugin graph. Keep the module declaration, `rules_flutter` override, and three
direct Bazel dependencies unchanged.

```python
plugins = use_extension("@rules_flutter//tools/flutter:plugins.bzl", "flutter_plugins_ext")
plugins.project(
    abis = ["arm64-v8a", "x86_64"],
    metadata = "//:.flutter-plugins-dependencies",
    embedding = "//android/app:flutter_embedding",
    maven_repo = "@flutter_maven//:pin",
)
use_repo(plugins, "flutter_plugins")

include("//:plugin_deps.MODULE.bazel")
```

`use_repo` makes the generated per-package targets and
`@flutter_plugins//:all` visible. `include` creates the one Maven repository in
the consumer module. They are different, and both are required.

### Turn on the Dart and Android plugin graph

In the root `BUILD.bazel`, remove `plugin_deps = None` so the conventional
committed plugin files and guards become active:

```python
flutter_app(
    abis = ["arm64-v8a", "x86_64"],
    assets = [],
)
```

Apply that change in the same edit as the module extension above: enabling the
Dart guard without creating `@flutter_plugins` leaves its expected file
unresolvable.

In `android/app/BUILD.bazel`, retain the existing imports, embedding, and
`main_activity`, then replace the opt-out Android setup with the plugin-aware
form. Find the fixed Flutter-generated registrant source before writing the target:

```sh
find android/app/src/main/java -name GeneratedPluginRegistrant.java
```

The generated Android registrant needs both the generated plugin aggregate and
the annotation JAR:

```python
PLUGINS = ["@flutter_plugins//:all"]

flutter_android_binary(
    name = "hello_bazel",
    abis = ["arm64-v8a", "x86_64"],
    app = "//:app",
    manifest_values = {"applicationId": "com.example.hello_bazel"},
    deps = [":main_activity"],
)

android_library(
    name = "generated_plugin_registrant",
    srcs = ["src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java"],
    deps = PLUGINS + [
        ":flutter_embedding",
        "@flutter_maven//:androidx_annotation_annotation_jvm",
    ],
)
```

Do not pass `plugins = None` or the explicit empty-graph `registrant` argument
in this shape. With a graph, `flutter_android_binary` derives the conventional
registrant target.

### Generate, commit, build, and prove the transition

Use the guards' generated outputs rather than hand-editing either committed
file. The first guard fails against the seed by design; copy its expected file
from the generated repository:

```sh
bazel build //:plugins_check
cp "$(bazel info output_base)/$(bazel cquery --output=files @flutter_plugins//:plugin_deps.MODULE.bazel)" plugin_deps.MODULE.bazel
bazel build //:plugins_check

bazel build //:dart_registrant_check
cp "$(bazel info output_base)/$(bazel cquery --output=files @flutter_plugins//:dart_plugin_registrant.dart)" lib/dart_plugin_registrant.dart
bazel build //:dart_registrant_check
bazel test //:guards_test
```

Commit `plugin_deps.MODULE.bazel` and `lib/dart_plugin_registrant.dart`. Then
build and install the APK:

```sh
export ANDROID_HOME="$HOME/Library/Android/sdk"
export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/28.2.13676358"
bazel build //android/app:hello_bazel
adb install -r bazel-bin/android/app/hello_bazel.apk
```

Launch the app and make the `path_provider` call. It should return the
application documents directory without throwing `MissingPluginException`.
If the app opens but the call throws that exception, the APK build and install
succeeded but plugin registration is stale or missing; refresh the generated
registrants and rebuild.

For every later pub plugin addition, removal, or upgrade, run `flutter pub get`.
Flutter refreshes `GeneratedPluginRegistrant.java`; keep its BUILD target dependent
on `@flutter_plugins//:all`, rather than maintaining a per-plugin Bazel list.
Rerun the two guards, copy their generated outputs when they drift, commit them,
rebuild, install, and exercise the changed plugin. Standard CMake-backed plugins
are generated automatically. If a plugin's Maven coordinate cannot be read statically,
declare it on that package instead of adding a second Maven install:

```python
plugins.package(
    name = "audioplayers_android",
    artifacts = [
        "org.jetbrains.kotlinx:kotlinx-coroutines-core:1.6.4",
    ],
)
```

`artifacts` contributes to the single generated `flutter_maven` install; it is
not a recipe for Gradle behavior.

## Monorepo app with a local path plugin

[`examples/local_plugin`](examples/local_plugin/) is a monorepo: the module
root is the repository root, the Flutter app is `packages/host_app`, and the
local plugin is `packages/greeter`.

```text
MODULE.bazel
plugin_deps.MODULE.bazel
packages/
  host_app/
    pubspec.yaml
    BUILD.bazel
    android/app/BUILD.bazel
  greeter/
    pubspec.yaml
    BUILD.bazel
    lib/
```

From `packages/host_app`, declare and resolve the path dependency:

```yaml
dependencies:
  greeter:
    path: ../greeter
```

```sh
cd packages/host_app
flutter pub get
cd ../..
```

Before enabling `plugins.project()`, bootstrap the two committed generated-state
files. From the module root, create the Dart placeholder but do **not** create an
empty Maven segment:

```sh
touch packages/host_app/lib/dart_plugin_registrant.dart
# NOT `touch plugin_deps.MODULE.bazel`.
```

Seed the root `plugin_deps.MODULE.bazel` by moving the complete
`maven = use_extension(...)` through `use_repo(maven, "flutter_maven")` block
from the plugin-free module above into that file, unchanged. This valid seed
makes `@flutter_maven//:pin` available while `plugins.project()` is evaluated.

At the **module root**, use the local-plugin module pattern. `embedding` and
`metadata` name the app subpackage, while the generated Maven segment remains
beside the root `MODULE.bazel` because `include()` is evaluated there.

```python
module(
    name = "local_plugin",
    version = "0.0.1",
)

bazel_dep(name = "rules_flutter", version = "0.1.0")
local_path_override(
    module_name = "rules_flutter",
    path = "../..",
)

bazel_dep(name = "rules_android", version = "0.7.3")
bazel_dep(name = "rules_kotlin", version = "2.4.0")
bazel_dep(name = "rules_jvm_external", version = "7.1")

# Android toolchains are owned by this Consumer Module.
android_sdk = use_extension(
    "@rules_android//rules/android_sdk_repository:rule.bzl",
    "android_sdk_repository_extension",
)
android_sdk.configure(
    api_level = 36,
    build_tools_version = "36.0.0",
)
use_repo(android_sdk, "androidsdk")
register_toolchains("@androidsdk//:all")

android_ndk = use_extension("@rules_flutter//tools/flutter:ndk.bzl", "android_ndk")
use_repo(android_ndk, "androidndk", "androidndk_cmake")
register_toolchains("@androidndk//:all")

plugins = use_extension("@rules_flutter//tools/flutter:plugins.bzl", "flutter_plugins_ext")
plugins.project(
    abis = ["arm64-v8a"],
    embedding = "//packages/host_app/android/app:flutter_embedding",
    maven_repo = "@flutter_maven//:pin",
    metadata = "//packages/host_app:.flutter-plugins-dependencies",
)
use_repo(plugins, "flutter_plugins")

include("//:plugin_deps.MODULE.bazel")
```

The root needs a Bazel package solely so it can export the included generated
segment:

```python
package(default_visibility = ["//visibility:public"])
exports_files(["plugin_deps.MODULE.bazel"])
```

The app's `packages/host_app/BUILD.bazel` declares the Dart sources of the
local path dependency. Pub locks do not hash the changing content of a `path:`
dependency, so omitting `path_deps` would leave an undeclared input and make the
path-dependency guard fail.

```python
load("@rules_flutter//tools/flutter:defs.bzl", "flutter_app")

package(default_visibility = ["//visibility:public"])

flutter_app(
    abis = ["arm64-v8a"],
    assets = [],
    path_deps = ["//packages/greeter:srcs"],
    plugin_deps = "//:plugin_deps.MODULE.bazel",
)
```

Give the local plugin a `packages/greeter/BUILD.bazel` filegroup for that
Dart-side declaration:

```python
package(default_visibility = ["//visibility:public"])

filegroup(
    name = "srcs",
    srcs = glob(["lib/**/*.dart"]) + ["pubspec.yaml"],
)
```

There is intentionally no separate hand-written Android target inside
`packages/greeter`. `flutter pub get` records the plugin's absolute path in
`packages/host_app/.flutter-plugins-dependencies`; the generator stages that
package and builds its Android half in `@flutter_plugins`, just as it would for
a pub plugin.

The app Android target uses named-package labels, and its generated registrant
depends on the plugin aggregate:

```python
flutter_embedding_library(name = "flutter_embedding")

flutter_android_binary(
    name = "host_app",
    abis = ["arm64-v8a"],
    app = "//packages/host_app",
    manifest_values = {"applicationId": "com.example.host_app"},
    deps = [":main_activity"],
)

android_library(
    name = "generated_plugin_registrant",
    srcs = ["src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java"],
    deps = [
        ":flutter_embedding",
        "@flutter_maven//:androidx_annotation_annotation_jvm",
        "@flutter_plugins//:all",
    ],
)
```

Retain the imports and `kt_android_library(name = "main_activity", ...)` from
the generated Android app; the canonical full file is
[`packages/host_app/android/app/BUILD.bazel`](examples/local_plugin/packages/host_app/android/app/BUILD.bazel).

Generate the root Maven segment and the app's Dart registrant through their
guards; the first build is expected to fail against the seed and print the
expected generated content:

```sh
bazel build //packages/host_app:plugins_check
cp "$(bazel info output_base)/$(bazel cquery --output=files @flutter_plugins//:plugin_deps.MODULE.bazel)" plugin_deps.MODULE.bazel
bazel build //packages/host_app:plugins_check

bazel build //packages/host_app:dart_registrant_check
cp "$(bazel info output_base)/$(bazel cquery --output=files @flutter_plugins//:dart_plugin_registrant.dart)" packages/host_app/lib/dart_plugin_registrant.dart
bazel build //packages/host_app:dart_registrant_check
bazel test //packages/host_app:guards_test
bazel build //packages/host_app/android/app:host_app
```

Adapt all three label families together when your layout differs:
`metadata = "//<app-package>:.flutter-plugins-dependencies"`,
`embedding = "//<app-package>/android/app:flutter_embedding"`,
`path_deps = ["//<plugin-package>:srcs"]`, and
`app = "//<app-package>"`. Keep the generated Maven segment at the module root
unless the module itself moves.

## Consumer recipes and native assets

Use a recipe only after normal plugin generation either refuses a package or
cannot see it. Two examples in [`examples/demo_app`](examples/demo_app/) show
the supported boundaries:

- `rive_native` has an ordinary Kotlin Android module, but its Gradle task
  downloads `librive_native.so`; no Gradle task runs here.
- `sqlite3` is not a Flutter Android plugin at all. Its Dart build hook chooses
  and obtains a native asset, so it is absent from the standard Android plugin
  metadata.

`ndk-build` plugins and third-party Gradle plugins remain unsupported. A recipe
does not run Gradle or `ndk-build`; it must replace the missing native build
with declared Bazel inputs and targets.

### The two supported entry points

Add these tags to `MODULE.bazel` through the same `plugins` extension, after
`plugins.project(...)` and before `use_repo(plugins, "flutter_plugins")`.

For a Maven coordinate the scraper cannot recover, add the coordinate to the
package tag so it becomes part of the one generated Maven install:

```python
plugins.package(
    name = "audioplayers_android",
    artifacts = [
        "org.jetbrains.kotlinx:kotlinx-coroutines-core:1.6.4",
    ],
)
```

For a replacement build, give the package a consumer-owned `.bzl` recipe:

```python
plugins.package(
    name = "rive_native",
    bzl_file = "//bazel/flutter:rive_native.bzl",
    macro = "rive_native_recipe",
)
plugins.package(
    name = "sqlite3",
    bzl_file = "//bazel/flutter:sqlite3.bzl",
    macro = "sqlite3_recipe",
)
```

The package name remains the generated target identity: consumers still depend
on `@flutter_plugins//rive_native` or `@flutter_plugins//sqlite3`. A recipe must
also define `<name>_flutter_native`; the generated aggregate consumes it and
fails at analysis if it is absent.

### Recipe contract and failure signals

The configured macro is called as `macro(name, info)`. The generated `info`
struct contains the pub package name, whether it is a Flutter plugin, every
staged file, classified Android sources/resources/manifest, namespace, Maven
coordinates and repository, plugin dependencies, generator reason codes,
requested ABIs, API level, and embedding label. Prefer the classified fields;
use `info.all_files` when the standard classifier omitted or misbucketed a
source.

The macro must define the conventional package target named `name` and a
`flutter_native_contribution` target named `name + "_flutter_native"`. The
native contribution maps every requested ABI to its pinned library. A package
that intentionally contributes no native library must say
`empty = True`; an accidental empty contribution fails analysis. For Dart
native assets, every `code_assets` value must exactly match a contributed
library filename.

| Failure | Meaning and fix |
| --- | --- |
| The package name is absent from both plugin metadata and the pub package configuration | Use the exact pub package name and rerun `flutter pub get`. |
| The generator repeats its gated reason and asks for a recipe | Register `plugins.package(name = ..., bzl_file = ..., macro = ...)` for that package. |
| The recipe macro or conventional package target cannot be loaded | Match `macro` to the exported function and create the target named by the supplied `name`. |
| `<name>_flutter_native` is missing | Define `flutter_native_contribution(name = name + "_flutter_native", ...)`; the generated aggregate consumes that exact target. |
| The contribution is empty | Supply the missing libraries, or set `empty = True` only when no runtime library is intentionally required. |
| A requested ABI has no library | Pin an input and add a mapping for every ABI listed in `plugins.project()`, `flutter_app()`, and `flutter_android_binary()`. |
| A declared code asset names an uncontributed file | Make `code_assets` use the exact filename from `NativeAssetsManifest.json` and contribute that library. |
| `<apk>_flutter_check` reports a missing code asset | Do not bypass the guard: the Dart VM would try to load a library absent from `lib/<abi>/`; fix the package recipe. |

Recipe macros cannot fetch network inputs. Declare downloads with `http_file`,
`http_archive`, or another repository rule in `MODULE.bazel`, with hashes, then
refer to them through `Label()` from the recipe.

### Declare pinned inputs in the consumer module

Downloads are module-time declarations owned and pinned by the application, not
network calls hidden in a recipe. For the complete three-ABI checksum and
archive declarations, copy the current
[`examples/demo_app/MODULE.bazel`](examples/demo_app/MODULE.bazel) entries when
your ABI list changes. The following arm64 entries are the runnable single-ABI
form of those declarations:

```python
http_file = use_repo_rule("@bazel_tools//tools/build_defs/repo:http.bzl", "http_file")
http_file(
    name = "libsqlite3_android_arm64_v8a",
    downloaded_file_path = "libsqlite3.so",
    sha256 = "e99515af1d7119fb61843ae5e597344e7f258563de3a7e5a3869f627aab2887b",
    urls = ["https://github.com/simolus3/sqlite3.dart/releases/download/" +
            "sqlite3-3.5.0/libsqlite3.arm64.android.so"],
)

http_archive = use_repo_rule("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")
http_archive(
    name = "rive_native_android",
    build_file_content = """
filegroup(
    name = "arm64_v8a",
    srcs = ["arm64-v8a/librive_native.so"],
    visibility = ["//visibility:public"],
)
""",
    sha256 = "765a4e5e7e244eb849c76af105d5dc9a33fa02401cd37e6f24720d8c8941498b",
    urls = ["https://rive-flutter-artifacts.rive.app/rive_native_versions/" +
            "0.1.10%2B2/rive_native_artifacts_android.zip"],
)
```

For multiple ABIs, declare one `sqlite3` `http_file` per ABI with the matching
published file, checksum, and repository name from the canonical module; keep
the `rive_native` archive's requested filegroups in step with the same list.

### Write recipes with consumer repository labels

Export recipe files from `bazel/flutter/BUILD.bazel`, as in the
[canonical recipe directory](examples/demo_app/bazel/flutter/). Use `Label()`
for every repository reference: a recipe is loaded from a generated repository,
whose apparent-name mapping is not the consumer's mapping. `Label()` resolves
the consumer's declared repository while the recipe file is loaded.

A concise arm64 `rive_native` recipe is:

```python
load("@rules_flutter//tools/flutter:recipe.bzl", "flutter_native_contribution")
load("@rules_kotlin//kotlin:android.bzl", "kt_android_library")

_LIBRARIES = {
    "arm64-v8a": Label("@rive_native_android//:arm64_v8a"),
}

def rive_native_recipe(name, info):
    kt_android_library(
        name = name,
        srcs = info.android_srcs,
        manifest = info.android_manifest,
        custom_package = info.namespace,
        exports_manifest = 1,
        deps = [info.embedding] + info.plugin_deps + info.coordinates,
    )
    for abi in info.abis:
        if abi not in _LIBRARIES:
            fail("rive_native_recipe has no prebuilt for {}; the archive holds {}.".format(
                abi,
                sorted(_LIBRARIES),
            ))
    flutter_native_contribution(
        name = name + "_flutter_native",
        libraries = {abi: _LIBRARIES[abi] for abi in info.abis},
    )
```

The Kotlin target deliberately keeps the generator's identity and generated
sources. The native contribution gives the APK assembler one
`librive_native.so` in each requested `lib/<abi>/` directory.

`sqlite3` contributes only a native asset; it has no Android manifest, Kotlin
sources, or plugin target implementation. Its recipe verifies the filename that
Flutter's native-assets manifest uses, then creates the empty conventional
package target:

```python
load("@rules_flutter//tools/flutter:recipe.bzl", "flutter_native_contribution")

_LIBRARIES = {
    "arm64-v8a": Label("@libsqlite3_android_arm64_v8a//file"),
}

def sqlite3_recipe(name, info):
    if info.is_plugin:
        fail("sqlite3 is not expected to be a Flutter plugin; the generator saw one")
    for abi in info.abis:
        if abi not in _LIBRARIES:
            fail("sqlite3_recipe has no prebuilt for {}; MODULE.bazel pins {}.".format(
                abi,
                sorted(_LIBRARIES),
            ))
    flutter_native_contribution(
        name = name + "_flutter_native",
        libraries = {abi: _LIBRARIES[abi] for abi in info.abis},
        code_assets = {
            "package:sqlite3/src/ffi/libsqlite3.g.dart": "libsqlite3.so",
        },
    )
    native.filegroup(name = name, srcs = [])
```

For the full, current three-ABI recipes, use
[`rive_native.bzl`](examples/demo_app/bazel/flutter/rive_native.bzl) and
[`sqlite3.bzl`](examples/demo_app/bazel/flutter/sqlite3.bzl), rather than
retyping their pinned mappings.

The package graph produces a per-ABI native aggregate. The APK's generated
bundle check compares native-asset declarations with the libraries actually
placed in the matching ABI slice. Build it explicitly in the demo shape, then
build and install the APK:

```sh
bazel build //:plugins_check
bazel build //:dart_registrant_check
bazel build //android/app:demo_app_flutter_check
bazel build //android/app:demo_app
adb install -r bazel-bin/android/app/demo_app.apk
```

On a device, exercise both runtime paths—not just the counter UI. The demo's
[`lib/main.dart`](examples/demo_app/lib/main.dart) calls `sqlite3.version` and
`rive_native.RiveNative.init()` and shows their results. That confirms the
native library is in `lib/<abi>/`, the native-asset mapping names the correct
file, and the selected ABI can load it. The build guards catch missing declared
libraries, but only executing both APIs proves that the packaged binaries load
on the target device.

## Common variants and maintenance

### Assets

For a new app, `assets = []` is correct until real asset files exist. When
`pubspec.yaml` lists assets such as the demo's
[`assets/images`](examples/demo_app/assets/images/), let `flutter_app()` use its
`assets/**` default (or specify the exact matching inputs). Run `flutter pub get`
after changing `pubspec.yaml`; assets and native-asset manifest contents are
part of the bundle that the APK packages.

### One ABI, many ABIs, fat APKs, and per-ABI APKs

Start with the ABI that matches the device or emulator, then repeat the same
list in every load-bearing declaration. `flutter_android_binary(name = "app",
abis = [...])` emits a fat `:app` APK carrying every listed ABI. When more than
one ABI is listed, it also emits one `:app_<abi>` APK per ABI, such as
`//android/app:demo_app_arm64-v8a` in the demo. A single-ABI app's main target
already is that one slice, so no duplicate per-ABI APK is emitted.

Do not add an ABI only to the Android target or only to `plugins.project()`.
Each AOT snapshot, native plugin/recipe contribution, and native-assets mapping
must cover the same requested slices; the generated bundle check is meant to
catch a missing or mismatched one before packaging.

### Release and debug

Release is default:

```sh
bazel build //android/app:demo_app
```

For the debug-shaped APK, select debug on the Android target:

```sh
bazel build //android/app:demo_app --@rules_flutter//tools/flutter:mode=debug
```

Debug bundles use a kernel blob rather than a release AOT snapshot. Therefore
an AOT target such as `//:app_arm64-v8a` is intentionally incompatible with the
debug setting; build the APK or assets target in debug mode instead.

### Existing projects and generated-state changes

An existing Android Flutter project follows the same recipe as a fresh one:
start at `flutter pub get`, put `MODULE.bazel` at the Flutter project root (or
at the monorepo root for the subpackage shape), and map the real
`MainActivity.kt` path and `applicationId` into the Android BUILD file. Preserve
the explicit root-vs-named `app` label rule.

After every pub resolution change, run `flutter pub get`. For any plugin graph,
then run `:plugins_check` and `:dart_registrant_check`, copy the generator's
expected files with the `bazel cquery --output=files` commands above, and commit
them with the lockfile changes. For `path:` dependencies, keep the local Dart
filegroup in `path_deps`; its content is not represented by a pub lock hash.

Finally, treat building as artifact production, not runtime proof. Discover the
APK, install it on a device or emulator for a shipped ABI, launch it, and
exercise every newly added plugin or native-asset path. That is the only step
that detects a missing registrant, unsupported device ABI, or native library
that is packaged but fails when loaded.
