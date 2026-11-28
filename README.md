# rules_flutter

[![CI](https://github.com/Sameri11/rules_flutter/actions/workflows/ci.yml/badge.svg)](https://github.com/Sameri11/rules_flutter/actions/workflows/ci.yml)

Bazel rules for building Flutter apps. Build Dart code and Flutter assets with
Bazel, then compose them with platform-native Bazel rules.

Android is currently the only supported app platform. This is a
community-maintained development preview, not affiliated with Google or the
Flutter project.

## First build (Android example)

Install Bazel 9.2.0, Android SDK platform 36 and build-tools 36.0.0, and
Android NDK 28 or newer. `flutter.sdk(version = "3.50.1")` provisions the SDK
through Bazel; downloads require stable Flutter 3.47.0 or newer. Pre-release
versions are unsupported.
The first resolution pins its Facts in `MODULE.bazel.lock`, which must be
committed. Set `ANDROID_HOME` and `ANDROID_NDK_HOME`.

The `flutter create` command below is a host Flutter command.

```sh
flutter create --empty --org com.example --platforms android hello_bazel
cd hello_bazel
```

Commit `pubspec.lock`. Copy the standalone consumer's
[`MODULE.bazel`](tests/archive_consumer/MODULE.bazel),
[`.bazelrc`](tests/archive_consumer/.bazelrc) and
[`.bazelversion`](tests/archive_consumer/.bazelversion) into your app root.
The module configures the Flutter, pub, and Android repositories and adds
these two dependencies from a pinned archive:

```python
bazel_dep(name = "sameri11_rules_flutter_core", version = "0.1.0", repo_name = "rules_flutter_core")
bazel_dep(name = "sameri11_rules_flutter_android", version = "0.1.0", repo_name = "rules_flutter_android")

archive_override(
    module_name = "sameri11_rules_flutter_core",
    sha256 = "4de150f68bd24f31a5c67ce79b4fdf29d3a430526d775189ec58536d7c557c3c",
    strip_prefix = "Sameri11-rules_flutter-1b6b8a6/rules_flutter_core",
    type = "tar.gz",
    urls = ["https://api.github.com/repos/Sameri11/rules_flutter/tarball/1b6b8a679f2c19a49f6b6e81be40f8a40f958362"],
)

archive_override(
    module_name = "sameri11_rules_flutter_android",
    sha256 = "4de150f68bd24f31a5c67ce79b4fdf29d3a430526d775189ec58536d7c557c3c",
    strip_prefix = "Sameri11-rules_flutter-1b6b8a6/rules_flutter_android",
    type = "tar.gz",
    urls = ["https://api.github.com/repos/Sameri11/rules_flutter/tarball/1b6b8a679f2c19a49f6b6e81be40f8a40f958362"],
)
```

No local rules checkout is needed.

Root `BUILD.bazel`:

```python
load("@rules_flutter_android//flutter:defs.bzl", "FLUTTER_ANDROID")
load("@rules_flutter_core//flutter:defs.bzl", "flutter_core")

flutter_core(
    name = "core",
    native_build_env = "@rules_flutter_android//flutter:native_build_env",
    platforms = [FLUTTER_ANDROID],
    pub = "@pub",
    visibility = ["//android/app:__pkg__"],
)
```

Create `android/app/BUILD.bazel`, using the activity source generated for this
application:

```python
load("@rules_flutter_android//flutter:defs.bzl", "flutter_android_app")
load("@rules_kotlin//kotlin:android.bzl", "kt_android_library")

flutter_android_app(
    name = "app",
    core = "//:core",
    manifest_values = {"applicationId": "com.example.hello_bazel"},
    plugins = None,
    deps = [":main_activity"],
)

kt_android_library(
    name = "main_activity",
    srcs = ["src/main/kotlin/com/example/hello_bazel/MainActivity.kt"],
    deps = [":app_inputs"],
)
```

Build the unsigned APK:

```sh
bazel build //android/app:app_unsigned.apk --lockfile_mode=update
```

Output: `bazel-bin/android/app/app_unsigned.apk`. Commit the generated
`MODULE.bazel.lock` and use `--lockfile_mode=error` for subsequent builds.

## Guides

- [Install and configure the rules](docs/install.md)
- [Run Dart and Flutter developer tools](docs/developer-tools.md)
- [Configure an Android app without plugins](docs/android-app.md)
- [Add Flutter plugins](docs/plugins.md)
- [Use path and Git dependencies or Pub workspaces](docs/pub-dependencies.md)
- [Configure recipes and Dart native assets](docs/native-assets.md)
- [Build and install Android variants](docs/android-builds.md)
- [Run Dart and Flutter host tests](docs/host-tests.md)
- [Run Android integration tests](docs/android-integration-tests.md)
- [Check supported versions and limitations](docs/compatibility.md)
