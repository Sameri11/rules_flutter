# Installing rules_flutter

Consumers use the `rules_flutter_core` and `rules_flutter_android` Bazel modules.
Until they are published to a registry, install both from the same immutable
repository archive. The checked [`tests/archive_consumer`](../tests/archive_consumer/)
example provides the complete, working module configuration, including archive
URLs, digests, strip prefixes, and a committed lockfile.

For a fresh app, copy the complete
[`.bazelversion`](../tests/archive_consumer/.bazelversion),
[`.bazelrc`](../tests/archive_consumer/.bazelrc), and
[`MODULE.bazel`](../tests/archive_consumer/MODULE.bazel) from the checked
example. Keep the module declarations and both overrides, which pin the same
immutable archive; there is no need to check out the rules repository. Treat
this archive as a pinned starter, not a substitute for configuring your own
consumer module.

For development against this checkout, keep the `bazel_dep` declarations and
replace the two archive overrides with `local_path_override` entries pointing
at `rules_flutter_core` and `rules_flutter_android`. Then update the Flutter
extension to a version supported by this checkout and match it to the local
Flutter SDK. The current checkout API also requires changing the app BUILD
configuration to load `FLUTTER_ANDROID` and pass `platforms = [FLUTTER_ANDROID]`
to `flutter_core`; the pinned archive starter has no `platforms` attribute.

Use the standalone fixture's `.bazelrc` as a starting point for a consumer
outside this repository. The in-repository
[`examples/no_plugins/.bazelrc`](../examples/no_plugins/.bazelrc) imports shared
configuration and is not standalone. The standalone fixture's settings enable
Bzlmod, merge Android manifest permissions, select JDK 17, forward
`ANDROID_NDK_HOME` to repository rules, and select the release ABI/mode. Adapt
those flags as needed; its complete file is linked at
[`tests/archive_consumer/.bazelrc`](../tests/archive_consumer/.bazelrc).

On Linux, building CMake Android plugin halves requires a C compiler available
on `PATH` as `gcc`, or selected through `CC`; `rules_foreign_cc` builds
`pkgconf` from source.

The Flutter SDK repository also exposes
`@flutter_sdk//:flutter.version.json` as read-only version metadata. Android
embedding repositories derive their SDK version from it; consumers need not
name those repository labels.


## Consumer configuration

Each consumer owns its Bazel configuration: the `.bazelrc`, Flutter SDK and pub
extensions, Android SDK/NDK toolchain registration, Maven installation, and pub
lock. Archive module trees do not supply a root module or a shared `.bazelrc`.
There are no settings inherited from a rules checkout.

`flutter.sdk(version = "X.Y.Z")` accepts stable versions 3.47.0 or newer.
Older versions and pre-releases are unsupported. The first extension resolution
downloads canonical artifacts and writes their pins to Facts in
`MODULE.bazel.lock`; review and commit that lock before using
`--lockfile_mode=error`.

To use a mirror, set `base_url` to redirect Flutter Storage downloads, or
override single pieces with `urls` and `sha256`, keyed by the piece names
recorded in the lock. Overrides never change the lock. Pinning also fetches from
GitHub; if it is blocked, rewrite `github.com` and `raw.githubusercontent.com`
with Bazel's `--downloader_config`.

```starlark
flutter.sdk(
    version = "3.50.1",
    base_url = "https://mirror.example",
    urls = {"framework_source": ["https://mirror.example/flutter-archive.tar.gz"]},
)
```

The host Flutter installation remains useful for IDE workflows, `pub get`, and
`build_runner`, but Bazel builds use the pinned SDK. Android SDK/NDK are local
prerequisites; use Android SDK platform 36, build-tools 36.0.0, and NDK 28 or
newer. Set `ANDROID_HOME` and `ANDROID_NDK_HOME`. SDK provisioning requires
`bash`, `python3`, and `tar`. Commit `pubspec.lock` and generated
`MODULE.bazel.lock`.

The archive consumer has a checked lockfile and can build with
`--lockfile_mode=error`. A new consumer must initially resolve dependencies with
`--lockfile_mode=update`, review and commit its lockfile, then use
`--lockfile_mode=error` for subsequent builds. The lockfile pins hosted pub
packages by sha256 and Git packages by resolved commit. Declare path dependency
sources in `path_deps`.

See [`tests/archive_consumer`](../tests/archive_consumer/) for the full checked
configuration and [the Android app guide](android-app.md) for the current API
and build target setup.
