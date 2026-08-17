# Consumer API test

A separate Bazel module that reaches these rules the way a real consumer does.

```sh
cd tests/consumer && bazel build --nobuild //...
```

It is **not** part of the root workspace's `//...`. It cannot be: a nested
`MODULE.bazel` is not a repo boundary, so without the root `.bazelignore` entry
Bazel would descend in and evaluate these packages as *root* packages, where
`local_path_override` never applies.


## What it covers

Loading and analysis — `--nobuild` — of every public symbol:

| file | symbols |
| --- | --- |
| `defs.bzl` | `dart_kernel`, `dart_aot_elf`, `flutter_aot_library`, `flutter_assets`, `pub_path_deps_check`, `pub_plugins_check` |
| `android.bzl` | `jni_lib_jar`, `android_native_lib_jar`, `strip_native_libs` |
| `bundle.bzl` | `flutter_bundle_contribution` (all three forms: `srcs`, slice-keyed `libraries`, `empty`), the location constants |
| `android.bzl` (join) | `flutter_android_libs` over **two** ABIs, and `flutter_android_binary` on top of it — the entry point that names a consumer's APK targets |
| `recipe.bzl` | `flutter_native_contribution` (both the populated and `empty = True` forms), `flutter_native_libs` |

That catches the two things a refactor of these rules actually breaks: a symbol
moving between files (load phase) and an attribute renamed, removed or made
mandatory (analysis phase). Both were verified by being made to fail.

The join is instantiated over **two** ABIs, so its per-ABI shape is exercised
rather than collapsing to the single-entry case. It passes `engine_jars`, which
a real consumer never does: left to the ABI table the join names the real engine
repositories, and analysing one downloads ~150 MB — into a test whose whole
point is that it costs under two seconds and fetches nothing.

Attributes are named explicitly rather than left to defaults — `target_os`,
`strip`, `mode` — because a default that disappears is exactly the kind of
change this is meant to notice.

## What it does not cover

- **Behaviour.** The fixtures are stubs; nothing here is meant to build. The
  root workspace's `app/` and the `smooth_app` consumer cover that.
- **`embedding.bzl`**, whose macros resolve Maven coordinates from the consuming
  project's own list.
- **The generated `@flutter_plugins` repo.** `plugins.bzl` passes the label of
  `android.bzl` and `recipe.bzl` into that repo, and those labels have already
  been broken once by a rename. Reaching that path needs a real plugin graph:
  `.flutter-plugins-dependencies` carries **absolute** paths into `~/.pub-cache`
  and package_config's `rootUri` is a `file://` URI, so a checked-in fixture
  cannot be portable — it would need a repository rule that synthesises both at
  fetch time, plus a fake plugin tree with an `android/build.gradle` and a
  `CMakeLists.txt`. `smooth_app` exercises this for real today.
