# Consumer API test

A separate Bazel module that reaches these rules the way a real consumer does,
combining API coverage with focused behavior checks.

```sh
cd tests/consumer
bazel build --nobuild --repo_env=ANDROID_NDK_HOME="$ANDROID_NDK_HOME" //...
bazel test --build_tests_only --repo_env=ANDROID_NDK_HOME="$ANDROID_NDK_HOME" //...
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
| `@rules_flutter_android//flutter:defs.bzl` | `flutter_android_app`, `flutter_android_inputs`, `flutter_apk_check`, `flutter_assets`, `flutter_assets_dir`, `flutter_android_manifest`, `flutter_native_contribution` |
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
writes the two hub files `plugins.project` reads (`plugins_metadata.json`,
`package_config.json`) for this fixture set.

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
- A generated plugin's Maven coordinate resolves through the **canonical**
  repository `plugins.project(maven_repo = ...)` named, not through whichever
  repository happens to be named `@flutter_maven` in the ruleset's own
  mapping. `MODULE.bazel` declares a second, distinctly-named install,
  `plugin_maven`, containing a coordinate absent from every `flutter_maven`
  install in the graph; `fake_plugin`'s `build.gradle` depends on it, and
  `plugins.project(maven_repo = "@plugin_maven//:pin")` names it.
  `:fake_plugin_test` builds the generated `@flutter_plugins//fake_plugin`
  target, which only resolves that dependency if `maven_repo` was actually
  threaded through to `maven_label()` rather than a hardcoded apparent name.
- Four namespace parser fixtures use bare Android manifests and source packages
  that each reference `R.string.namespace_marker`; `:namespace_plugin_test`
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
  only. The exceptions are `:apk_no_plugin_graph`, which builds a real signed
  APK and runs its bundle check to prove the repository-free contribution shape
  and real embedding Maven dependency graph, and `:apk_external_app`, whose
  content test reads its external module's marker from the signed APK.
  `//examples/demo_app` and smooth_app cover pluginful behaviour.
- **The generated `@flutter_plugins` repo's CMake path.** `fixtures/fake_plugin`
  (below) reaches the repository-free, non-native half of that path — a plain
  `android_library` plugin with one Maven coordinate. It declares no
  `externalNativeBuild`, so the declared NDK marker and CMake cross-compile
  chain stay unreached. `//examples/demo_app` and smooth_app
  cover that.
