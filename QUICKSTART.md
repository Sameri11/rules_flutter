# rules_flutter consumer quickstart

Status: Community-maintained, Android-only development preview; not affiliated
with, endorsed by, or supported by Google or the Flutter project.

The ruleset has two modules: `rules_flutter_core` builds Flutter artifacts and
Dart/package/test outputs; `rules_flutter_android` composes those artifacts with
Android packaging. This guide shows the files and commands for a plugin-free app,
then explains plugin, monorepo, recipe, native-asset, test, and direct-binary
variants. See [README](README.md) for supported behavior and limitations.

## Choose a consumer shape

| Shape | Use it when | Working example |
| --- | --- | --- |
| Plugin-free root app | A flat app has no Android plugin graph. | [`examples/no_plugins`](examples/no_plugins/) |
| Root app with pub plugins | The app is at the module root and pub resolves Android plugins. | [`examples/pub_plugins`](examples/pub_plugins/) |
| Monorepo app with local path plugin | App and plugin are packages within one Bazel module. | [`examples/local_plugin`](examples/local_plugin/) |
| Consumer recipes / Dart native assets | Native build or dependency metadata needs consumer-authored instructions. | [`examples/demo_app`](examples/demo_app/) |
| Standalone install from an immutable archive | The app consumes the ruleset without a local rules checkout. | [`tests/archive_consumer`](tests/archive_consumer/) |

A normal CMake Android plugin uses automatic generation. A Package Recipe
replaces generation for its package; CMake contributions from other packages
remain available. Automatic generation does not cover `ndk-build` or plugins
whose Android half ships prebuilt JNI libraries.

## Prerequisites and configuration

Use the Flutter SDK version pinned by the repository CI workflow and the Bazel
version configured by that workflow. The checked CI hosts are macOS 15 arm64 and
Ubuntu Linux x64. The Android configuration below uses SDK API 36,
build-tools 36.0.0, and NDK 28 or newer. Flutter, Android SDK, and NDK are local,
non-hermetic inputs. Dart compilation is not incremental.

On Linux, `rules_foreign_cc` 0.16.0 builds its `pkgconf` tool from source for CMake native plugin halves. Bazel's auto-configured C toolchain compiles it with `gcc` from `PATH`, or with the compiler named by `CC`.

Set the SDK locations before building:

```sh
export FLUTTER_ROOT=/path/to/flutter
export PATH="$FLUTTER_ROOT/bin:$PATH"
export ANDROID_HOME="$HOME/Library/Android/sdk"
export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/<your-28-or-newer-version>"
```

The examples use Bzlmod and the checked-in `pubspec.lock`. Run `flutter pub get`
when changing dependencies, then commit the updated lock and generated plugin
state. Hosted packages are pinned by lockfile checksums; Git pub sources are
unsupported. Declare path dependency sources in `path_deps`.

An archive consumer owns its `.bazelrc`; the archive carries neither this
repository's root module nor its shared Android fragment. Write the settings
directly in the consumer's `.bazelrc`:

```text
common --enable_bzlmod

# rules_android requires JDK 17.
build --merge_android_manifest_permissions
build --tool_java_language_version=17 --tool_java_runtime_version=remotejdk_17
build --java_language_version=17 --java_runtime_version=remotejdk_17

# Forward the NDK path to repository rules instead of reading the action env.
common --repo_env=ANDROID_NDK_HOME
```

Release and ABI selection stay ordinary command-line configuration:
`-c opt`, `--@rules_flutter_core//flutter:mode=release` and
`--android_platforms=@rules_android//:arm64-v8a`. The checked example puts them
in its `.bazelrc`; either placement works.

The root `MODULE.bazel` declares both ruleset modules and the Flutter/pub
extensions. The working install path is one immutable commit archive: both
`archive_override` entries name the same URL and `sha256`, and differ only in
their `strip_prefix`, which selects each module's directory inside the extracted
tree. No local rules checkout is used.

```python
module(name = "hello_bazel", version = "0.0.1")

# Keep the Apple toolchain setup before rules that register C/C++ toolchains.
bazel_dep(name = "apple_support", version = "1.24.5")

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

flutter = use_extension("@rules_flutter_core//flutter:extensions.bzl", "flutter")
flutter.sdk(version = "3.47.3")
pub = use_extension("@rules_flutter_core//flutter:extensions.bzl", "pub")
pub.lock(name = "pub", lock = "//:pubspec.lock")
use_repo(pub, "pub")
include("//android:config.MODULE.bazel")
```

The digest fails the build during repository fetch if the downloaded archive
does not match, so a mistyped archive or a changed upstream tarball cannot
silently enter the graph.

A new consumer has no `MODULE.bazel.lock`. Generate it with the first real build
under `--lockfile_mode=update` (a `build` resolves the configured graph,
while `mod deps` can enumerate extensions a build never loads and leave the lock
incomplete), commit the resulting `MODULE.bazel.lock`, and use
`--lockfile_mode=error` from then on. Regenerate with `update` again only after
an intentional dependency change.

For development against a local checkout, keep the same `bazel_dep` lines and
replace each `archive_override` with `local_path_override(module_name = ...,
path = "../rules_flutter/rules_flutter_core")` (and the matching Android path).
The rest of the configuration is identical. Once the modules are published to a
registry, the `bazel_dep` lines resolve normally and the overrides are deleted;
do not remove the `bazel_dep` declarations.

Create `android/config.MODULE.bazel` and include it from the root module as
shown above. This Consumer Module owns Android SDK/NDK and Maven resolution. The
full AndroidX dependency closure below is the one used by the checked direct
consumer example; it is not a claim about the minimum classpath of every app.

```python
bazel_dep(name = "rules_android", version = "0.7.3")
bazel_dep(name = "rules_jvm_external", version = "7.1")
bazel_dep(name = "rules_cc", version = "0.2.17")
bazel_dep(name = "rules_kotlin", version = "2.4.0")
bazel_dep(name = "platforms", version = "1.0.0")

android_sdk = use_extension(
    "@rules_android//rules/android_sdk_repository:rule.bzl",
    "android_sdk_repository_extension",
)
android_sdk.configure(api_level = 36, build_tools_version = "36.0.0")
use_repo(android_sdk, "androidsdk")
register_toolchains("@androidsdk//:all")

android_ndk = use_extension("@rules_flutter_android//flutter:extensions.bzl", "android_ndk")
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

The archive install above is the checked path: keep both `bazel_dep`
declarations and supply the download through the two `archive_override` tags.
In-repository examples instead substitute a checkout with `local_path_override`;
do not copy such a path without adapting it. When the modules are published to a
registry, the overrides are removed and the same `bazel_dep` lines resolve from
the registry. See [`tests/archive_consumer`](tests/archive_consumer/) for the
complete standalone configuration: its `MODULE.bazel`, `.bazelrc`, `.bazelversion`
and committed lock.

## Build a plugin-free root app

Start from a Flutter Android project with `pubspec.yaml`, current
`pubspec.lock`, `lib/`, and `android/`. Commit the lockfile. If the project has no
assets, set `assets = []` explicitly. Create root `BUILD.bazel`:

```python
load("@rules_flutter_core//flutter:defs.bzl", "flutter_core")

package(default_visibility = ["//visibility:public"])

flutter_core(
    name = "core",
    srcs = glob(["lib/**/*.dart"]),
    assets = [],
    native_build_env = "@rules_flutter_android//flutter:native_build_env",
    pub = "@pub",
)
```

If a production package (including the app package) contains a staged
`hook/build.dart`, `flutter_core` requires `native_build_env` during analysis.
The Android environment shown above supplies the SDK needed by Flutter's native
build-hook runner. Dev-only dependencies do not trigger this requirement.
Host-test asset targets do not run native build hooks and need no app
environment.

Declare one `flutter_core` per Bazel package. It owns the package's app,
package, and test outputs. If the Consumer Module has a plugin graph, declare
`flutter_plugin_deps_guards` once in the package containing its committed Maven
segment. A plugin-free module does not need this guard macro.

Find the Flutter-generated activity under `android/app/src/main/kotlin/`, then
create `android/app/BUILD.bazel`:

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

The helper composes Flutter Android inputs, manifest, assets placement, and APK
check with a stock Android binary. It does not create a second packaging API.

Build release and debug with their supported compilation modes. The first
release build also writes `MODULE.bazel.lock`; commit it, then keep
`--lockfile_mode=error` for every later build:

```sh
# First build only: generate the lock, then commit MODULE.bazel.lock.
bazel build //android/app:hello_bazel -c opt --lockfile_mode=update \
  --android_platforms=@rules_android//:arm64-v8a
cp bazel-bin/android/app/hello_bazel.apk /tmp/hello-release-arm64.apk

# Subsequent release and debug builds.
bazel build //android/app:hello_bazel -c opt --lockfile_mode=error \
  --android_platforms=@rules_android//:arm64-v8a
cp bazel-bin/android/app/hello_bazel.apk /tmp/hello-release-arm64.apk

bazel build //android/app:hello_bazel -c fastbuild --lockfile_mode=error \
  --@rules_flutter_core//flutter:mode=debug \
  --android_platforms=@rules_android//:arm64-v8a
cp bazel-bin/android/app/hello_bazel.apk /tmp/hello-debug-arm64.apk
```


The supported ABIs are `arm64-v8a`, `x86_64`, and `armeabi-v7a`; 32-bit `x86`,
`riscv64`, and other values are unsupported. Explicitly pass
`--android_platforms` for the desired ABI platform targets unless your Bazel
configuration sets it.
Release uses `-c opt`; debug uses `-c fastbuild` plus Flutter debug mode. There
is no profile mode. Keep the APK label unchanged across ABI configurations.
Capture each APK before starting the next configuration because materialized
output paths may be shared.

Install the captured APK with `adb install -r <apk-path>`. For Flutter hot
reload, run the Bazel-built debug APK with
`flutter run -d <device-id> --debug --use-application-binary=<apk-path>`;
packaging changes require a Bazel rebuild.

## Standalone install from an archive

[`tests/archive_consumer`](tests/archive_consumer/) is a complete consumer that
builds only from one pinned archive, with no local rules checkout and no parent
repository configuration. Its `.bazelrc`, `MODULE.bazel`, `.bazelversion` and
`MODULE.bazel.lock` are the whole setup.

```sh
cd tests/archive_consumer
bazel build //:app_unsigned.apk \
  --lockfile_mode=error \
  --repo_env=ANDROID_NDK_HOME="$ANDROID_NDK_HOME" \
  --android_platforms=@rules_android//:arm64-v8a \
  -c opt --@rules_flutter_core//flutter:mode=release
```

This module already carries its committed `MODULE.bazel.lock`, so it builds
directly under `--lockfile_mode=error`; that is the difference from a fresh root
app, whose first build has to create the lock with `--lockfile_mode=update`. The
release `.bazelrc` already selects `-c opt`, release Flutter mode and the
`arm64-v8a` platform, so `bazel build //:app_unsigned.apk --lockfile_mode=error`
is equivalent. The module is pinned to the archive it names: it shows a known
distribution walking through archive resolution, not the rules in the current
checkout.

The two `archive_override` entries point at the same tarball URL and `sha256`;
their `strip_prefix` values select `rules_flutter_core` and
`rules_flutter_android` inside the extracted tree. A wrong digest, a missing
strip prefix or an unresolved dependency fails rather than silently building
different sources. To build against a local checkout instead, pass
`--override_module=sameri11_rules_flutter_core=<path>/rules_flutter_core` (and
the Android module) on the command line; the checked module file keeps the
archive as its only source.

## Plugins and generated state

For a pub plugin, add it to `pubspec.yaml`, run `flutter pub get`, and commit the
updated lock. For the first plugin graph, create placeholders only when absent:

```sh
test -e plugin_deps.MODULE.bazel || touch plugin_deps.MODULE.bazel
test -e lib/dart_plugin_registrant.dart || touch lib/dart_plugin_registrant.dart
```

`plugin_deps.MODULE.bazel` is the generated Maven dependency segment;
`lib/dart_plugin_registrant.dart` is the Dart registrant. Android Java
registrants are generated separately per mode: debug includes dev-only plugins,
while release excludes them. `plugins.project(name = ...)` names the generated
plugin hub. Its required `abis` list describes native plugin build coverage; it
does not choose the APK's ABI set. Choose each APK's contents with
`--android_platforms`.

For a plugin graph, the generated segment declares the Consumer Module's
`flutter_maven` install. Replace the plugin-free configuration's explicit
`maven.install(name = "flutter_maven", ...)` with the repository mapping below;
do not declare a second install with the same name. The segment supplies the
plugin and embedding coordinates and is included in the Android config fragment
that the root `MODULE.bazel` includes. The complete checked examples linked below
show this wiring.

```python
maven = use_extension("@rules_jvm_external//:extensions.bzl", "maven")
use_repo(maven, "flutter_maven")
include("//:plugin_deps.MODULE.bazel")
```

In the Consumer Module's Android configuration, configure the plugin hub:

```python
plugins = use_extension(
    "@rules_flutter_android//flutter:extensions.bzl",
    "flutter_plugins_ext",
)
plugins.project(
    name = "flutter_plugins",
    abis = ["arm64-v8a", "x86_64", "armeabi-v7a"],
    metadata = "@pub//:plugins_metadata.json",
    package_config = "@pub//:package_config.json",
    maven_repo = "@flutter_maven//:pin",
)
use_repo(plugins, "flutter_plugins")
```

In the root `BUILD.bazel`, load the standalone Maven guard once for the Consumer
Module's plugin graph:

```python
load("@rules_flutter_android//flutter:defs.bzl", "flutter_plugin_deps_guards")

flutter_plugin_deps_guards(plugins = "@flutter_plugins")
```

The hub derives the compile-only Flutter embedding from the selected Maven
repository. Consumers do not declare an embedding `java_import` or pass an
embedding target to the project tag. Generated plugin libraries compile
against this mode-correct embedding without adding a second runtime embedding
to the APK.



Include the generated Maven segment in the Consumer Module after configuring
its repository mapping. The guard macro creates check and update targets for
the segment, plus a test target that ensures the per-project guards agree.
Run the update target when the check reports drift. Core independently checks
the committed debug Dart registrant against pub metadata and prints its update
command when that file is stale.

The generator supplies package-scoped `BuildConfig` values for ordinary
source-built Android plugins. It does not parse Gradle `buildConfigField`
declarations; declare custom primitive or String fields in the Consumer Module's
plugin extension configuration with repeated `plugins.build_config_field` tags:

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

Supported types are `String`, `boolean`, `byte`, `short`, `int`, `long`,
`float`, and `double`. Strings are plain text, booleans are `true` or `false`,
and numbers are decimal literals. The only `value_from` source is
`package_version`; specify exactly one of `value` and `value_from`. Build logic
that needs Gradle evaluation or arbitrary expressions belongs in a Package
Recipe.

The generator handles ordinary Java/Kotlin and CMake plugin Android halves. Use
`plugins.package(artifacts = [...])` when a Maven coordinate cannot be inferred.
Use a Package Recipe when metadata requires Gradle evaluation, file I/O,
unsupported plugin-native build methods, or package-specific native asset
preparation. See [`examples/pub_plugins`](examples/pub_plugins/) and
[`examples/demo_app`](examples/demo_app/) for working plugin and recipe
configurations.

## Monorepo and path dependencies

Keep each app's `pubspec.yaml`, `pubspec.lock`, and `flutter_core` in the same
Bazel package. Declare every local path dependency's source files in
`path_deps`; Bazel does not infer or hash undeclared path contents. The example
[`examples/local_plugin`](examples/local_plugin/) places its host app under
`packages/host_app` and its plugin under `packages/greeter`. Create one core in
the app package and point the Android helper at that package-local target.

For example, the app core declares the plugin source target:

```python
flutter_core(
    name = "app",
    path_deps = ["//packages/greeter:srcs"],
    pub = "@pub",
)
```

Declare that source target inside the plugin package so it owns its glob:

```python
filegroup(
    name = "srcs",
    srcs = glob(["lib/**/*.dart"]) + ["pubspec.yaml"],
)
```


## Recipes and Dart native assets

A Package Recipe replaces standard generation for its package and can supply
native dependency metadata or ABI-keyed libraries. The APK ships only the ABI
selection from `--android_platforms`; recipe preparation may declare additional
ABIs where needed to prepare its inputs. Other packages' automatically generated
CMake contributions remain available.

A Dart native asset's `.so` must reach APK `lib/<abi>/`, not the Flutter assets
tree. Keep the bundle tree and native libraries as separate Android inputs; the
native-assets manifest remains in the bundle for runtime resolution. Use the
consumer recipe mechanism in [`examples/demo_app`](examples/demo_app/), which
shows recipe inputs and ABI-specific native contributions.

## Consumer-owned stock android_binary

A consumer may package core outputs with its own stock `android_binary`. The
four output groups are provided by `OutputGroupInfo` on a configured
`flutter_core` target; `FlutterArtifactInfo` is a separate typed provider, not
the output-group provider. Use `filegroup(output_group = ...)` to select the
outputs. `flutter_assets` is the asset tree, `flutter_engine` is the whole
selected engine-library set (which may contain multiple libraries for an ABI),
`flutter_libapp` is release AOT output and empty in debug, and
`flutter_embedding` is the selected mode's embedding jar. Use the mode-selecting
embedding output directly rather than a hard-coded Maven release label.

For example, one group can be selected from the configured core like this:

```python
filegroup(
    name = "direct_engine",
    srcs = [":core"],
    output_group = "flutter_engine",
)
```

Select the other three groups with the same pattern and their respective
`output_group` names. The checked fixture below shows those groups flowing into
the stock binary together with the mode-selected Java embedding and raw
ABI-pinned native inputs.

The checked stock-binary fixture is
[`tests/consumer/composed_app/BUILD.bazel`](tests/consumer/composed_app/BUILD.bazel),
target `//composed_app:direct_apk`. It shows group selection, mode-selected
embedding import with the explicit AndroidX dependency closure in
[`tests/consumer/embedding_deps.bzl`](tests/consumer/embedding_deps.bzl), raw
ABI-pinned native inputs, and a stock `android_binary`. The fixture's
`direct_native` helper is consumer-owned demonstration code, not a public ruleset
API. Android packaging owns normal JNI and strip handling; use the raw
ABI-pinned strip path as appropriate for the consumer's native files. Do not
assume a single engine `.so` or a minimal embedding classpath.

## ABI configuration and switching

Use one APK label for each existing app/mode variant. Select ABIs with ordinary
`--android_platforms`; do not encode ABI in the label or maintain suffixed
compatibility targets. Capture the APK artifact before switching to another
configuration. Release uses `-c opt`; debug uses `-c fastbuild` with Flutter
debug mode. Recipe preparation may require input coverage beyond the selected
APK ABI set.

One measured warm four-command sequence took 1.500 seconds with the former
suffixed labels and 16.165 seconds with the same label across successive ABI
configurations. These timings describe one machine/workflow, not a general
performance promise. Flutter/native actions remained reusable while Android
packaging reran. Disk/remote-cache switching speed was not measured; shared
materialized paths do not inherently imply action-cache collision.

## Host tests

`flutter_test` declares a host test target and `flutter_test_suite` groups host
tests. These use host-platform assets and do not require Android packaging or a
device. A `flutter_core` exposes package/test outputs for the package; keep tests
in that same Bazel package and declare their imports through the generated pub
hub. See `examples/no_plugins/BUILD.bazel` for the host test suite shape and
`examples/local_plugin` for package-scoped layouts.

For a suite that discovers all tests under `test/`, use the package test output:

```python
load("@rules_flutter_core//flutter:defs.bzl", "flutter_test_suite")

flutter_test_suite(
    name = "tests",
    srcs = glob(["test/**/*_test.dart"]),
    app = ":core_test_package",
)
```

Run it with `bazel test //:tests`. Use individual `flutter_test` targets when
tests need explicit `data`, materialization, or `dart_defines`; add those targets
to the suite's `tests` attribute as shown in
[`examples/demo_app/BUILD.bazel`](examples/demo_app/BUILD.bazel). Host tests
compile against host-platform assets and need no Android device. The pub hub
builds a shared debug kernel for packages imported by the tests. If an imported
package cannot compile in that shared kernel but should be compiled by a
particular test instead, the `pub.lock` tag's `test_deps_exclude` can exclude
that package from the shared kernel; the test still compiles its own direct
dependency.

The wildcard command `bazel test //...` retains Bazel's normal target universe:
it can also analyze non-test app artifacts, which require an Android app
configuration. Use `bazel test --build_tests_only //...` to select the tests
and their dependencies without unrelated non-test roots, or name a host suite
explicitly when running only host tests. Selected platform-dependent tests are
not filtered out and still need their platform configuration.
