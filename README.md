# rules_flutter

[![CI](https://github.com/Sameri11/rules_flutter/actions/workflows/ci.yml/badge.svg)](https://github.com/Sameri11/rules_flutter/actions/workflows/ci.yml)

Bazel rules that build Flutter applications with two modules: `rules_flutter_core` for Flutter artifacts and `rules_flutter_android` for Android composition and packaging. Consumer Modules load both for helper-based packaging, or consume core outputs in a consumer-owned stock `android_binary`.

Status: Community-maintained, Android-only development preview; not affiliated with, endorsed by, or supported by Google or the Flutter project.

## Why rules_flutter?

`rules_flutter` separates Flutter artifact production from Android packaging. `flutter_core` exposes typed artifacts that Android packaging can compose independently. This keeps the Android binary a normal Bazel target rather than hiding it behind a custom packaging API.

```
lib/**.dart ──frontend_server──> app.dill ──gen_snapshot──> libapp.so ─┐
                                                                       ├─> Android APK
libflutter.so (prebuilt engine) ───────────────────────────────────────┤
flutter_assets ────────────────────────────────────────────────────────┘
       \________ Dart compilation ________/    \__ Android packaging __/
```

CI tests the Flutter version pinned in `.github/workflows/ci.yml`, the Bazel
version configured by the CI workflow, macOS 15 arm64 and Ubuntu Linux x64.
Other versions may work but are unverified.

### Supported behavior

- Android release (`-c opt`) and debug (`-c fastbuild` with `--@rules_flutter_core//flutter:mode=debug`) builds are supported; there is no profile mode, and AOT is release-only.
- Supported Android ABIs: `arm64-v8a`, `x86_64`, and `armeabi-v7a`. 32-bit `x86`, `riscv64`, and other ABI values are unsupported.
- Supported plugin shapes include pub plugins with Java/Kotlin Android halves,
  CMake native halves, local path plugins, consumer-written Package Recipes, and
  Dart build-hook packages surfaced through recipes. Automatic generation does
  not support `ndk-build` or prebuilt-JNI plugins. Coordinates that cannot be
  read statically require `plugins.package(artifacts = ...)`.
- CI builds and hash-checks examples per host; this does not establish
  cross-machine reproducibility.

### Before you install

A local Flutter SDK, Android SDK, and Android NDK 28+ are required and not hermetic. Set `FLUTTER_ROOT` or put `flutter` on `PATH`, and set `ANDROID_HOME` and `ANDROID_NDK_HOME`. Commit `pubspec.lock`; Git pub sources are rejected, path dependencies need `path_deps`, and Dart compilation is not incremental. Bazel emits a debug-key-signed APK and an unsigned APK; release signing occurs outside Bazel. Native assets require consumer-written Package Recipes. The Consumer Module owns its Maven installation. Targets are Android-only.

### Composition and ABI selection

Declare one `flutter_core` from the core module per Bazel package; it owns that
package's app outputs, package/test outputs, and conditional plugin/registrant
guards. `flutter_android_app` is the standard helper entrypoint.
`flutter_android_inputs`, `flutter_apk_check`, `flutter_android_manifest`,
`flutter_assets_dir`, and `flutter_native_contribution` support custom
composition.

Select APK ABIs with ordinary `--android_platforms`. Use one APK label for each
existing app/mode variant and separate build commands for fat or single-ABI
configurations. Capture each APK before the next configuration because the
materialized APK path may be shared.

A consumer-owned stock `android_binary` may consume configured core targets'
`OutputGroupInfo`: `flutter_assets` is the bundle tree, `flutter_engine` is the
complete selected engine-library set, `flutter_libapp` is release AOT (empty in
debug), and `flutter_embedding` is the mode-selected embedding jar. The engine
group can contain multiple libraries for one ABI. `FlutterArtifactInfo` is a
separate typed provider. See the checked stock-binary example in
[`tests/consumer/composed_app/BUILD.bazel`](tests/consumer/composed_app/BUILD.bazel),
target `//composed_app:direct_apk`. Consumers own Android packaging and native
library handling, including strip behavior required by their packaging graph.

One measured warm four-command sequence took 1.500 seconds with the former suffixed labels and 16.165 seconds with one label under successive ABI configurations. These timings are scoped to one machine/workflow, not a general speed promise. Expensive Flutter/native actions remained reusable, while Android packaging reran. Disk/remote-cache switching speed was not measured; shared materialized paths do not inherently collide in action caches.

## Compatibility with flutter_tools

| Feature | Stock Flutter | rules_flutter | Notes |
| --- | --- | --- | --- |
| Android release builds | `flutter build apk --release` | Implemented | Build with `-c opt`. |
| Android debug builds | `flutter build apk --debug` | Implemented | Build with `-c fastbuild` and `--@rules_flutter_core//flutter:mode=debug`. |
| Android profile builds | `flutter build apk --profile` | Not implemented | Debug and release only. |
| Split APKs by architecture | `--split-per-abi` | Implemented | Select ABI set through `--android_platforms`; one APK label per app/mode variant. |
| Android App Bundles (AAB) | `flutter build appbundle` | Not implemented | APKs only. |
| Dart defines | `--dart-define`, `--dart-define-from-file` | Partial | `flutter_core(dart_defines = {...})` and `flutter_test(dart_defines = {...})`; no `--dart-define-from-file`. |
| Android plugins and native packages | Standard Flutter/Gradle workflow | Partial | Common Java/Kotlin and CMake plugins work; custom build logic and native assets need recipes. |
| Release signing | Gradle signing configuration | Not implemented | Sign the unsigned output outside the build. |
| Product flavors | `--flavor` | Not implemented | Declare separate Bazel targets instead. |
| iOS, web, desktop | Platform-specific builds | Not implemented | Android only. |
| Unit and widget tests | `flutter test` | Partial | `flutter_test` and `flutter_test_suite` run host tests; no devices or integration tests. |

## Quickstart

This is a complete plugin-free path for a fresh Android-only Flutter project. For the detailed plugin, monorepo and recipe walkthroughs, see [QUICKSTART.md](QUICKSTART.md).

### Prerequisites

Use the CI-tested Flutter and Bazel versions, Bzlmod, Android SDK platform 36 with build-tools 36.0.0, and Android NDK 28 or newer. Set `FLUTTER_ROOT` or put `flutter` on `PATH`, plus `ANDROID_HOME` and `ANDROID_NDK_HOME`.

### Create the project

From a `rules_flutter` checkout:

```sh
cd ..
flutter create --org com.example --platforms android hello_bazel
cd hello_bazel
```

Commit the generated `pubspec.lock`; Bazel reads it, not `.dart_tool/`.

### Bazel workspace files

Use Bazel 9.2.0 and Bzlmod. Declare both modules in the Consumer Module:

```python
bazel_dep(name = "sameri11_rules_flutter_core", version = "0.1.0", repo_name = "rules_flutter_core")
bazel_dep(name = "sameri11_rules_flutter_android", version = "0.1.0", repo_name = "rules_flutter_android")
```

The Consumer Module configures the Flutter SDK/pub extensions, Android SDK/NDK toolchains, and its own Maven graph. See the detailed quickstart for the full module configuration.

Create the root BUILD file:

```python
load("@rules_flutter_core//flutter:defs.bzl", "flutter_core")

package(default_visibility = ["//visibility:public"])

flutter_core(
    name = "core",
    plugin_deps = None,
    assets = [],
    pub = "@pub",
)
```

Find the generated `MainActivity.kt` path, then create `android/app/BUILD.bazel`:

```python
load("@rules_flutter_android//flutter:defs.bzl", "flutter_android_app")
load("@rules_kotlin//kotlin:android.bzl", "kt_android_library")

package(default_visibility = ["//visibility:public"])

flutter_android_app(
    name = "hello_bazel",
    core = "//:core",
    manifest_values = {"applicationId": "com.example.hello_bazel"},
    plugins = None,
    deps = [":main_activity"],
)


kt_android_library(
    name = "main_activity",
    srcs = ["src/main/kotlin/com/example/hello_bazel/MainActivity.kt"],
    deps = [":hello_bazel_inputs"],
)
```

The helper produces the app inputs target used by the Android entrypoint and
other Android targets in the package.

Build release with `-c opt` and debug with `-c fastbuild` plus Flutter debug mode:

```sh
bazel build //android/app:hello_bazel -c opt \
  --android_platforms=@rules_android//:arm64-v8a
bazel build //android/app:hello_bazel -c fastbuild \
  --@rules_flutter_core//flutter:mode=debug \
  --android_platforms=@rules_android//:arm64-v8a
```


Select the ABI set using `--android_platforms`; keep the APK label unchanged. Build and capture each configuration's APK before the next invocation. Install with `adb install -r bazel-bin/android/app/hello_bazel.apk`. For hot reload, run the Bazel-built debug APK with `flutter run --debug --use-application-binary=<apk-path>`; packaging changes require a rebuild.

## Scope and constraints

The SDK, Android NDK and Android SDK are local, non-hermetic inputs. The Consumer Module owns Maven dependency resolution. `pubspec.lock` must be committed; hosted packages are pinned by sha256, Git sources are unsupported, and path dependencies must be declared. The Android registrant is generated from the lock for each mode: debug includes dev-only plugins and release excludes them. `plugin_deps.MODULE.bazel` is the generated Maven segment; `lib/dart_plugin_registrant.dart` is the Dart registrant.

Bazel emits debug-key-signed and unsigned APKs; sign release APKs outside Bazel. `ndk-build` and prebuilt-JNI plugins are unsupported by automatic generation. See the detailed quickstart for Package Recipes and plugin configuration.
