# rules_flutter

[![CI](https://github.com/Sameri11/rules_flutter/actions/workflows/ci.yml/badge.svg)](https://github.com/Sameri11/rules_flutter/actions/workflows/ci.yml)

Bazel rules that build Flutter's Dart and Android halves directly: `frontend_server` and `gen_snapshot` compile the Dart application, while `rules_android` packages the result. Android-only today.

## Why rules_flutter?

Wrapping `flutter build` in one Bazel action makes the whole build opaque: Bazel cannot see or cache the Dart compilation and packaging units independently. `rules_flutter` exposes those units directly, so Dart actions and the Android packaging seam can be analysed, cached, and composed with ordinary Bazel targets.

```
lib/**.dart ──frontend_server──> app.dill ──gen_snapshot──> libapp.so ─┐
                                                                       ├─> Android APK
libflutter.so (prebuilt engine) ───────────────────────────────────────┤
flutter_assets ────────────────────────────────────────────────────────┘
       \________ Dart compilation ________/    \__ Android packaging __/
```

### Supported and verified

- Flutter 3.44.2 / Dart 3.12.2 with Bazel 9.2.0.
- Android release and debug builds for `arm64-v8a`, `x86_64`, and `armeabi-v7a`, including fat and per-ABI APKs.
- Java and Kotlin plugins, CMake-backed native plugins, and native assets have worked; a real arm64 APK has been built, installed, and launched on an API 35 emulator.
- Every example module builds on CI, and all seven APK shapes they declare are compared byte-for-byte against a recorded table (`tools/ci/example_hashes.py`) that a developer machine reproduces.

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

Install Flutter 3.44.2 (Dart 3.12.2), Bazel 9.2.0 (Bazelisk recommended), a recent Android SDK, and an Android NDK 28 or newer. Set `FLUTTER_ROOT` or put `flutter` on `PATH`, and set `ANDROID_HOME` and `ANDROID_NDK_HOME` (for the NDK). The rules pin their own JDK 17 toolchain.

With no `api_level`, `rules_android` compiles against the highest Android platform installed, which makes the APK's manifest depend on the machine. This repository's examples therefore pin SDK platform 36 and build-tools 36.0.0; building them needs both installed. An Android Consumer Module must explicitly register NDK toolchains in its `MODULE.bazel` and inherit the stable repositories from `rules_flutter`'s NDK extension; an NDK that is not configured will be discovered only when a target tries to use Android toolchains, at which point the repository fetch will fail with a diagnostic naming `ANDROID_NDK_HOME`.

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
# Forwarded to repository rules, which is where the NDK path is read.
common:android --repo_env=ANDROID_NDK_HOME
common --config=android
```

Create `MODULE.bazel` (the `local_path_override` is development-only until `rules_flutter` is published to a registry):

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

Create `BUILD.bazel` at the project root:

```python
load("@rules_flutter//tools/flutter:defs.bzl", "flutter_app")

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
load("@rules_flutter//tools/flutter:android.bzl", "flutter_android_binary")
load("@rules_flutter//tools/flutter:embedding.bzl", "flutter_embedding_library")
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
export ANDROID_HOME="$HOME/Library/Android/sdk"
export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/<your 28+ version>"
bazel build //android/app:hello_bazel
ls bazel-bin/android/app/
adb install -r bazel-bin/android/app/<name>.apk
bazel test //:guards_test
```

Replace `<name>.apk` with the APK discovered in `bazel-bin/android/app/`. To build the optional debug-shaped APK:

```sh
bazel build //android/app:hello_bazel --@rules_flutter//tools/flutter:mode=debug
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

- The local Flutter, Android SDK, and NDK installations are not hermetic.
- Most Dart and asset actions are unsandboxed and do not support remote execution; source tracking is imperfect and Dart compilation is not incremental.
- A cold analysis with an empty `HOME` may leave the `Analyzing` count unchanged for minutes while Maven/Coursier, JDK, Flutter engine, Kotlin, NDK, and tool repositories are fetched; continued download or process activity indicates network-bound setup, not proof of a deadlock. When intentionally perturbing `HOME`, pin `BAZELISK_HOME` and Bazel's startup `--output_user_root` to isolate launcher and download caches from rules behavior.
- Native assets require manual consumer recipes, and the first plugin graph requires manual bootstrap and committed generated state.
- Custom release signing is not supported, and `ndk-build` plugins are not supported.
- Plugin Maven coordinates that cannot be read statically require `plugins.package(artifacts = ...)`.
- iOS and other platform packaging are not implemented.

### Possible future direction

Hermetic dependency and SDK modelling, incremental workers, more plugin systems, and other platforms are possible directions, not scheduled commitments.
