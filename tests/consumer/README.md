# Consumer API test

A separate Bazel module that reaches these rules the way a real consumer does,
combining API coverage with focused behavior checks.

```sh
cd tests/consumer
bazel build --nobuild -c opt --lockfile_mode=error --repo_env=ANDROID_NDK_HOME="$ANDROID_NDK_HOME" --android_platforms=@rules_android//:arm64-v8a //:analysis_only
bazel build --nobuild --build_tests_only -c opt --lockfile_mode=error --repo_env=ANDROID_NDK_HOME="$ANDROID_NDK_HOME" --android_platforms=@rules_android//:arm64-v8a //...
bazel test --build_tests_only -c opt --repo_env=ANDROID_NDK_HOME="$ANDROID_NDK_HOME" --android_platforms=@rules_android//:arm64-v8a //...
```

The real prerequisite is an **installed NDK named by `ANDROID_NDK_HOME`**, not the
flag. This module owns its Android toolchains in `android/config.MODULE.bazel`,
where it imports and registers both SDK and NDK repositories. The composed
native strip targets resolve the C++ toolchain through the registered NDK.

With no NDK the failure now happens where the path is required, at the upstream
repository fetch:

    Error in fail: Either the ANDROID_NDK_HOME environment variable or the path
    attribute of android_ndk_repository must be set.

That is intentional. The module extension declares the same repositories in every
environment and reads no environment variable, so committed locks stay portable;
only repository evaluation looks for the NDK. `--repo_env` **explicitly forwards**
the variable, and is recommended for reproducibility rather than required: an
exported `ANDROID_NDK_HOME` works on its own, and naming it on the command line
makes the input deterministic instead of shell-dependent, which matters most in
CI. It cannot substitute for the NDK: unset, it forwards an empty value and the
fetch failure above appears. It is passed here rather than added to this module's
`.bazelrc`, which deliberately carries only the three flags an APK build needs
and not the ruleset's whole Android group.

`tools/ci/android_toolchain_probe.py` exercises Android toolchain ownership
directly, one scenario per invocation. Each is one command, and CI runs all of
them:

```sh
python3 tools/ci/android_toolchain_probe.py --scenario analysis
python3 tools/ci/android_toolchain_probe.py --scenario inventory
python3 tools/ci/android_toolchain_probe.py --scenario compile-probe
python3 tools/ci/android_toolchain_probe.py --scenario missing-ndk
python3 tools/ci/android_toolchain_probe.py --scenario lock-portability
python3 tools/ci/android_toolchain_probe.py --scenario core-isolation
```

`lock-portability` generates a disposable Android Consumer, resolves it twice in
separate scratch state with `ANDROID_NDK_HOME` unset and set, and requires
byte-identical locks that name neither the variable nor the local NDK path.
`core-isolation` uses `tests/core_consumer`; the others use this fixture.

It is **not** part of any `//...` target set. The repository root has no module,
so no `bazel test //...` reaches it: it is a separate module with its own
`MODULE.bazel`, and its `local_path_override` entries resolve against that module's graph.


## What it covers

Loading and analysis — `--nobuild` — of every supported BUILD symbol through the
core and Android entrypoints below, plus focused behavior checks:

| entry point | symbols |
| --- | --- |
| `@rules_flutter_core//flutter:defs.bzl` | `flutter_core`, `flutter_package`, `flutter_pubspec`, `flutter_test`, `pub_path_deps_check`, `pub_plugins_check` |
| `@rules_flutter_android//flutter:defs.bzl` | `flutter_android_app`, `flutter_android_inputs`, `flutter_apk_check`, `flutter_assets`, `flutter_assets_dir`, `flutter_android_manifest`, `flutter_native_contribution`, `flutter_plugin_deps_guards` |
| `@rules_flutter_android//flutter:extensions.bzl` | `flutter_plugins_ext` (`plugins.project()`/`plugins.package()`/`plugins.build_config_field()`) over real, checked-in external plugin graphs — `:fake_plugin_deps_check`, `:fake_plugin_test`, `:namespace_plugin_test`, `:build_config_plugin_jar_test`, `:build_config_plugin_values_test` |

Remaining implementation rules and helpers are covered indirectly by the
supported macros; the Consumer BUILD file loads no private implementation file.

That catches the two things a refactor of these rules actually breaks: a symbol
moving between files (load phase) and an attribute renamed, removed or made
mandatory (analysis phase). Both were verified by being made to fail.

`//composed_app:native_files_test` checks the generated carrier for all three
ABIs, including automatic CMake and recipe libraries, a recipe override, and
debug-only native plugin filtering. Run it in both debug and release modes.
`//composed_app:apk_override_contents_test` checks the override APK's native
library contents.

`//composed_app:direct_apk` exercises a consumer-owned stock Android binary
using the four `flutter_core` output groups directly. Its selected engine
libraries are stripped with the Android toolchain, its plugin libraries come
from the raw per-ABI file aggregate, and its embedding is a mode-selected Java
import with the explicit AndroidX closure. The fixture also packages the
three-ABI synthetic AAR and compiles a Kotlin Flutter activity. This route does
not depend on the Android inputs helper.

`flutter_android_app` remains covered with plugin and plugin-free apps, a
second app variant reusing inputs, and an app from an external module.
`//apk_external_app_contents_test` checks that the external app's declared asset
lands at its runtime path.

Neither this module nor `external_app` owns a `flutter` package. A `select()`
key inside a ruleset macro that regresses from `Label("//flutter:mode_debug")`
to a bare string resolves in the caller's repository, so it fails analysis here
with `no such package` under every mode instead of silently picking a branch.
Verified by planting both the kernel and embedding keys.

`flutter_core` is instantiated in `//standard_layout`, a second package whose
contents follow the layout `flutter create` leaves behind: `pubspec.yaml`,
`pubspec.lock`, `lib/main.dart`, and one asset. Its package config is the
`@standard_layout_pub` hub of that lock. It permanently selects
`lib/alternate$release.dart`; this covers the nondefault entrypoint without
shell expansion. The root fixture also declares one core and exercises both
plugin and plugin-free packaging.

`fixtures/fake_plugin` is an external Flutter plugin layout, and the four
`fixtures/namespace_*` directories are plugin layouts dedicated to namespace
syntax coverage. They are not in any `pubspec.lock`, so no `pub.lock` hub
describes them. `fixtures/plugin_fixture.bzl` is a small repository rule that
generates the two files `plugins.project` reads (`plugins_metadata.json`,
`package_config.json`). Android's plugin project generates the Java registrants
from that metadata. `fake_plugin` also implements the `ping` method channel
invoked by the `consumer_rules_r8` fixture; its launcher activity lives under
`fixtures/consumer_rules/`.

This proves two
things nothing else here can, because this module reaches the ruleset the
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
  the ruleset's own root `rive_native`/`sqlite3` recipes the moment it
  called `plugins.project()`, because the ruleset shipped a demo app inside its
  own module. That app is now `//examples/demo_app`, a separate module absent
  from this graph, so nothing is inherited and the case is declared on purpose.
  Better coverage, not merely restored coverage — it no longer depends on the
  ruleset having an app inside it.
- Generated plugin coordinates resolve through the canonical repository selected
  by `plugins.project`, not the ruleset's apparent `@flutter_maven`. The Consumer
  Module includes the generated `plugin_maven` segment; `fake_plugin` depends on
  a coordinate present only there, and the root project selects
  `@plugin_maven//:pin`. `external_app` imports that same repository as
  `@plugin_maven_alias`; its `maven_alias_inputs` target proves the helper accepts
  a distinct apparent name for the same canonical repository.
- `:fake_plugin_test` builds the generated `fake_plugin` target with an override
  of its scraped `androidx.annotation:annotation-experimental` coordinate.
  `:fake_plugin_deps_check` verifies the committed install segment carries
  version `1.4.0`, not the Gradle version `1.4.1`. Appending the override beside
  the scraped coordinate instead would duplicate the versionless deps label and
  fail analysis. `recipe_plugin` uses this coordinate too and gets the same pin
  to keep the shared install aligned.
- Four namespace parser fixtures use bare Android manifests and source packages
  that each reference its own `R.string.namespace_<case>_marker`; `:namespace_plugin_test`
  builds all four generated targets, making javac observe the exact namespace
  emitted as `custom_package` rather than accepting a manifest fallback.
- `fixtures/build_config_plugin` disables AGP BuildConfig generation and reads
  Bazel's generated built-ins plus custom fields of every supported primitive
  type. The release and debug runtime tests prove mode-sensitive built-ins,
  typed values, and `package_version`; `build_config_probe.py` separately proves
  all invalid declarations fail repository evaluation with the responsible
  package and field in the diagnostic:

  ```sh
  python3 build_config_probe.py
  ```

## What it does not cover

- **General runtime behaviour.** Most fixtures remain stubs and are analysed
  only. Focused runtime coverage is limited to the `consumer_rules_r8` method
  channel call, `:apk_no_plugin_graph` bundle check, and
  `:apk_external_app` content check. `//examples/demo_app` and smooth_app cover
  broader pluginful behaviour.
- **The generated `@flutter_plugins` repo's CMake path.** `fixtures/fake_plugin`
  (below) reaches the repository-free, non-native half of that path — a plain
  `android_library` plugin with one Maven coordinate. It declares no
  `externalNativeBuild`, so the declared NDK marker and CMake cross-compile
  chain stay unreached. `//examples/demo_app` and smooth_app
  cover that.
