# Android builds

For installation and consumer module configuration, see [Install](install.md) and [Android app setup](android-app.md). Plugin composition is covered in [Plugins](plugins.md).

## Package a debug test APK as the app

`flutter_android_app` can add one APK per `test_apps` entry. This APK is for launching a debug kernel as an app; it is distinct from the Android integration-test APK and its test runner described in [Android integration tests](android-integration-tests.md). It inherits the app's Android dependencies, manifest values, resources, plugin setup and `flutter_android_inputs`, but runs the entry's debug kernel. The `test_apps` key is appended to the app target name:

This example is the app target in `android/app/BUILD.bazel`; `//:core` is the root package's Flutter core.
```python
load("@rules_flutter_core//flutter:composition.bzl", "flutter_debug_core")
load("@rules_flutter_android//flutter:defs.bzl", "FLUTTER_ANDROID", "FLUTTER_DEBUG_UNCOMPRESSED_ASSETS", "flutter_android_app")

_DEFINES = {"FLAVOR": "integration"}
_TEST = {"testonly": True, "proguard_specs": []}

flutter_android_app(
    name = "hello_bazel",
    core = "//:core",
    manifest_values = {"applicationId": "com.example.hello_bazel"},
    plugins = None,
    deps = [":main_activity"],
    nocompress_extensions = [".so"] + select({
        "@rules_flutter_core//flutter:mode_debug": FLUTTER_DEBUG_UNCOMPRESSED_ASSETS,
        "@rules_flutter_core//flutter:mode_release": [],
    }),
    test_apps = {
        "smoke": _TEST | {
            "entrypoint": "//integration_test:smoke.dart",
            "srcs": ["//integration_test:helper.dart"],
            "dart_defines": _DEFINES | {"TEST_MARK": "smoke"},
        },
        "prebuilt": {
            "core": ":prebuilt_core",
            "manifest_values": {"applicationId": "com.example.hello_bazel"},
        },
    },
)

flutter_debug_core(
    name = "prebuilt_core",
    app = "//:core",
    entrypoint = "//integration_test:prebuilt.dart",
    srcs = ["//integration_test:helper.dart"],
    platforms = [FLUTTER_ANDROID],
    dart_defines = _DEFINES | {"TEST_MARK": "prebuilt"},
)
```

`FLUTTER_DEBUG_UNCOMPRESSED_ASSETS` names the debug kernel and snapshots. By default the app rule keeps `.so` files uncompressed and keeps Flutter debug assets uncompressed only in debug; the explicit `nocompress_extensions` override above preserves that mode-specific behavior. The `applicationId` must match the app for the test APK to replace it. This declares `:hello_bazel_smoke`, its debug core `:hello_bazel_smoke_core`, and `:hello_bazel_smoke_check_test`. A macro-core entry needs `entrypoint` and defaults `app` to the app's core; set `app` explicitly when the app uses prebuilt `inputs`. The prebuilt entry names a `flutter_debug_core` target directly and can be declared in another Bazel package. That target is debug-only and `manual` by default; its `platforms` are required and its `dart_defines` are not inherited from the app. `srcs` must include imported files outside the app's `lib/`. Both test APK entries can merge shared Android settings such as `proguard_specs`.

`integration_test/BUILD.bazel` must export Dart files used across the package boundary so `//android/app` can reference them:

```python
exports_files(["smoke.dart", "prebuilt.dart", "helper.dart"], visibility = ["//android/app:__pkg__"])
```

For the alternative colocated-core layout, see the checked [`examples/no_plugins/android/app/BUILD.bazel`](../examples/no_plugins/android/app/BUILD.bazel) and [`examples/no_plugins/integration_test/BUILD.bazel`](../examples/no_plugins/integration_test/BUILD.bazel).

## Consumer-owned stock `android_binary`

Use the convenience rules from `defs.bzl` for standard apps. A consumer that needs to own Android packaging can combine the public building blocks: `flutter_core` exposes the `flutter_assets` and `flutter_aot` output groups; Android engine libraries come from `@rules_flutter_android//flutter:engine_libs`. Declare the platform with `flutter_core(platforms = [FLUTTER_ANDROID])`.

Android app assets resolve the core under the first `--android_platforms` value, or the first `FLUTTER_ANDROID` target platform when that flag is unset. Hand-wired selects follow the requesting target's platform configuration and default to the first descriptor.

The Android composition module provides `flutter_plugin_registrant`, `flutter_build_config`, and the mode-selected `embedding_jar`; use `flutter_embedding_deps(maven_repo)` for the embedding's explicit AndroidX classpath. Here `flutter_assets` is `flutter_core`'s output group, not the `flutter_assets` rule. Stock `rules_android` rules then package those targets; for native packaging, see the checked [`tests/consumer/composed_app:direct_apk`](../tests/consumer/composed_app/BUILD.bazel) fixture.

[`tests/consumer/hand_wired_app/BUILD.bazel`](../tests/consumer/hand_wired_app/BUILD.bazel) demonstrates plugin, Java, and Maven wiring without plugin extensions or convenience macros; it is not a complete APK because it does not package the Flutter native libraries. The registrant and build-config rules each produce one Java source file suitable for `android_library.srcs`, and development plugin code is included only in debug. Consumers using Kotlin Multiplatform Maven artifacts must name the platform artifact (such as an `-jvm` artifact) because `rules_jvm_external` does not resolve Gradle module metadata.

Hand-wired registrants default to alphabetical order. Set `order` to list plugin names in registration order; unlisted plugins follow alphabetically. Set `release_order` only when release needs a different order.

## ABI configuration and switching

Supported Android ABIs are `arm64-v8a`, `x86_64`, and `armeabi-v7a`; 32-bit `x86`, `riscv64`, and other values are unsupported. Select ABIs with ordinary `--android_platforms`; explicitly pass the desired ABI platform targets unless your Bazel configuration sets them. Use one APK label for each existing app/mode variant; do not encode ABI in the label or maintain suffixed compatibility targets. Separate build commands select fat or single-ABI configurations. Capture the APK artifact before switching to another configuration because materialized output paths may be shared.

Release uses `-c opt`; debug uses `-c fastbuild` plus `--@rules_flutter_core//flutter:mode=debug`. There is no profile mode. Recipe preparation may require input coverage beyond the selected APK ABI set. Debug APKs are debug-key-signed; release produces an unsigned APK, with signing outside Bazel. Dart compilation is not incremental. Packaging changes require a Bazel rebuild. For Flutter hot reload, run `bazel run @rules_flutter_core//flutter -- run -d <device-id> --debug --use-application-binary=<apk-path>`.

A measured warm four-command sequence took 1.500 seconds with former suffixed labels and 16.165 seconds with the same label across successive ABI configurations. These timings describe one machine/workflow, not a general performance promise. Flutter/native actions remained reusable while Android packaging reran. Disk/remote-cache switching speed was not measured; shared materialized paths do not inherently imply action-cache collision.
