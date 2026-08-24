# Consumer API test

A separate Bazel module that reaches these rules the way a real consumer does,
combining API coverage with focused behavior checks.

```sh
cd tests/consumer
bazel build --nobuild --repo_env=ANDROID_NDK_HOME="$ANDROID_NDK_HOME" //...
bazel test --build_tests_only --repo_env=ANDROID_NDK_HOME="$ANDROID_NDK_HOME" //...
```

The real prerequisite is an **installed NDK named by `ANDROID_NDK_HOME`**, not the
flag. `//...` here includes `:apk_derived_flutter_engine_<abi>_stripped`, and
stripping resolves `@@bazel_tools//tools/cpp:toolchain_type`; with no NDK,
`@flutter_bazel//tools/flutter:ndk.bzl` substitutes its toolchain-less stub and
analysis fails:

    No matching toolchains found for types:
      @@bazel_tools//tools/cpp:toolchain_type

`--repo_env` **explicitly forwards** that variable, and is recommended for
reproducibility rather than required. `ndk.bzl` declares `environ =
["ANDROID_NDK_HOME"]` on its extension, so `module_ctx.getenv` reads the client
environment and an exported variable works on its own — measured: the plain
`bazel build --nobuild //...` succeeds with it exported. Naming it on the command
line makes the input explicit and deterministic instead of depending on whatever
the invoking shell holds, which matters most in CI.

It cannot substitute for the NDK. With `ANDROID_NDK_HOME` unset the flag forwards
an empty value, the stub is still selected and the same toolchain error appears —
also measured. It is passed here rather than added to this module's `.bazelrc`,
which deliberately carries only the three flags an APK build needs and not the
ruleset's whole Android group.

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
| `plugins.bzl` | `flutter_plugins_ext` (`plugins.project()`/`plugins.package()`) over a real, checked-in external plugin graph — `:fake_plugin_deps_check`, `:fake_plugin_test` |

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

`fixtures/fake_plugin` is a third package layout: a minimal external Flutter
plugin, wired up via `plugins.project()` in `MODULE.bazel`. Unlike the
fixtures above, its two pub-written inputs
(`.flutter-plugins-dependencies`/`package_config.json`) cannot be checked in
verbatim — both carry **absolute** `file://` paths into `~/.pub-cache`, unique
to whichever machine ran `pub get`. `fixtures/plugin_fixture.bzl` is a small
repository rule that synthesizes both at fetch time from `fake_plugin`'s real
on-disk location, so the pair stays correct on any checkout. This proves two
things nothing else here can, because this module reaches `flutter_bazel` the
same way `hello_bazel` and `smooth-app` do and those two are external to this
repository:

- A `plugins.package()` recipe a *dependency* registers for a package this
  project does not have is ignored, not `fail()`-ed on.
  `external_app/MODULE.bazel` registers one — `absent_package` — and
  `:fake_plugin_deps_check` builds clean while printing the notice naming it.
  `external_app/absent_package.bzl` **cannot be loaded**: its `load()` asks
  `recipe.bzl` for a symbol that does not exist, so if the attribution ever
  regresses and a dependency's unmatched recipe gets loaded rather than dropped,
  that load is the failure. Without that, "builds clean" would be consistent
  with the recipe having been loaded and simply working, which asserts nothing.
  Verified in both directions: registering the same kind of recipe from the
  **root** module still fails with `plugins.package() registered a recipe for
  ..., but no such package is in the resolution`.

  This case used to arrive for free: every consumer inherited
  `flutter_bazel`'s own root `rive_native`/`sqlite3` recipes the moment it
  called `plugins.project()`, because the ruleset shipped a demo app inside its
  own module. That app is now `//examples/demo_app`, a separate module absent
  from this graph, so nothing is inherited and the case is declared on purpose.
  Better coverage, not merely restored coverage — it no longer depends on the
  ruleset having an app inside it.
- A generated plugin's Maven coordinate resolves through the **canonical**
  repository `plugins.project(maven_repo = ...)` named, not through whichever
  repository happens to be named `@flutter_maven` in `flutter_bazel`'s own
  mapping. `MODULE.bazel` declares a second, distinctly-named install,
  `plugin_maven`, containing a coordinate absent from every `flutter_maven`
  install in the graph; `fake_plugin`'s `build.gradle` depends on it, and
  `plugins.project(maven_repo = "@plugin_maven//:pin")` names it.
  `:fake_plugin_test` builds the generated `@flutter_plugins//fake_plugin`
  target, which only resolves that dependency if `maven_repo` was actually
  threaded through to `maven_label()` rather than a hardcoded apparent name.

## What it does not cover

- **General runtime behaviour.** Most fixtures remain stubs and are analysed
  only. The exceptions are `:apk_no_plugin_graph`, which builds a real signed
  APK and runs its bundle check to prove the repository-free contribution shape
  and real embedding Maven dependency graph, and `:apk_external_app`, whose
  content test reads its external module's marker from the signed APK.
  `//examples/demo_app` and smooth_app cover pluginful behaviour.
- **The generated `@flutter_plugins` repo's CMake path.** `fixtures/fake_plugin`
  (below) reaches the repository-free, non-native half of that path — a plain
  `android_library` plugin with one Maven coordinate. It declares no
  `externalNativeBuild`, so `_ndk_root`'s toolchain check and the CMake
  cross-compile chain stay unreached. `//examples/demo_app` and smooth_app
  cover that.
