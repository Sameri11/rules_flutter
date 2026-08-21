# Consumer API test

A separate Bazel module that reaches these rules the way a real consumer does,
combining API coverage with focused behavior checks.

```sh
cd tests/consumer
bazel build --nobuild //...            # load + analysis of every public symbol
bazel test --build_tests_only //...    # the focused behaviour checks
```

It is **not** part of the root workspace's `//...`. It cannot be: a nested
`MODULE.bazel` is not a repo boundary, so without the root `.bazelignore` entry
Bazel would descend in and evaluate these packages as *root* packages, where
`local_path_override` never applies.


## What it covers

Loading and analysis — `--nobuild` — of every public symbol, plus focused
behavior checks:

| file | symbols |
| --- | --- |
| `defs.bzl` | `dart_kernel`, `dart_aot_elf`, `flutter_aot_library`, `flutter_assets`, `pub_path_deps_check`, `pub_plugins_check`, `flutter_app` |
| `android.bzl` | `jni_lib_jar`, `android_native_lib_jar`, `strip_native_libs` |
| `bundle.bzl` | `flutter_bundle_contribution` (all three forms: `srcs`, slice-keyed `libraries`, `empty`), the location constants |
| `android.bzl` (join) | `flutter_android_libs` over **two** ABIs, and `flutter_android_binary` on top of it — the entry point that names a consumer's APK targets; `:apk_external_app` drives that high-level API from an external module through a real bundle and signed APK |
| `recipe.bzl` | `flutter_native_contribution` (both the populated and `empty = True` forms), `flutter_native_libs` |

That catches the two things a refactor of these rules actually breaks: a symbol
moving between files (load phase) and an attribute renamed, removed or made
mandatory (analysis phase). Both were verified by being made to fail.

The join is instantiated over **two** ABIs, so its per-ABI shape is exercised
rather than collapsing to the single-entry case. It passes `engine_jars`, which
a real consumer never does: left to the ABI table the join names the real engine
repositories, and analysing one downloads ~150 MB — into a test whose whole
point is that it costs under two seconds and fetches nothing.

`flutter_android_binary` appears five times, on purpose:

- `:apk` names **every** attribute, defaults included — a default that
  disappears is exactly the kind of change this module exists to notice;
- `:apk_derived` uses the short spelling, `app = "//:app"`, so the derivation of
  `aot`, `assets` and `pubspec` from one package label is analysed;
- `:apk_no_plugin_natives` passes `plugin_native_libs = {}`, the declaration an
  app with no native plugin half makes. It cannot be derived, and this pins that
  `{}` keeps meaning "none" rather than "derive";
- `:apk_no_plugin_graph` derives its Dart targets from `//standard_layout`,
  passes `plugins = None`, and uses the production
  `flutter_embedding_library`. Analysis proves that this suppresses every
  `@flutter_plugins` edge — classes, recipe libraries, native plugin libraries
  and registrant — while retaining the engine embedding's real AndroidX graph
  from this fixture's `@flutter_maven` install.
- `:apk_external_app` derives every Dart target from
  `@external_app//app`; its generated bundle check and
  `:apk_external_app_contents_test` build the signed APK and inspect the
  external module's declared asset at its runtime path.

Attributes are named explicitly rather than left to defaults — `target_os`,
`strip`, `mode`, `abi`, `slice` — for the same reason.

`flutter_app` is instantiated in **`//standard_layout`**, a second package whose
contents are the layout `flutter create` and `flutter pub get` leave behind:
`pubspec.yaml`, `pubspec.lock`,
`.dart_tool/{version,package_graph.json,package_config.json}`, `lib/main.dart`,
and one asset. It permanently selects `lib/alternate$release.dart`; execution
covers the nondefault `flutter_assets.entrypoint` without shell expansion, and
smooth_app executes the same nondefault-entrypoint shape.

It passes `plugin_deps = None`, the Dart half of a project that never calls
`plugins.project()`. The root package pairs it with
`flutter_android_binary(plugins = None)`, which removes every
`@flutter_plugins` label from the APK graph. This does not remove the Flutter
embedding's Maven dependencies: `MODULE.bazel` declares
`rules_jvm_external` 7.1, creates `maven.install(name = "flutter_maven", ...)`
with the complete embedding coordinate list, and imports it with
`use_repo(maven, "flutter_maven")`.

## What it does not cover

- **General runtime behaviour.** Most fixtures remain stubs and are analysed
  only. The exceptions are `:apk_no_plugin_graph`, which builds a real signed
  APK and runs its bundle check to prove the repository-free contribution shape
  and real embedding Maven dependency graph, and `:apk_external_app`, whose
  content test reads its external module's marker from the signed APK. Root
  `app/` and smooth_app cover pluginful behaviour.
- **The generated `@flutter_plugins` repo.** `plugins.bzl` passes the label of
  `android.bzl` and `recipe.bzl` into that repo, and those labels have already
  been broken once by a rename. Reaching that path needs a real plugin graph:
  `.flutter-plugins-dependencies` carries **absolute** paths into `~/.pub-cache`
  and package_config's `rootUri` is a `file://` URI, so a checked-in fixture
  cannot be portable — it would need a repository rule that synthesises both at
  fetch time, plus a fake plugin tree with an `android/build.gradle` and a
  `CMakeLists.txt`. `smooth_app` exercises this for real today.
