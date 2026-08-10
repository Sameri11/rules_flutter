# flutter_bazel

Bazel rules that build the **Dart half** of a Flutter app directly — driving
`frontend_server` and `gen_snapshot` rather than shelling out to `flutter build`.

The premise: a Flutter build is not one monolithic step. It decomposes at a
natural seam.

```
lib/**.dart ──frontend_server──> app.dill ──gen_snapshot──> libapp.so ─┐
                                                                       ├─> APK/IPA
libflutter.so (prebuilt engine) ───────────────────────────────────────┤
flutter_assets ────────────────────────────────────────────────────────┘
       \_____ Dart half (this repo) _____/    \__ platform half (not yet) __/
```

Everything left of `libapp.so` is what these rules cover. The right-hand side is
ordinary Android/iOS packaging that `rules_android` / `rules_apple` already do,
consuming `libapp.so` as a plain prebuilt `.so`.

## Status

Working and verified on Flutter 3.44.2 / Dart 3.12.2, Bazel 9.2.0, macOS arm64,
target `android-arm64-release`.

```
bazel build //app:app_arm64-v8a ->  bazel-bin/app/app_arm64-v8a/libapp.so  (aarch64 ELF, stripped)
bazel build //app:assets       ->  .../app/assets/flutter_assets/  (tree artifact)
bazel build //app/android/app:demo_app -> …/demo_app.apk  (signed APK)
```

**Note:** two packages that fall outside the standard build — `rive_native`
(native half downloaded, not compiled) and `sqlite3` (a Dart build hook) — are
built by **consumer-supplied recipes**. See "Package recipes" below.

Verified properties:

- **Matches the reference.** Both `libapp.so` and the asset bundle are
  byte-identical (sha256) to the same pipeline driven by hand outside Bazel.
- **Reproducible.** `gen_snapshot --deterministic` yields a stable hash across
  repeated runs. The asset bundle likewise, once `.last_build_id` is dropped.
- **Correctly incremental.** No-op rebuild ~40-80 ms. Editing a `.dart` source,
  an asset, or a declared `path:` dependency invalidates correctly; reverting
  restores the original hash exactly.
- **Release/debug split.** Release actions are remote-cacheable; debug actions
  are pinned local. Debug uses the non-product SDK and ships `kernel_blob.bin`.
- **Undeclared `path:` deps are caught**, not merely documented — see
  `//app:path_deps_check`.
- **Plugins build from source**, including their Maven dependencies, resolved by
  `rules_jvm_external` with no Gradle involved. Plugins whose coordinates cannot
  be read statically are refused by a reason-coded gate rather than mis-built.
  Both halves of registration are wired: the native `GeneratedPluginRegistrant`
  and the Dart one federated plugins need. A plugin whose `build.gradle` drives
  **CMake** also gets its own `CMakeLists` compiled against the NDK, with the
  resulting `.so` riding the same path into the APK as `libapp.so`. Verified
  with `connectivity_plus`, `image_picker` and `rive_common` (~1400 C/C++
  sources, Kotlin Android half) all calling through to the platform and back in
  one APK.

- **The APK is stripped**, the way AGP's `stripDebugSymbolsRelease` does it for
  a Gradle build: 183 MB to 22 MB, almost all of it the engine's DWARF.

- **The APK runs.** `//app/android/app:demo_app` was installed on an arm64 API 35
  emulator and launched: `Fully drawn +1s243ms`, no fatal exceptions, and the
  counter increments on tap. The app bar reads "hello from mylib v3" — the
  string comes from the `//packages/mylib` path dependency, so the whole chain
  (kernel -> AOT -> APK) is demonstrably executing our Dart code.

What is *not* done: `versionCode` / `versionName` (empty — Flutter derives them
from `pubspec.yaml`), plugins using ndk-build, and plugins with dependency
coordinates the scraper cannot read — including, for now, any plugin declaring
versions in a `build.gradle.kts` or inside a `buildscript { }` block, which need
a `plugins.package(artifacts = ...)` until those two gaps are closed. Also
release signing, hermetic SDK download, ABIs other than arm64, and iOS. See
"Known limitations" and [`docs_internal/overview.md`](docs_internal/overview.md).

Two things once on that list — plugins shipping prebuilt `jniLibs`, and **native
assets** (a `.so` produced by a Dart build hook) — now work through
consumer-supplied recipes; see "Package recipes" below.

## Layout

| Path | Role |
| --- | --- |
| `tools/flutter/repo.bzl` | Repo rule locating the SDK, exposing its tools as targets |
| `tools/flutter/abis.bzl` | One table per Android ABI: target-platform string, engine directory, Maven artifact, manifest key, and the gen_snapshot flags armv7 needs |
| `tools/flutter/defs.bzl` | Platform-independent rules: `dart_kernel`, `dart_aot_elf`, `flutter_aot_library`, `flutter_assets`, `pub_path_deps_check`, `pub_plugins_check` |
| `tools/flutter/android.bzl` | Android-only rules: `flutter_android_libs` (the packaging join), `jni_lib_jar`, `android_native_lib_jar`, `strip_native_libs`, `native_assets_check` |
| `tools/flutter/bundle.bzl` | The named contributions an app makes to a platform bundle: `FlutterBundleContributionInfo`, `flutter_bundle_contribution`. Platform-independent, so a second platform reuses the vocabulary |
| `tools/flutter/check_path_deps.py` | Script behind `pub_path_deps_check` |
| `tools/flutter/check_native_assets.py` | Script behind `native_assets_check` |
| `tools/flutter/plugins.bzl` | Repo rule generating one target per native Android plugin, their Maven coordinates, the CMake targets for native ones, and the `plugins.package()` extension |
| `tools/flutter/recipe.bzl` | The recipe contract: `FlutterNativeInfo`, `flutter_native_contribution`, `flutter_native_libs` |
| `bazel/flutter/` | This project's *own* recipes, as a consuming project would write them |
| `plugin_deps.MODULE.bazel` | Generated, committed, `include()`d — the build's only `maven.install` |
| `tools/flutter/embedding.bzl` | Flutter embedding's Maven coordinates, and `flutter_embedding_library()` — the macro a consuming project instantiates |
| `tools/flutter/maven.bzl` | Coordinate → label mangling and highest-wins version reconciliation |
| `app/` | Minimal Flutter app used as the test subject |
| `packages/mylib/` | A `path:` dependency, used to test input declaration |
| `sandbox_demo/` | Probe demonstrating sandboxed vs local execution |
| `tools/format/` | buildifier targets: workspace-wide Starlark formatting and lint |
| `tests/consumer/` | A separate module consuming these rules through `bazel_dep`, so an API break is caught here rather than in someone else's workspace |
| `app/android/app/` | `BUILD.bazel` beside the Gradle module: `android_binary`, Kotlin `MainActivity`, AndroidX deps |
| `docs_internal/` | Background notes — not published yet, see below |

Further reading — **note these are not in the repository yet.** `docs_internal/`
is gitignored while the notes are still being worked over, so the links below
resolve only in a local working copy. Rename the directory back to `docs/` to
publish them.

- [`docs_internal/overview.md`](docs_internal/overview.md) — **start here**: what was accomplished,
  in order, with links into the detail below.
- [`docs_internal/bazel-execution-model.md`](docs_internal/bazel-execution-model.md) — execroot,
  the symlink forest, sandboxing, action keys, and the tag semantics that drive
  the caching policy. Includes how to run the `sandbox_demo` probe.
- [`docs_internal/references.md`](docs_internal/references.md) — Bazel documentation links, and a
  map of the flutter_tools source files that serve as documentation for the
  Flutter half.
- [`docs_internal/android-packaging.md`](docs_internal/android-packaging.md) — how the APK is
  assembled: engine artifacts, native libraries, assets, the JDK pin, and the
  AndroidX dependency chain.
- [`docs_internal/plugins.md`](docs_internal/plugins.md) — the plugin build in full: the two
  registrants, the source library, Maven resolution without Gradle, the gate, and
  the CMake native path.
- [`docs_internal/package-recipes.md`](docs_internal/package-recipes.md) — how a project
  supplies its own build instructions for a package outside the standard build:
  the `plugins.package()` tag, the recipe contract, the Bazel phase boundary that
  forced its shape, and what was measured on a device.
- [`docs_internal/build-performance.md`](docs_internal/build-performance.md) — measured
  against vanilla `flutter` on a real app: where the time goes, and the two
  changes that would make this build faster than the tool it wraps.
- [`docs_internal/running-on-device.md`](docs_internal/running-on-device.md) — build, boot an
  emulator, install, launch, and verify.

## Targets

```sh
bazel build //app:app_arm64-v8a     # release libapp.so, one target per ABI
bazel build //app:assets            # release flutter_assets tree
bazel build //app:app_debug_kernel  # debug kernel (.dill)
bazel build //app:assets_debug      # debug bundle, ships kernel_blob.bin
bazel build //app:path_deps_check   # guard: fails on undeclared path: deps
bazel build //app:plugins_check     # guard: fails on stale plugin_deps.MODULE.bazel
bazel build //app:dart_registrant_check  # guard: fails on stale Dart plugin registrant
bazel build //app/android/app:flutter_check  # guard: bundle completeness + code assets
bazel build //app/android/app:demo_app   # signed APK
```

### Validating a change

```sh
bazel test //...                                   # guards + buildifier
(cd tests/consumer && bazel build --nobuild //...) # the public API, as a consumer sees it
```

The guards fail as **actions**, not as test assertions, which is deliberate and
stronger: anything depending on a guard fails too, and the result is
remote-cacheable. `build_test` does not change that — it only gives `bazel test`
a reason to build them, so they stop being checks that run only when someone
remembers to name them. A tripped guard therefore reports `FAILED TO BUILD`
rather than a test failure.

Then verify on a device — [`docs_internal/running-on-device.md`](docs_internal/running-on-device.md).
**This step is not covered by the gate and is not optional** for anything
touching the Dart or packaging path: this build's recurring failure mode is an
artifact that compiles, packages, installs and *launches* while being wrong, so
a green build is not evidence.

The second command is a separate Bazel module that reaches the rules through
`bazel_dep` + `local_path_override`, exactly as a consumer does. It is not part
of `//...` and cannot be — see
[`tests/consumer/README.md`](tests/consumer/README.md) for why, and for the one
consumer path it still does not reach. It exists because moving a symbol between
`defs.bzl` and `android.bzl` breaks a consumer's `load()` while every check in
this workspace stays green; that has already happened once.

Still **not** covered by either command:

- **Behaviour in a consumer** — the API test analyses, it does not build.
- **Non-macOS hosts**, until CI runs on one.

### Starlark formatting

```sh
bazel run //tools/format:buildifier        # format and lint-fix in place
bazel run //tools/format:buildifier.check  # report only, non-zero on drift
```

[buildifier](https://github.com/bazelbuild/buildtools/blob/main/buildifier/README.md)
covers every `BUILD.bazel`, `*.bzl` and `MODULE.bazel` in the workspace, minus the
exclusions in `//tools/format:BUILD.bazel`. `plugin_deps.MODULE.bazel` is included:
the generator emits buildifier-canonical output, so formatting it does not put the
committed file at odds with `//app:plugins_check`.

In VS Code, `.vscode/` configures the `bazelbuild.vscode-bazel` extension to
format Starlark on save. It needs `buildifier` on `PATH` (`brew install
buildifier` — 8.5.1, the version pinned here); pointing it at the Bazel target
instead would drag in toolchain resolution, and with it `ANDROID_NDK_HOME`.

### Package recipes

Some pub packages cannot be described statically by any amount of scraping.
`rive_native` downloads its `.so` from a CDN inside a Gradle `Exec` task;
`sqlite3` ships a Dart build hook that decides at build time whether to
download, compile, or link a system library. Neither is buildable from source,
and `sqlite3` is not even a Flutter plugin — it has no `android/` module, so the
plugin machinery never sees it.

For these, a consuming project supplies its own build instructions:

```python
plugins.package(
    name = "rive_native",
    bzl_file = "//bazel/flutter:rive_native.bzl",
    macro = "rive_native_recipe",
)
```

The rules generate a BUILD file that loads that macro **by canonical label** and
hands it everything the generator knows — enumerated sources, namespace,
resolved Maven labels, the reason codes it is answering. The recipe's own
`load()` statements then resolve in the *consuming project's* repo mapping, so a
recipe can use rulesets these rules have never heard of. `@flutter_plugins//<name>`
remains the label a consumer names, recipe or not.

A recipe is also the **per-package reversal of the gate**: `prebuilt_jni_libs`
stays gated for every package that has not been given an answer, instead of
being switched off globally the moment one plugin needs it.

And `//app/android/app:flutter_check` makes the class-D failure loud. A package with a
build hook declares an asset id that the Dart VM resolves to a filename and
`dlopen`s; nothing else in the build connects that to whether a library actually
reached `lib/<abi>/`. The check compares the two and fails at build time, where
previously the first signal was an FFI call on a device.

Both work on an arm64 API 35 emulator, with the `.so` files in the APK
byte-identical to what upstream ships:

```
sqlite3: Version(libVersion: 3.53.3, …)      rive_native: success
```

Exercised at scale against [smooth-app](https://github.com/openfoodfacts/smooth-app)
(30 Android plugins): all 30 classify with none gated — 28 from source, `jni` via
CMake, `rive_native` via recipe. Building them is blocked outside these rules: AndroidX
poms carry Maven strict ranges no POM-based resolver can satisfy, so
`resolver = "gradle"` is required, and that hits
[rules_jvm_external#1605](https://github.com/bazel-contrib/rules_jvm_external/issues/1605).

See [`docs_internal/package-recipes.md`](docs_internal/package-recipes.md) for
the design, the Bazel constraints that forced it, and what was measured.

### Fresh clone

Run `flutter pub get` in `app/` **before** the first `bazel build`. It is not
optional convenience: the build reads three pub-generated files that are not in
version control, and a missing one fails as a bare "no such file" without
naming the cause.

```sh
cd app && flutter pub get && cd ..
```

| Generated file | Used as |
| --- | --- |
| `app/.dart_tool/package_config.json` | passed to `frontend_server` (41 MB, machine-specific paths — must never be committed) |
| `app/.flutter-plugins-dependencies` | a declared Bazel input, `//app:.flutter-plugins-dependencies` |
| `…/GeneratedPluginRegistrant.java` | an `android_library` src |

Two files that *are* committed are also generated, deliberately, and guarded
against drift: `plugin_deps.MODULE.bazel` and `app/lib/dart_plugin_registrant.dart`
— see `//app:plugins_check` and `//app:dart_registrant_check`.

### Environment

The Dart-half targets need only the Flutter SDK — `FLUTTER_ROOT`, or `flutter`
on PATH:

```sh
FLUTTER_ROOT=/Users/samer/fvm/versions/3.44.2 bazel build //app:app_arm64-v8a
```

Building the **APK** additionally needs the Android SDK and NDK:

```sh
export ANDROID_HOME="$HOME/Library/Android/sdk"
export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/28.2.13676358"   # 28 or newer
```

Both are easy to get wrong in ways that do not name themselves:

- **`ANDROID_HOME` unset** — `android_sdk_repository` silently generates a
  no-op stub, and the build fails with
  `no such target '@androidsdk//:aapt2'`, which does not mention the SDK.
- **`ANDROID_NDK_HOME` unset or older than 28** — refused with an explicit
  message. The NDK supplies both the CMake toolchain for native plugins and the
  `llvm-strip` used to strip the APK. 28 is the floor because earlier NDKs
  default to 4 KB page alignment, and such a `.so` crashes the loader on a
  16 KB-page device rather than failing cleanly — see
  [`docs_internal/plugins.md`](docs_internal/plugins.md).

**The Android-only flags are grouped behind `--config=android`.** Four of them —
the manifest-permission merge, the two JDK-17 pins, and the `ANDROID_NDK_HOME`
forward — are correct for Android and wrong to impose on a build that is not
Android; the JDK pin in particular would fix a consumer's whole JVM toolchain at
17 to work around a ruleset they may never load. This project *is* an Android
project, so `.bazelrc` opts in on its last line:

```
common --config=android
```

A consumer building only the Dart half, or another platform, deletes that one
line and keeps the group. Verified: with it removed and both `ANDROID_HOME` and
`ANDROID_NDK_HOME` unset, `//app:app` and `//app:assets` build and `libapp.so`
is byte-identical — while the APK fails exactly as the JDK-17 comment predicts,
`turbine_direct_graal` reporting `could not locate class file for
java.lang.Record`.

`ANDROID_NDK_HOME` is forwarded with `--repo_env` rather than hardcoded, since a
path here would be machine-specific. It sits under `common:` rather than
`build:` because repository rules are evaluated by `query` and `mod` too. Targets
that resolve a toolchain no longer drag in the NDK — see limitation #8.

## Known limitations

These are real and unresolved, not oversights.

**1. Most actions run unsandboxed.** `package_config.json` contains absolute
paths into `~/.pub-cache` and the Flutter SDK. None of that is a declared Bazel
input, so the kernel and asset actions run with `no-sandbox` and cannot be
remote-executed. (`DartAotElf` is the exception — it has complete inputs and
Bazel sandboxes it automatically.)
Fixing this properly means modelling pub packages as Bazel repositories — a
`pubspec.lock` → `MODULE.bazel` resolver. That is the genuinely hard part of
Flutter-on-Bazel, and it is exactly the blocker the Flutter team cites in
[flutter/flutter#58082](https://github.com/flutter/flutter/issues/58082)
("no natural mapping from a Dart package to a Bazel module").

**2. The SDK is not hermetic.** `repo.bzl` symlinks an SDK that already exists
on the machine and relies on `flutter precache` having populated the engine
artifacts. A hermetic version would download a pinned SDK plus artifacts by
hash.

**3. Single target platform.** Only `android-arm64-release` is wired up. Other
ABIs and the iOS path (`app-aot-macho-dylib` instead of `app-aot-elf`) are the
same shape but need their own toolchain plumbing.

**4. Source tracking is wrong in both directions.** `srcs` is a `glob` used only
for invalidation; the compiler discovers the real import graph itself.
`frontend_server --depfile` emits that graph as a Ninja-style depfile — 773
files for this demo app, covering `lib/`, the Flutter framework, and pub-cache
packages.

*Over-declaration (performance).* The glob is conservative, so touching a
`.dart` file nothing imports still triggers a rebuild. Bazel cannot ingest a
depfile from a Starlark rule (the `.d` handling in C++ is internal to the native
rules), but `ctx.actions.run(unused_inputs_list = ...)` provides the complement
and is supported as of Bazel 9 — note it is rejected by `run_shell`. Computing
`glob - depfile` into that list would prune these rebuilds.

*Under-declaration (correctness).* The framework and pub-cache sources in the
depfile are real inputs that are never declared — `aquery` shows the kernel
action taking eleven inputs, none of them framework or pub-cache sources. This is mitigated,
though not closed, by version stamping; see below. `unused_inputs_list` cannot
help here — it only prunes inputs, never adds them. Fully closing it requires
declaring pub packages as real inputs, i.e. limitation #1.

**5. Native assets are packaged as assets, not libraries.** A package can ship a
`.so` that Dart opens over FFI through Dart's native-assets mechanism rather than
as a Flutter plugin — a third class of native library beside `libapp.so` and a
CMake plugin's output. `flutter build bundle`, which `flutter_assets` shells out
to, writes it *inside* the asset tree, so it reaches the APK under `assets/`;
only `lib/<abi>/` entries are installed as libraries, and `DynamicLibrary.open`
then fails at runtime. Nothing fails at build time, and `AssetManifest.bin` stays
byte-identical to the reference, a native asset not being a declared `assets:`
entry. Fixing it means splitting the `.so` out of the tree artifact and sending
it down the `jni_lib_jar` path that already carries `libapp.so`. See
[`docs_internal/android-packaging.md`](docs_internal/android-packaging.md) →
"Native assets".

**6. No incremental Dart compilation — the inner loop only ties vanilla
Flutter.** Measured on a real app (811 sources), editing a single `.dart` file
costs 17.9s against `flutter assemble`'s 17.1s, and editing a file that 290
others import costs the same as editing one nothing imports. Neither system
compiles incrementally for release AOT, so the unit of work is the whole program
and caching has nothing to bite on. Bazel wins only the no-op (0.97s vs 2.0s)
and the cold build (17.5s vs 24.9s).

The cost is one action: `frontend_server` spends **14.5s** on whole-program parse
and kernel generation, while `gen_snapshot` takes 0.5s. Tree-shaking is free —
dropping `--tfa` is *slower*, because the dill grows from 5.2 MB to 174 MB.

`frontend_server` supports incremental compilation (it is what hot reload
drives), and `flutter build --release` cannot use it. Driving it from a Bazel
persistent worker is the one change that would make this build faster than the
tool it wraps rather than merely equal to it — plausibly ~7s against 17s, now
that limitation #7 is fixed and the asset action's floor is known. See
[`docs_internal/build-performance.md`](docs_internal/build-performance.md).

**7. ~~The asset action spends ~90% of its time staging.~~** **Fixed.** Inputs
were copied one process at a time; a single tar pipe stages them in one pass and
the action went 13.2s → 4.8s on a real app, byte-identical output. What is left
is `flutter build bundle` itself (~3.6s), which no staging change can touch. See
"Staging" below and
[`docs_internal/staging-experiments.md`](docs_internal/staging-experiments.md).

**8. ~~The NDK is a prerequisite of every Bazel command~~ — fixed.**
`register_toolchains` cannot be conditional, and toolchain resolution loads
every registered toolchain repo looking for a match. `rules_android_ndk`'s
`android_ndk_repository` fails during that *fetch* when `ANDROID_NDK_HOME` is
unset — so any target resolving any toolchain used to need an NDK, including
`bazel run //tools/format:buildifier`, a formatter with no Android content.

`//tools/flutter:ndk.bzl` now wraps that extension: with the variable set it
runs the same repository rule with the same inputs; without it, `@androidndk`
becomes a stub declaring no toolchains, so `@androidndk//:all` registers nothing
and resolution carries on. This is the shape `@androidsdk` already had — stub
now, fail later at the target that needs it.

What still needs an NDK, correctly:

- the APK, and any Android cc work (the strip, a native plugin jar);
- **`@flutter_plugins` generation in this project**, because one plugin
  (`rive_common`) has a CMake build — so `//app:plugins_check` needs it too,
  while `//app:path_deps_check` and the whole Dart half do not. That is this
  project's plugin set, not a property of the rules.

One cost, worth knowing before wrapping a third-party extension: a repo created
by *your* extension resolves apparent repo names against *your* module, so
`@androidndk`'s generated BUILD referencing `@platforms` made `platforms` a
direct `bazel_dep` here.

This compounds with limitation #3. Every platform added — iOS, desktop, web —
and every host-only tool target pays the Android tax, on machines that have no
other reason to hold an NDK. `@androidsdk` does not have the problem in the same
form: with `ANDROID_HOME` unset it generates a stub and fails later, at a target
that actually wants `aapt2`.

The fix belongs upstream in `rules_android_ndk`: the repository rule should
fetch successfully without a path and fail only when something in it is built,
moving the error from fetch time to use time. Until then the workaround is to
make the variable unconditionally visible to Bazel — a
`try-import %workspace%/user.bazelrc` carrying
`common --repo_env=ANDROID_NDK_HOME=...` — rather than relying on whichever
shell, or GUI, launched the build having exported it.

## Invalidation strategy

Three layers, in decreasing strength:

| Layer | Kind | Catches |
| --- | --- | --- |
| `platform_strong.dill`, `frontend_server.snapshot`, `gen_snapshot` | content hash | any engine roll |
| `@flutter_sdk//:flutter.version.json` | content hash | **any framework commit** — `frameworkRevision` is a git hash, so it moves even when engine artifacts are byte-identical |
| `pubspec.lock` (`pub_stamp`) | content hash | any hosted dependency change — pub verifies the per-package sha256 on extraction |
| `.dart_tool/version`, `package_graph.json` (`pub_stamp`) | identity | in-place `flutter upgrade`; version bumps of path dependencies |
| `path_deps` | content hash | `path:` dependency sources, which nothing else observes |

`package_config.json` is **not** in this table for `dart_kernel`: it is passed as
`--packages` but deliberately undeclared, to keep absolute pub-cache paths out of
the action key. See "Key portability". `flutter_assets` still declares it, since
that action is not portable anyway.

### Remote caching

Remote *execution* is impossible here (undeclared pub-cache inputs would not
exist on a remote worker). Remote *caching* is a different mechanism — the
action still runs locally and only results are shared — so it is worth
considering per action.

Policy: **release actions are remote-cacheable, debug actions are not.**

| Action | ExecutionInfo | Cacheable | Key portable |
| --- | --- | --- | --- |
| `DartAotElf` | *(none — runs sandboxed)* | yes | inherited (see below) |
| `DartKernel` release | `no-sandbox, no-remote-exec` | yes | **yes** |
| `DartKernel` debug | `+ local` | **no** | — |
| `FlutterAssets` release | `no-sandbox, no-remote-exec` | yes | no |
| `FlutterAssets` debug | `+ local` | **no** | — |

`DartAotElf` has no machine-specific inputs of its own, but its key includes the
`.dill`, which embeds ~370 absolute paths. So it is portable exactly when the
kernel step is a cache hit: the `.dill` is then downloaded rather than
recompiled, and never diverges. If the kernel runs locally on a second machine,
the `.dill` differs and the AOT step misses too.

Debug opts out because debug kernels embed ~800 absolute source URIs and are
shipped verbatim as `kernel_blob.bin`. A cache hit would hand one machine's
artifact to another, carrying the producing machine's paths into stack traces
and breaking hot reload. Release output passes through `gen_snapshot --strip`,
which discards them.

The distinction is expressed per-action via `mode`, not globally. `.bazelrc`
deliberately does **not** set `--spawn_strategy=local`: that would flatten the
policy and force every action local. With it removed, `DartAotElf` runs in the
sandbox (`darwin-sandbox`) and still produces a byte-identical `libapp.so` —
direct confirmation that its input set is complete.

#### Key portability

`dart_kernel` passes `package_config.json` as `--packages` but does **not**
declare it as an input. Its `rootUri` entries are absolute paths into
`~/.pub-cache`, so declaring it would put machine-specific bytes in the action
key and guarantee a miss on every other machine. Undeclared, it is read through
the execroot symlink forest instead — which is why the `no-sandbox` tag is load
bearing, not merely tolerated.

Verified: every remaining declared input contains zero absolute paths, and the
action sets no environment.

| Declared input | absolute paths |
| --- | --- |
| `package_graph.json`, `version`, `pubspec.lock`, `main.dart` | 0 |
| `dartaotruntime`, `frontend_server.snapshot` | 0 |
| `platform_strong.dill`, `vm_outline_strong.dill`, `flutter.version.json` | 0 |

So the release kernel key is machine-independent, and `DartAotElf` inherits that
— on a cache hit the `.dill` is never recompiled, so its embedded paths never
diverge.

`FlutterAssets` is **not** portable and still declares `package_config.json`,
because it gains nothing: its `FLUTTER_ENV` bakes in `HOME` and a `PATH`
containing bazelisk download hashes and local toolchain directories. Fixing that
means constructing a minimal, stable environment first.

#### Path dependencies

`path:` dependencies are the one case the stamps cannot cover, so they are
declared explicitly:

```python
PATH_DEPS = ["//packages/mylib:srcs"]

flutter_aot_library(name = "app", path_deps = PATH_DEPS, ...)
```

Bazel globs cannot cross package boundaries, so the dependency needs its own
`BUILD.bazel` exposing a `filegroup`.

Demonstrated on a real path dependency:

| State | `libapp.so` |
| --- | --- |
| mylib v1, undeclared | `f9706580…` |
| mylib v2, undeclared | `f9706580…` — **stale, silently** |
| mylib v2, declared via `path_deps` | `326afe89…` |
| mylib v3, declared | `f63b14af…` — invalidates correctly |

`pub_path_deps_check` automates the audit: it parses `pubspec.lock` for
`source: path` entries and fails if any is not covered by `path_deps`, printing
the filegroup to add. Depend on it from CI before enabling a shared cache — a
manual grep is exactly the step people skip.

```
bazel build //app:path_deps_check
```

**What this trades.** Declaring `package_config.json` was an accidental safety
interlock: machine-specific bytes guaranteed cache misses, so sharing was
useless but never wrong. Removing it enables sharing and shifts correctness onto
`pub_stamp` — above all `pubspec.lock`, whose per-package sha256 pub verifies on
extraction, so identical keys imply identical *hosted* package contents. Path
dependencies have no hash and no meaningful version: **list their sources in
`srcs`, or a shared cache can serve the wrong artifact.** Audit for `path:`
dependencies before pointing this at a shared cache.

Note `--filesystem-root` / `--filesystem-scheme`, which canonicalize paths in
some Dart toolchains, are not exposed by this `frontend_server` build.

### Path embedding: release vs debug

Measured with `strings <file> | grep -c /Users/...` (note: `grep -c` directly on
a binary is unreliable and will under-report):

| Artifact | Absolute paths |
| --- | --- |
| Release `.dill` (intermediate) | 371 |
| Debug `.dill` (intermediate) | 773 |
| **Release `libapp.so`** (shipped) | **0** |
| **Debug `kernel_blob.bin`** (shipped) | **803** |
| Release asset bundle | 0 |

So *shipped* release artifacts are reproducible across machines — `gen_snapshot
--strip` discards the source URIs — while debug bundles embed the kernel
directly (`kernel_blob.bin`, `vm_snapshot_data`, `isolate_snapshot_data`) and
carry machine paths into the app.

Note this is a different axis from cacheability: keys are built from *inputs*,
so a release build produces a portable artifact via a non-portable action graph.
The output would be byte-identical on another machine; the cache simply cannot
prove it.

On safety: the stamps make hosted-package content differences *observable* in
the action key — a version change moves `rootUri`, and `pubspec.lock` carries a
pub-verified sha256 per hosted package — so cache hits imply identical hosted
dependencies. Path dependencies are the exception: no hash, no version in the
URI, and they live outside the Bazel package, so declare their sources in `srcs`
before trusting a shared cache.

### Why not the project's `.metadata`

A Flutter project's `.metadata` also carries a `revision:` hash, but it records
the revision the project was *scaffolded or migrated with*. `flutter create` and
`flutter migrate` write it; ordinary SDK use, including `pub get`, does not.
Two checkouts on different SDKs can therefore share a `.metadata`. The SDK's own
`bin/cache/flutter.version.json` is the correct source for the *active* SDK
identity, and being inside the SDK it can be content-hashed as a real input
rather than trusted as a project-local stamp.

The `pub_stamp` files record **identity, not content** — they are version
stamps, deliberately conservative. Verified: editing `.dart_tool/version`
reruns the kernel compile, while the AOT step stays an action cache hit because
the resulting `.dill` is byte-identical. So an over-eager stamp costs one
kernel compile, not the whole chain.

Residual gap, now much narrower: SDK *revisions* are tracked, so framework-only
commits are caught. What remains uncaught is editing framework or pub-cache
sources **in place at an unchanged revision** — patching
`$FLUTTER_ROOT/packages/flutter/lib/**` by hand, or mutating an extracted
pub-cache package. Both are dirty-tree scenarios rather than normal workflow.
Only declaring those files as real inputs closes them completely.

**5. No platform packaging yet.** Assets are now built (see below); the
remaining gap is the `android_binary` wiring that consumes `libapp.so`,
`libflutter.so` and the asset tree.

## Assets

```
bazel build //app:assets   ->   bazel-bin/app/assets/   (tree artifact, 2.0 MB)
```

Contents: `AssetManifest.bin`, `FontManifest.json`, `NativeAssetsManifest.json`,
`NOTICES.Z`, MaterialIcons + package fonts, shaders, and declared assets — i.e.
exactly what belongs at `assets/flutter_assets/` in an APK.

**This half does shell out to `flutter build bundle`, deliberately.** The Dart
half avoids flutter_tools because `frontend_server` and `gen_snapshot` are
standalone binaries. Assets have no equivalent: resolution of asset variants,
package assets, font manifests and license aggregation lives entirely inside
flutter_tools, with no separate bundler to call. `--asset-dir` is the documented
entry point for exactly this — its help text reads "Can be used to redirect the
output when driving the Flutter toolchain from another build system" — which
makes it a far more stable contract than the `flutter assemble` target names.

Notes on the implementation:

- `copy_assets` (an `assemble` target) writes to `environment.buildDir`
  (`.dart_tool/flutter_build/<hash>/`), not to `-o`, so it is awkward to wire
  into Bazel. `flutter build bundle` writes where it is told.
- The bundle is reproducible. Across repeat runs the only differing file is
  `.last_build_id`, flutter_tools bookkeeping, which the rule deletes. Verified:
  everything else, `NOTICES.Z` included, is byte-identical, and the Bazel output
  matches a hand-built bundle exactly.
- flutter_tools needs a real environment — it probes `$HOME` to locate the
  Android SDK. The repo rule captures `HOME`, `PATH` and, when set,
  `ANDROID_HOME` / `ANDROID_SDK_ROOT` / `PUB_CACHE` into an explicit `env`
  rather than inheriting everything via `use_default_shell_env`.
- Output is a `declare_directory` tree artifact, so Bazel hashes the contents.
  Verified: no-op rebuild ~80 ms, editing an asset or adding one via `pubspec.yaml`
  both rebuild correctly.

### Cost, and why assets are not chained to the Dart half

Measured after a source change (macOS arm64, this demo app):

| Build | Wall clock |
| --- | --- |
| `//app:app` (kernel + AOT) | 8.79 s |
| `//app:assets` | 1.84 s |
| both, in parallel | **8.82 s** |

The two halves are independent, so Bazel runs them concurrently and the asset
bundle costs ~30 ms of real time. Making assets a dependency of the Dart
compile would serialize them to roughly 10.6 s — about 21% worse — for no
benefit.

There is no duplicated kernel work to reclaim: `flutter build bundle --release`
does not compile one. A cold run (with `.dart_tool/flutter_build` wiped) emits
no `.dill` at all, only the `dart_build`, `install_code_assets` and
`release_flutter_bundle` stamps; `kernel_blob.bin` is a debug-mode artifact.
Note also that Bazel caches at *action* granularity and cannot see inside a
subprocess, so no arrangement of the graph would let it cache flutter_tools'
internal steps.

`--no-pub` is passed deliberately. `flutter build` runs pub get by default,
which would put implicit dependency resolution — and a possible network call —
inside a Bazel action. Resolution is the caller's job.

**Previously a known side effect, now fixed by staging (below).** Because the
action used to `cd` into the package, and the execroot entry for that package is
a symlink to the source tree, flutter_tools wrote its incremental cache to
`app/.dart_tool/flutter_build/<hash>/` in **your sources** — an undeclared
output. What that caused:

- It survives `bazel clean`, so a "clean build" silently reuses previous state.
  This is a classic works-locally-fails-in-CI source.
- Two asset targets (release and debug) run concurrently and write the same
  directory. Nothing coordinates them, and the same applies if you run
  `flutter run` during a build.
- If any glob ever covers `.dart_tool/**`, the action mutates its own inputs and
  every build dirties the next one.

### Staging

**Implemented.** The action no longer runs in the symlinked package; it copies
its declared inputs into a temporary directory and builds there:

```sh
EXECROOT="$PWD"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/flutter_assets.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

# every declared input, copied to its execroot-relative path
tar -cf - -T <manifest> | (cd "$STAGE" && tar -xf -)
chmod -R u+w "$STAGE"

cd "$STAGE/app"
flutter build bundle --release --no-pub --target-platform=android-arm64 \
    --asset-dir="$EXECROOT/<declared output>"
```

Inputs are copied to their **execroot-relative** paths, which reproduces the
workspace layout inside the stage. That is what keeps the `mylib` path
dependency resolvable — `package_config.json` refers to it as
`../../packages/mylib`, so staging only the app directory would break it. The
file list is written to a manifest with `ctx.actions.write` rather than passed
as arguments, so a large app cannot overflow the argument limit.

Verified: source tree untouched (0 `flutter_build` directories created, before
and after a concurrent release+debug build), and the bundle is byte-identical to
the pre-staging output.

Bazel provides no managed scratch directory for local actions: `$TMPDIR` is the
shared system temp and is not cleaned, so the action uses `mktemp -d` plus a
`trap`.

**Cost — was 90% of the action, now ~20%.** Staging used to spawn `mkdir -p` and
`cp` per file: on a real app, 1546 files and roughly 3000 processes, ~9s of an
13.2s action. The tar pipe does the same work in **~0.95s** in one process pair,
and the action is now **4.8s** with byte-identical output — verified down to a
bit-identical APK. The demo app has ~13 files, which is why this never showed
there.

What is left is not staging. `flutter build bundle` on a real app costs **~3.6s**
on its own — the 1.08s previously quoted was a demo-app number — so ~75% of the
action is now the tool, and no staging change can reach it. Five implementations
(tar, `pax -rw`, `pax -rw -l`, `rsync --files-from`, symlinks) were measured and
land within 0.7s of each other; compression on the tar pipe was measured too and
every filter loses. See
[`docs_internal/staging-experiments.md`](docs_internal/staging-experiments.md).

**Staging does not fix the startup lock** — handled separately. The `flutter` CLI serializes
concurrent invocations (`Waiting for another flutter command to release the
startup lock...` appears when the release and debug asset targets build
together), but that lock is on `$FLUTTER_ROOT/bin/cache/lockfile` — SDK-scoped,
not project-scoped, so a different working directory changes nothing. The fix,
now applied, is the `FLUTTER_ALREADY_LOCKED=true` environment variable, which
flutter_tools sets for its own sub-invocations (`cache.dart:423`,
`base/process.dart:652`). Safe here because the lock guards the SDK cache
against concurrent mutation, and these actions only read it: `--no-pub` prevents
resolution and the SDK must already be precached.

### Alternative: Bazel's own sandbox

Bazel 9 offers `--sandbox_add_mount_pair`, `--sandbox_writable_path` and
`--sandbox_tmpfs_path`. Mounting `~/.pub-cache` and `$FLUTTER_ROOT` into the
sandbox would let the assets action drop `no-sandbox` entirely, and Bazel would
supply the isolation — writes land in the sandbox and are discarded. It is the
more idiomatic mechanism, but those are global flags, so machine-specific
absolute paths end up in `.bazelrc`. Manual staging keeps the fix inside the
rule and needs no per-developer configuration.

## Why not just wrap `flutter build`

Because it defeats the point. A wrapper is one opaque action: no caching of the
expensive AOT step, no parallelism against the platform build, no remote
execution. Splitting at `libapp.so` gives Bazel two cacheable units and lets the
Android/iOS packaging reuse rules that already exist.

## On `flutter assemble`

`flutter assemble` is Flutter's own build-system-facing entrypoint (it is what
the Gradle plugin and the Xcode build phase call), and its target names are
explicitly documented as internal and unstable. These rules skip it and drive
`frontend_server` / `gen_snapshot` directly — one layer lower, but a much
smaller and more stable surface. Since the SDK is version-pinned anyway,
"unstable across versions" reduces to "stable for this pin".


## Android packaging

`//app/android/app:demo_app` is an `android_binary` from `rules_android` 0.7.3, which
does work on Bazel 9.2.0 despite the native Android rules having been removed.

```
lib/arm64-v8a/libapp.so       <- //app:app
lib/arm64-v8a/libflutter.so   <- engine jar, fetched from Maven
assets/flutter_assets/**      <- //app:assets
classes.dex                   <- embedding + AndroidX
```

The BUILD file sits inside the Gradle module `flutter create` generated, so
Bazel and Gradle read the same manifest, resources and sources — nothing is
copied.

Verified running on an arm64 API 35 emulator: `Fully drawn +1s243ms`, no fatal
exceptions, counter increments on tap, and the app bar renders a string from the
`//packages/mylib` path dependency — so the whole chain is demonstrably
executing our Dart code.

Four things this required, none of them obvious:

1. The engine artifacts are **not** in `bin/cache`; their Maven URLs are derived
   from `flutter.version.json`, and the directory and filename use *different*
   hashes.
2. `android_binary` extracts `lib/<abi>/*.so` from jars on the classpath, so no
   Android CC toolchain is needed to carry a prebuilt `.so`.
3. The JDK must be pinned to 17 — `rules_android`'s dexer tools do not compile
   under 25.
4. The embedding's AndroidX dependencies must be declared explicitly, and
   attached to the target that contains the classes, not just to the binary.
5. `MainActivity` is Kotlin in the Flutter template, so `rules_kotlin` compiles
   it directly rather than a Java stand-in being maintained alongside.

Full detail, including the failure messages each of these produces:
[`docs_internal/android-packaging.md`](docs_internal/android-packaging.md). To build, install and
verify on a device: [`docs_internal/running-on-device.md`](docs_internal/running-on-device.md).

Native libraries are stripped on the way into the APK, the way AGP's
`stripDebugSymbolsRelease` does it for a Gradle build — 183 MB to 22 MB, almost
all of it the engine's DWARF. The debug info is discarded rather than saved, so
there is no symbol artifact to upload to a crash reporter yet. Release stack
traces are readable regardless: Dart keeps its name table in the snapshot unless
`--split-debug-info` is used, which this build does not.

Known gaps: empty `versionCode` / `versionName`, debug signing only, and
arm64-v8a only.

### The plugin registrant

`GeneratedPluginRegistrant` — the class flutter_tools regenerates on every `pub
get` — is compiled by `:generated_plugin_registrant`, a target of its own rather
than another src on `:main_activity`, because its deps *are* the plugin list:
`registerWith()` instantiates each plugin class, so plugin targets attach there.

Two properties worth knowing before trusting a build:

- **Nothing calls it.** `FlutterEngine` finds it reflectively —
  `GeneratedPluginRegister` does `Class.forName("io.flutter.plugins.Generated`
  `PluginRegistrant")`, then `getDeclaredMethod("registerWith")`. It needs no
  call site, only presence in the dex, and `@Keep` becomes load bearing the
  moment shrinking is enabled.
- **Its absence is silent.** A missing registrant is an `E`-level log, not a
  crash. Measured on an emulator, an APK without it reported `Displayed …
  +1s456ms`, no `FATAL`, and a working counter, while logging 32
  `GeneratedPluginsRegister` lines and running with every plugin dead. It is the
  "functional success hides defects" pattern again, so the check is
  `adb logcat -d | grep -c GeneratedPluginsRegister` returning 0 — see
  [`docs_internal/running-on-device.md`](docs_internal/running-on-device.md).

Also note `androidx.annotation:annotation` became a KMP module at 1.7 and is
metadata-only: anything compiling against the embedding needs
`@flutter_maven//:androidx_annotation_annotation_jvm`. The bare artifact
satisfies runtime resolution but carries no class files, so it fails a strict
compile classpath — the same shape as the `window` / `window-java` split.
`FlutterPlugin` annotates its methods with `@NonNull`, so this hits every plugin
too; `//tools/flutter:flutter_embedding` therefore `exports` its AndroidX deps,
mirroring the `api` dependency Gradle attaches to each plugin.

### Plugins

`@flutter_plugins//<name>` is one `android_library` per native Android plugin,
generated by `//tools/flutter:plugins.bzl` from the same
`.flutter-plugins-dependencies` that Gradle's `FlutterAppPluginLoaderPlugin`
reads. The plugin's `android/` tree is symlinked out of `~/.pub-cache` into an
external repository — Bazel cannot glob outside the workspace — and its sources
are enumerated by the repo rule rather than globbed, since the tree is reached
through a directory symlink.

Adding a plugin to `pubspec.yaml` and running `pub get` is the whole workflow;
nothing in `tools/` is edited per plugin.

Plugin-to-plugin dependencies are wired from the `dependencies` field of the
same metadata — `image_picker_android` needs `FlutterLifecycleAdapter` from
`flutter_plugin_android_lifecycle`, which Gradle handles in
`PluginHandler.configurePluginDependencies`.

**Maven dependencies.** Each plugin's `build.gradle` is scraped for dependency
coordinates, including `$var` / `${var}` substitution from `ext`/`def`
assignments in the same file. `kotlin-stdlib` is skipped as toolchain-provided —
it is the single most common unresolved coordinate, because the plugin template
writes `$kotlin_version`, which is defined in the *root* project and so is never
readable from the plugin's own file.

No Gradle is involved. `rules_jvm_external` already does transitive resolution,
POM handling and AAR packaging; the only thing Gradle was needed for was the
direct coordinates, and those are literal often enough to scrape.

`MODULE.bazel` cannot `load()`, and one module extension cannot add tags to
another, so the coordinates cannot be fed to `maven.install()` directly. They are
generated into `plugin_deps.MODULE.bazel`, committed, and `include()`d — and
`//app:plugins_check` diffs the committed file against the generated one,
printing what to write. Same shape as `pub_path_deps_check`, for the same
reason: the manual step is the one people skip.

That segment carries the embedding's coordinates too, and is the only
`maven.install` in the build — see "Version conflicts" below for why splitting
it is unsafe.

**The gate.** Plugins are classified by *reason code*, and routing is one lookup
against `_GATED_REASONS`:

| Reason | Meaning |
| --- | --- |
| `unresolved_dep` | a coordinate could not be read statically — a variable defined outside the file, or a version supplied by a BOM via `platform(...)`. |
| `ndk_build` | the module drives ndk-build (`Android.mk`), which nothing here runs. |

`external_native_build` (the module drives CMake) used to be on that list. It is
not any more: the plugin's own `CMakeLists` is built against the NDK, and the
resulting `.so` is attached to the same label. See `docs_internal/plugins.md`.

This is structured so widening support is a deletion. Removing an entry from
that list re-routes every plugin carrying it, and the strategy is deliberately
**not** encoded in the label — `@flutter_plugins//connectivity_plus` is the same
label however it is built, so flipping a plugin never touches a consumer.

Verified with two plugins. `connectivity_plus` is the simple case: the body reads
`connectivity: wifi`, so its Java reached `ConnectivityManager` and the reply
came back over the method channel. `image_picker` is the hard case, and its
Android half is fully built — `res/xml/flutter_image_picker_file_paths.xml` is
compiled into the APK, the `<provider>`'s `${applicationId}` placeholder
resolves to `com.example.demo_app.flutter.image_provider`, and its four AndroidX
coordinates resolve.

The gate is granular: an unsupported plugin gets a target that *fails when
built*, not a `fail()` in the repository rule, so one unsupported plugin no
longer makes every other plugin unfetchable. `unresolved_dep` has an escape hatch
(the `override` tag); `external_native_build` does not yet — the CMake route is
decided but unbuilt. The full plugin story, the fallbacks, and the open
shell-vs-`rules_foreign_cc` decision live in
[`docs_internal/plugins.md`](docs_internal/plugins.md).

Note: editing the repository rule can make the *next* build surface results
computed against the previous repository state. Building a second time clears it.

### The Dart plugin registrant

`GeneratedPluginRegistrant.java` is only half of plugin registration. A
*federated* plugin also declares `dartPluginClass` — `image_picker_android`
declares `ImagePickerAndroid` — implementing its platform interface in Dart, and
that half is registered from a generated Dart library. Without it the app builds,
launches and registers every plugin natively, then fails on first use:

```
image_picker: failed: MissingPluginException(No implementation found for
method retrieve on channel plugins.flutter.io/image_picker)
```

`ImagePickerPlatform.instance` was never set, so calls fell through to the
default `MethodChannelImagePicker` and a channel the Pigeon-based Android
implementation does not serve. Note the native side was entirely fine — which is
why this surfaces as a missing *method* rather than a missing plugin.

The registrant is generated by the same repository rule (from each plugin's
pubspec, since `.flutter-plugins-dependencies` does not carry `dartPluginClass`),
committed to `app/lib/dart_plugin_registrant.dart`, and guarded by
`//app:dart_registrant_check`. `dart_kernel` passes:

```
--source package:demo_app/dart_plugin_registrant.dart
--source package:flutter/src/dart_plugin_registrant.dart
-Dflutter.dart_plugin_registrant=package:demo_app/dart_plugin_registrant.dart
```

Nothing imports the file. It is compiled in via `--source`, and the engine finds
it at runtime through that define, which
`package:flutter/src/dart_plugin_registrant.dart` reads into a const — hence the
`vm:entry-point` pragmas, since nothing references the symbols and tree shaking
would otherwise drop them.

**Why a `package:` URI, and why the file is committed into `lib/`.** The engine
looks the library up by that exact string, so it must match the URI
`frontend_server` recorded. Passing an execroot-relative path does not work: the
compiler canonicalises it to an absolute `file://` URI while the define keeps the
relative form, the lookup misses, and the registrant silently never runs —
verified, the build succeeds and behaviour is unchanged.

Matching them by passing absolute paths does work, and is what flutter_tools
does. But the define is a const String *value* read at runtime, not a source URI,
so `gen_snapshot --strip` cannot discard it — it would put a machine-specific
absolute path in a shipped release artifact. Only a file inside the package
config has a stable `package:` URI, so the generated file is committed to `lib/`
and addressed the same way `entrypoint_uri` already is.

Verified after the change: `image_picker: ok (no lost data)`, and
`strings libapp.so | grep -c /Users/` still **0**.

One consequence worth noting: a stock `flutter build apk --release` of a
plugin-using app embeds an absolute build-machine path in `libapp.so` for this
reason. This build does not.

#### Version conflicts

There is exactly **one** `maven.install` for `@flutter_maven`, in the generated
segment, listing both the embedding's dependencies and every plugin's.
`MODULE.bazel` declares no artifacts of its own.

That is not tidiness. Two `install` tags sharing a repository name merge into a
single resolution in which **the later tag wins outright** — not highest-version,
not declaration order. With the embedding's artifacts in `MODULE.bazel` and the
plugins' in the generated segment, this happened:

| Artifact | embedding | plugins | resolved |
| --- | --- | --- | --- |
| `androidx.annotation:annotation` | 1.8.1 | 1.9.1 | 1.9.1 |
| `androidx.exifinterface:exifinterface` | 1.4.1 | 1.3.7 | **1.3.7** |

The plugin list won in both directions, so adding a plugin silently *downgraded*
an artifact the embedding declares. Nothing failed; the APK built and ran.

The fix is structural rather than a policy flag: coordinates live in
`//tools/flutter:embedding.bzl`, the generator merges them with every plugin's
and applies highest-wins — Gradle's rule — across the whole set, then emits one
list. A cross-source conflict is no longer possible to express. Both artifacts
above now resolve to the higher version, and `//app:plugins_check` fails if
`embedding.bzl` is edited without regenerating.

`version_conflict_policy = "pinned"` remains on that single install: every
artifact is already reduced to one version, so it makes those versions
authoritative over transitive suggestions rather than failing resolution when
some pom asks for something older.

#### Manifest permissions

`.bazelrc` sets `--merge_android_manifest_permissions`. Bazel's manifest merger
**strips `<uses-permission>` and `<uses-permission-sdk-23>` from every
dependency manifest** before merging — `removePermissions()` in
`ManifestMergerAction.java`, gated on that flag, which defaults to off. The
policy behind the default is that an app should declare its own permissions
rather than inherit them silently.

Flutter plugins work the opposite way: they declare what they need and Gradle
merges it up. Without the flag, `connectivity_plus`'s `ACCESS_NETWORK_STATE` is
dropped and the APK builds, installs, launches, registers the plugin, and then
throws `SecurityException` on first use — measured: `Displayed … +1s181ms`, no
`FATAL`, and a `connectivity: failed: PlatformException(...)` in the UI. Nothing
about the build reports a problem. Check the APK, not the build log:

```sh
aapt2 dump permissions demo_app.apk | grep uses-permission
```
