# rules_flutter

[![CI](https://github.com/Sameri11/rules_flutter/actions/workflows/ci.yml/badge.svg)](https://github.com/Sameri11/rules_flutter/actions/workflows/ci.yml)

Bazel rules that build a Flutter application's Dart and Android halves as ordinary Bazel targets: `frontend_server` and `gen_snapshot` compile the Dart half, and `rules_android` packages the Android half.

Status: Community-maintained, Android-only development preview; not affiliated with, endorsed by, or supported by Google or the Flutter project.

## Why rules_flutter?

Wrapping `flutter build` in one Bazel action makes the whole build opaque: Bazel cannot see the Dart compilation and Android packaging units independently. `rules_flutter` exposes those units as ordinary Bazel targets, so they can be analysed and composed separately. This project publishes no build-speed or hermeticity measurements; the constraints below are the honest picture.

```
lib/**.dart ──frontend_server──> app.dill ──gen_snapshot──> libapp.so ─┐
                                                                       ├─> Android APK
libflutter.so (prebuilt engine) ───────────────────────────────────────┤
flutter_assets ────────────────────────────────────────────────────────┘
       \________ Dart compilation ________/    \__ Android packaging __/
```

### CI-tested toolchains

CI currently tests the configurations below. Other versions may work, but are
not verified; add a configuration here after it passes CI.

- Flutter 3.44.2 / Dart 3.12.2, using Flutter's bundled Dart toolchain.
- Bazel 9.2.0 with Bzlmod; no WORKSPACE path is implemented.
- macOS 15 arm64 and Ubuntu Linux x64; the CI setup action rejects other hosts.

### Supported behavior
- Android release (the default) and debug builds (`--@rules_flutter//flutter:mode=debug`) are supported; there is no profile mode, and AOT is release-only.
- Supported Android ABIs: `arm64-v8a`, `x86_64`, and `armeabi-v7a`. 32-bit `x86` (`@platforms//cpu:x86_32`), `riscv64`, and other ABI values are unsupported.
- The rules request `minSdkVersion` 21 (the same level a plugin's CMake half compiles against) and `targetSdkVersion` 36, but `rules_android` applies its own min-SDK floor during resource processing, so the shipped APK declares 23 today. The consumer's Android SDK pin (36 in the examples) is the compile SDK, not the minimum supported device.
- Proven plugin shapes are pub plugins with Java/Kotlin Android halves, pub plugins with CMake-built native halves, local path plugins in a monorepo, consumer-written Package Recipes, and Dart build-hook packages surfaced through recipes. The automatic graph does not support `ndk-build` or prebuilt-JNI plugins; use a Package Recipe. Plugins whose Maven coordinates cannot be read statically require `plugins.package(artifacts = ...)`.
- A real arm64 APK has been built, installed, and launched on an API 35 emulator.
- Every example module builds on CI, and all seven APK shapes they declare are compared byte-for-byte against a recorded per-host table (`tools/ci/example_hashes.py`). This proves identical bytes for the same host and the same pinned SDK, not cross-machine reproducibility.

### Before you install

These are the hard constraints; [Current constraints](#current-constraints) has the
detail behind each one.

- A local Flutter SDK, Android SDK, and Android NDK 28+ are required and not hermetic: use `FLUTTER_ROOT` or `flutter` on `PATH`, `ANDROID_HOME`, and `ANDROID_NDK_HOME`. CI uses Flutter 3.44.2/Dart 3.12.2. The examples pin SDK platform 36 and build-tools 36.0.0; the consumer module chooses its own. With `ANDROID_NDK_HOME` unset, the NDK wrapper substitutes a no-toolchains stub and the build fails only when a target needs an Android toolchain.
- Dart and asset actions run unsandboxed with remote execution disabled because they read the local Flutter SDK and `~/.pub-cache` by absolute path.
- Hosted pub dependencies are keyed by `pubspec.lock`, path dependencies are not hashed and go stale unless the consumer declares their sources, `.dart_tool` state is a bootstrap prerequisite rather than a tracked input, and Dart compilation is not incremental.
- Bazel emits an unsigned APK; release signing happens outside Bazel, and custom release signing inside Bazel is not supported.
- Native assets require consumer-written Package Recipes.
- Before the first plugin graph, `flutter pub get` must produce the generated state and two zero-byte placeholders must be created by hand; this bootstrap path has no automated regression gate.
- The consumer module owns its `rules_jvm_external` installation and Maven repository; this ruleset does not own the application's Maven graph.
- Targets are Android-only; iOS, web, and desktop packaging are not implemented.

## Quickstart

This is the complete plugin-free path for a fresh Android-only Flutter
project. For an existing project, skip only the `flutter create` command,
run `flutter pub get`, then add the files below at the existing project root.
The project root is also the Bazel module root, beside `pubspec.yaml`, `lib/`,
and `android/`.
For the expanded plugin-free walkthrough, pub plugins, local plugins in
monorepos, and consumer recipes/native assets, see the
[detailed quickstart](QUICKSTART.md).

### Prerequisites

Start with the CI-tested Flutter 3.44.2 (Dart 3.12.2), Bazel 9.2.0 with Bzlmod, Android SDK platform 36 with build-tools 36.0.0, and Android NDK 28 or newer. Set `FLUTTER_ROOT` or put `flutter` on `PATH`, and set `ANDROID_HOME` and `ANDROID_NDK_HOME`. The rules pin their own JDK 17 toolchain.

Without `api_level`, `rules_android` compiles against the highest Android platform installed, which makes the APK's manifest depend on the machine. This repository's examples therefore pin SDK platform 36 and build-tools 36.0.0; building them needs both installed. A consumer module must explicitly register NDK toolchains in its `MODULE.bazel` and inherit the stable repositories from `rules_flutter`'s NDK extension. With `ANDROID_NDK_HOME` unset, the NDK wrapper substitutes a stub declaring no toolchains; the failure surfaces only when a target needs an Android toolchain.

### Create the project

Until registry publication, run these commands from a `rules_flutter` checkout.
They create the consumer as a sibling, so the later `../rules_flutter` override
resolves to this repository.

```sh
cd ..
flutter create --org com.example --platforms android hello_bazel
cd hello_bazel
flutter pub get
```

`flutter pub get` is required: the build consumes its generated package config, plugin-dependencies state, and `GeneratedPluginRegistrant.java`.

### Bazel workspace files

Create `.bazelversion`:

```
9.2.0
```

Create `.bazelrc`:

```
common --enable_bzlmod
build:android --merge_android_manifest_permissions
build:android --tool_java_language_version=17 --tool_java_runtime_version=remotejdk_17
build:android --java_language_version=17 --java_runtime_version=remotejdk_17
common:android --repo_env=ANDROID_NDK_HOME
common --config=android
```

Create the root `MODULE.bazel` (the `local_path_override` is development-only until `rules_flutter` is published to a registry):

```python
module(name = "hello_bazel", version = "0.0.1")

bazel_dep(name = "sameri11_rules_flutter", version = "0.1.0", repo_name = "rules_flutter")
local_path_override(
    module_name = "sameri11_rules_flutter",
    path = "../rules_flutter",
)

include("//android:config.MODULE.bazel")
```

Export the platform configuration from `android/BUILD.bazel`:

```python
exports_files(["config.MODULE.bazel"])
```

Put Android dependencies, repositories, and toolchain registration in
`android/config.MODULE.bazel`:

```python
bazel_dep(name = "rules_android", version = "0.7.3")
bazel_dep(name = "rules_kotlin", version = "2.4.0")
bazel_dep(name = "rules_jvm_external", version = "7.1")

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

android_ndk = use_extension("@rules_flutter//flutter:extensions.bzl", "android_ndk")
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

Create `BUILD.bazel` at the project root:

```python
load("@rules_flutter//flutter:defs.bzl", "flutter_app")

package(default_visibility = ["//visibility:public"])

flutter_app(
    abis = ["arm64-v8a", "x86_64"],
    plugin_deps = None,
    assets = [],
)
```

### Android target

Find the generated activity path (the package path depends on the organization and project name):

```sh
find android/app/src/main/kotlin -name MainActivity.kt
```

Create `android/app/BUILD.bazel`, replacing `com.example.hello_bazel`, `hello_bazel`, and the `MainActivity.kt` path when your project differs:

```python
load("@rules_android//rules:rules.bzl", "android_library")
load("@rules_flutter//flutter:defs.bzl", "flutter_android_binary", "flutter_embedding_library")
load("@rules_kotlin//kotlin:android.bzl", "kt_android_library")

package(default_visibility = ["//visibility:public"])

flutter_embedding_library(name = "flutter_embedding")

flutter_android_binary(
    name = "hello_bazel",
    abis = ["arm64-v8a", "x86_64"],
    app = "//:app",  # NOT "//"
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

The root application label must be `//:app`, not `//`. Keep the explicit ABI list in both rules.

### Build, install, and check

The release build is the default. The APK target depends on the Dart/AOT and
asset targets, so build it directly:

```sh
: "${ANDROID_HOME:?set ANDROID_HOME to your Android SDK}"
: "${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME to an Android NDK 28+ installation}"
bazel build //android/app:hello_bazel
ls bazel-bin/android/app/
adb install -r bazel-bin/android/app/<name>.apk
bazel test //:guards_test
```

Replace `<name>.apk` with the APK discovered in `bazel-bin/android/app/`. To build the optional debug-shaped APK:

```sh
bazel build //android/app:hello_bazel --@rules_flutter//flutter:mode=debug
```

Run the Bazel-built debug APK through Flutter. This installs it, launches it,
and attaches without invoking Gradle:

```sh
flutter run -d <device-id> --debug \
  --use-application-binary=bazel-bin/android/app/hello_bazel.apk
```

Use `r` for hot reload and `R` for hot restart. Packaging-input changes require
rebuilding the APK and running the command again. See the
[detailed hot-reload workflow](QUICKSTART.md#hot-reload-with-flutter-run).

Do not apply debug mode to `//:app_arm64-v8a`; AOT is release-only.

### Adding plugins

The first plugin setup generates and commits the Maven/plugin registrant state required by the plugin graph; its generated files and configuration are intentionally not inlined here.

## Scope, limitations, and direction

### Supported today

Android release and debug packaging across the supported ABIs, including fat and per-ABI APKs; pub plugin Java/Kotlin and CMake native builds; generated Dart and Android registrants; and consumer-supplied native-asset recipes.

### Current constraints

- The local Flutter 3.44.2/Dart 3.12.2 SDK, Android SDK, and Android NDK installations are not hermetic. The SDK is located through `FLUTTER_ROOT` or `flutter` on `PATH`; the consumer supplies `ANDROID_HOME` and Android SDK API 36/build-tools 36.0.0, and `ANDROID_NDK_HOME` must point to NDK 28 or newer. If `ANDROID_NDK_HOME` is unset, the NDK wrapper substitutes a stub declaring no toolchains, so failure surfaces only when a target needs an Android toolchain.
- Dart and asset actions are unsandboxed with remote execution disabled because they read the local Flutter SDK and `~/.pub-cache` by absolute path.
- Hosted pub dependencies are keyed by `pubspec.lock`; path dependencies are not hashed and go stale unless the consumer declares their sources. `.dart_tool` state is a bootstrap prerequisite, not a tracked input, and Dart compilation is not incremental.
- Before a build, `flutter pub get` must have produced `.dart_tool/package_config.json` and `.flutter-plugins-dependencies`. The first plugin graph additionally needs two zero-byte placeholders created by hand: `plugin_deps.MODULE.bazel` because `include()` requires its target file to exist, and `lib/dart_plugin_registrant.dart` because the plugin guard's committed-file attribute is mandatory. This bootstrap path has no automated regression gate; follow the [public plugin-graph walkthrough](QUICKSTART.md#create-generated-state-and-wire-the-plugin-graph) by hand.
- Native assets from Dart build-hook packages require consumer-written Package Recipes. The consumer module also owns its `rules_jvm_external` installation and Maven repository; this ruleset does not own the application's Maven graph.
- Bazel emits an unsigned APK. Release signing happens outside the build so credentials never enter the action graph; custom release signing inside Bazel is not supported.
- `ndk-build` plugins and prebuilt-JNI plugin shapes are not supported. Plugin Maven coordinates that cannot be read statically require `plugins.package(artifacts = ...)`.
- iOS, web, and desktop packaging are not implemented; targets are Android-only.
- A cold analysis with an empty `HOME` may leave the `Analyzing` count unchanged for minutes while Maven/Coursier, JDK, Flutter engine, Kotlin, NDK, and tool repositories are fetched; continued download or process activity indicates network-bound setup, not proof of a deadlock. When intentionally perturbing `HOME`, pin `BAZELISK_HOME` and Bazel's startup `--output_user_root` to isolate launcher and download caches from rules behavior.

### Possible future direction

Hermetic dependency and SDK modelling, incremental workers, more plugin systems, and other platforms are possible directions, not scheduled commitments.
