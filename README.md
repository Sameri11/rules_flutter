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

A local Flutter SDK, Android SDK, and Android NDK 28+ are required and are not
hermetic. Set `FLUTTER_ROOT` or put `flutter` on `PATH`, and set
`ANDROID_HOME` and `ANDROID_NDK_HOME`. Commit `pubspec.lock`; Git pub sources are
rejected, path dependencies need `path_deps`, and Dart compilation is not
incremental. Bazel emits a debug-key-signed APK and an unsigned APK; release
signing occurs outside Bazel. Native assets require consumer-written Package
Recipes. The Consumer Module owns its Maven installation. Android is the only
implemented app backend; host test and asset views do not require an app Target
OS.

The same `flutter_core` declaration serves host unit/widget tests and Android
app configurations. Host tests do not need an app Target OS; Android app builds
select the AOT kernel from their configured Target OS. No per-OS core
declarations are needed.

### Composition and ABI selection

The convenience API is the default: load `flutter_core`, `flutter_package`,
`flutter_pubspec`, `flutter_test`, and `flutter_test_suite` from
`@rules_flutter_core//flutter:defs.bzl`, and `flutter_android_app` and related
Android helpers from `@rules_flutter_android//flutter:defs.bzl`. For deliberate
hand-wiring, the public `composition.bzl` modules expose lower-level providers,
rules, and targets. `flutter_pubspec` remains in core `defs.bzl` because
`flutter_package` requires it.

Select APK ABIs with ordinary `--android_platforms`. Use one APK label for each
existing app/mode variant and separate build commands for fat or single-ABI
configurations. Capture each APK before the next configuration because the
materialized APK path may be shared.

The core output groups remain available to hand-wired consumers, but embedding
is owned by the Android ruleset. Use
`@rules_flutter_android//flutter:embedding_jar` for the mode-selected jar;
`flutter_embedding_deps(maven_repo)` supplies its explicit AndroidX classpath.
For a complete stock `android_binary` example—including a plugin registrant,
BuildConfig, and development-only Maven dependency—see
[`tests/consumer/hand_wired_app/BUILD.bazel`](tests/consumer/hand_wired_app/BUILD.bazel).

`flutter_debug_core` is a lower-level core composition rule. It declares a debug
artifact of an app's `flutter_core` built from another entrypoint, such as an
integration-test file, with its own `dart_defines`. Dart files outside `lib/`
that the entrypoint imports go in `srcs`; an undeclared import fails the
compile. The app's package inputs, mode-free bundle, and debug engine are reused.
It is debug-only and `manual` unless `tags` overrides that. Build it with
`-c fastbuild --@rules_flutter_core//flutter:mode=debug` and an Android
`--platforms`.


One measured warm four-command sequence took 1.500 seconds with the former suffixed labels and 16.165 seconds with one label under successive ABI configurations. These timings are scoped to one machine/workflow, not a general speed promise. Expensive Flutter/native actions remained reusable, while Android packaging reran. Disk/remote-cache switching speed was not measured; shared materialized paths do not inherently collide in action caches.

## Compatibility with flutter_tools

| Feature | Stock Flutter | rules_flutter | Notes |
| --- | --- | --- | --- |
| Android release builds | `flutter build apk --release` | Implemented | Build with `-c opt`. |
| Android debug builds | `flutter build apk --debug` | Implemented | Build with `-c fastbuild` and `--@rules_flutter_core//flutter:mode=debug`. |
| Android profile builds | `flutter build apk --profile` | Not implemented | Debug and release only. |
| Split APKs by architecture | `--split-per-abi` | Implemented | Select ABI set through `--android_platforms`; one APK label per app/mode variant. |
| Android App Bundles (AAB) | `flutter build appbundle` | Not implemented | APKs only. |
| Dart defines | `--dart-define`, `--dart-define-from-file` | Partial | `flutter_core(dart_defines = {...})`, `flutter_debug_core(dart_defines = {...})` and `flutter_test(dart_defines = {...})`; no `--dart-define-from-file`. |
| Android plugins and native packages | Standard Flutter/Gradle workflow | Partial | Common Java/Kotlin and CMake plugins work; custom build logic and native assets need recipes. |
| Release signing | Gradle signing configuration | Not implemented | Sign the unsigned output outside the build. |
| Product flavors | `--flavor` | Not implemented | Declare separate Bazel targets instead. |
| iOS, web, desktop | Platform-specific builds | Not implemented | Android only. |
| Unit and widget tests | `flutter test` | Partial | `flutter_test` and `flutter_test_suite` run host tests. |
| Integration tests | `flutter test integration_test` | Partial | `flutter_integration_test` with `flutter_android_app(integration_tests = ...)` runs on an Android device or emulator; no sharding. |

## Installing the rules

Consumers declare both modules in their Consumer Module. Until the modules are
published to a registry, the supported install path is an immutable commit
archive of this repository: one tarball, two `archive_override` entries, and no
local rules checkout.

```python
bazel_dep(name = "sameri11_rules_flutter_core", version = "0.1.0", repo_name = "rules_flutter_core")
archive_override(
    module_name = "sameri11_rules_flutter_core",
    urls = ["https://api.github.com/repos/Sameri11/rules_flutter/tarball/42c9011f4f44fff205f122c4583aa39198564aea"],
    sha256 = "06d5307ebfe9622aaa12173c6486fe5a9edadb25315cff1398947d50996ae691",
    strip_prefix = "Sameri11-rules_flutter-42c9011/rules_flutter_core",
    type = "tar.gz",
)

bazel_dep(name = "sameri11_rules_flutter_android", version = "0.1.0", repo_name = "rules_flutter_android")
archive_override(
    module_name = "sameri11_rules_flutter_android",
    urls = ["https://api.github.com/repos/Sameri11/rules_flutter/tarball/42c9011f4f44fff205f122c4583aa39198564aea"],
    sha256 = "06d5307ebfe9622aaa12173c6486fe5a9edadb25315cff1398947d50996ae691",
    strip_prefix = "Sameri11-rules_flutter-42c9011/rules_flutter_android",
    type = "tar.gz",
)
```

Both overrides name the same archive, the same URL and the same digest; only
`strip_prefix` differs, so each module is read from its own directory of the
extracted tree. The digest pins the download: an archive whose contents do not
match fails during repository fetch instead of building. Moving to another rules
revision means updating `urls` and `sha256` together in both overrides; the
`strip_prefix` root changes with the commit. Copy the values from a tested
consumer such as
[`tests/archive_consumer/MODULE.bazel`](tests/archive_consumer/MODULE.bazel).

An archive consumer owns its whole repository configuration. The extracted
module trees carry neither this repository's root module nor its shared
`.bazelrc`, so the consumer declares its own `.bazelrc` settings, Flutter/pub
extensions, Android SDK and NDK toolchain registration, Maven install and pub
lock. Nothing is imported from a parent rules checkout.

For development against a local checkout, keep the same two `bazel_dep` lines
and use `local_path_override` instead of the archive overrides; the rest of the
consumer configuration is unchanged. When the modules are published to a
registry, the `bazel_dep` lines resolve normally and the overrides are removed.

The checked [`tests/archive_consumer`](tests/archive_consumer/) example is a
complete standalone consumer built from one pinned archive, with its own
`.bazelrc`, module file and committed lock. It pins Flutter 3.47.3, Bazel 9.2.0,
Android SDK API 36 with build-tools 36.0.0 and NDK 28 or newer, and builds
`//:app_unsigned.apk` for release `arm64-v8a`. It is an installation example for
the archive revision it names, not a test of the current checkout.

## Quickstart

This is a complete plugin-free path for a fresh Android-only Flutter project. For the detailed plugin, monorepo and recipe walkthroughs, see [QUICKSTART.md](QUICKSTART.md).

### Prerequisites

Use the CI-tested Flutter and Bazel versions, Bzlmod, Android SDK platform 36 with build-tools 36.0.0, and Android NDK 28 or newer. Set `FLUTTER_ROOT` or put `flutter` on `PATH`, plus `ANDROID_HOME` and `ANDROID_NDK_HOME`.

### Create the project

No rules checkout is needed; the archive supplies both modules:

```sh
flutter create --org com.example --platforms android hello_bazel
cd hello_bazel
```

Commit the generated `pubspec.lock`; Bazel reads it, not `.dart_tool/`.

### Bazel workspace files

Use Bazel 9.2.0 and Bzlmod. Declare both modules with the archive overrides
shown in [Installing the rules](#installing-the-rules); the `bazel_dep` lines
alone do not resolve, because the modules are not published to a registry yet.

The Consumer Module configures the Flutter SDK/pub extensions, Android SDK/NDK
toolchains, and its own Maven graph. See the detailed quickstart for the full
module and `.bazelrc` configuration.

Create the root BUILD file:

```python
load("@rules_flutter_core//flutter:defs.bzl", "flutter_core")

package(default_visibility = ["//visibility:public"])

flutter_core(
    name = "core",
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

A new consumer has no `MODULE.bazel.lock` yet. Run the first release build with
`--lockfile_mode=update`, which resolves the archive and writes the lock, then
commit the generated `MODULE.bazel.lock`. Every later build uses
`--lockfile_mode=error`, so an unresolved archive or dependency fails instead of
silently changing the lock:

```sh
# First build only: generate the lock, then commit MODULE.bazel.lock.
bazel build //android/app:hello_bazel -c opt --lockfile_mode=update \
  --android_platforms=@rules_android//:arm64-v8a

# Subsequent release and debug builds.
bazel build //android/app:hello_bazel -c opt --lockfile_mode=error \
  --android_platforms=@rules_android//:arm64-v8a
bazel build //android/app:hello_bazel -c fastbuild --lockfile_mode=error \
  --@rules_flutter_core//flutter:mode=debug \
  --android_platforms=@rules_android//:arm64-v8a
```

Select the ABI set using `--android_platforms`; keep the APK label unchanged. Build and capture each configuration's APK before the next invocation. Install with `adb install -r bazel-bin/android/app/hello_bazel.apk`. For hot reload, run the Bazel-built debug APK with `flutter run --debug --use-application-binary=<apk-path>`; packaging changes require a rebuild.

## Scope and constraints

The SDK, Android NDK and Android SDK are local, non-hermetic inputs. The Consumer Module owns Maven dependency resolution. `pubspec.lock` must be committed; hosted packages are pinned by sha256, Git sources are unsupported, and path dependencies must be declared. The Android plugin hub generates Java registrants for each mode; debug includes dev-only plugins and release excludes them. The checked-in debug Dart registrant is at `lib/dart_plugin_registrant.dart`; the hub generates release registration during the build. Core checks the committed debug registrant against pub metadata.

Bazel emits debug-key-signed and unsigned APKs; sign release APKs outside Bazel. `ndk-build` and prebuilt-JNI plugins are unsupported by automatic generation. See the detailed quickstart for Package Recipes and plugin configuration.

## Android integration tests

Declare each `integration_test` file with `flutter_integration_test` in the
package root, then attach it to the Android app:

```python
load("@rules_flutter_core//flutter:defs.bzl", "flutter_integration_test")
load("@rules_flutter_android//flutter:defs.bzl", "flutter_android_app")

flutter_integration_test(
    name = "login",
    app = ":core",
    src = "integration_test/login_test.dart",
)

flutter_android_app(
    name = "app",
    integration_tests = {"//:login": {}},
)
```

This generates `//android/app:app_login` (the test APK) and
`//android/app:app_login_test` (the runner). Run with
`bazel test --@rules_flutter_core//flutter:mode=debug //android/app:app_login_test`;
adding that mode flag to `.bazelrc` is convenient.

The host provides the emulator/device and runs its adb server. The server's adb
version must match the adb from the declared Android SDK; start the emulator or
start the server with that SDK's adb. Select a device with an exported
`ANDROID_SERIAL`, or pass `--test_env=ANDROID_SERIAL=<serial>`; the exported
variable is inherited by the test.

The test APK has the same `applicationId` as the development app, replaces it
while the test runs, and is uninstalled afterward. In the Dart test, create
`${Directory.systemTemp.path}/rules_flutter_test/outputs/` and write files there
(for example with `Directory.create(recursive: true)` and `File.writeAsString`).
The runner copies those files into Bazel's `test.outputs` directory. It always
adds `manual`, `external`, and `exclusive` tags. The rule has no `data` or `env`
attributes; configure device-visible values with `dart_defines`. Use
`--test_filter` to select cases.
Sharding is not supported yet.
