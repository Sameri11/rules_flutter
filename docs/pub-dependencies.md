# Pub workspaces and path dependencies

Bazel does not discover or hash source files merely because Dart resolves a
package dependency. Keep each app's `pubspec.yaml` and `flutter_core` in the same
Bazel package; outside a pub workspace, keep that app's `pubspec.lock` there as
well. Declare every local path dependency's source files in `path_deps` on the
consumer target. Both `flutter_core` and `flutter_package` check declarations
against the selected `pub` hub's lock on every build. Set
`--run_validations=false` to opt out.

For example, an app package can declare its local plugin sources:

```python
flutter_core(
    name = "app",
    path_deps = ["//packages/greeter:srcs"],
    platforms = [FLUTTER_ANDROID],
    pub = "@pub",
)
```

The dependency package owns the source glob and its manifest:

```python
filegroup(
    name = "srcs",
    srcs = glob(["lib/**/*.dart"]) + ["pubspec.yaml"],
)
```

The [local plugin example](../examples/local_plugin/) places an app and plugin
under `packages/host_app` and `packages/greeter` respectively. Keep one core in
the app's Bazel package and point the Android app helper at that target.

## Pub workspaces

A Dart pub workspace has one root `pubspec.yaml`, `pubspec.lock`, and pub hub.
List each workspace member as a literal path in the root `workspace:` field;
globs are rejected because Bazel cannot reliably track new directory matches.
Each member declares `resolution: workspace`.

```yaml
name: workspace_root
workspace:
  - packages/shared
  - apps/mobile
```

Declare the root lock once and share its repository across workspace packages:

```python
pub = use_extension("@rules_flutter_core//flutter:extensions.bzl", "pub")
pub.lock(name = "pub", lock = "//:pubspec.lock")
use_repo(pub, "pub")
```

For a lock whose relative path packages are rooted elsewhere, set
`path_package_root` to a file label in that repository; its containing directory
is used as the path root.

Set `pub = "@pub"` on each `flutter_core` or `flutter_package`. Workspace
membership does not add source files to Bazel actions: list member sources as
`path_deps` on every package that imports them. The workspace app's core selects
its own Dart registrant and Android plugin subset. Configure one
`plugins.project(pub = "@pub")` per hub; use separate hubs when workspace
members need different plugin or Maven overrides. See the
[workspace example](../tests/consumer/pub_workspace/).

## Testing a path package

A path package's tests may require development dependencies absent from the app
lock. Commit a package-specific `pubspec.lock`, declare a separate hub for its
tests, and configure a separate test package to use it. Keep the production
package on the app hub:

```python
# MODULE.bazel
pub_greeter = use_extension("@rules_flutter_core//flutter:extensions.bzl", "pub")
pub_greeter.lock(name = "pub_greeter", lock = "//packages/greeter:pubspec.lock")
use_repo(pub_greeter, "pub_greeter")

# packages/greeter/BUILD.bazel
flutter_package(name = "greeter", pub = "@pub", pubspec = ":pubspec")
flutter_package(
    name = "greeter_test_package",
    pub = "@pub_greeter",
    pubspec = ":pubspec",
)
flutter_test_suite(name = "tests", package = ":greeter_test_package")
```

For test execution and host prerequisites, see
[host tests](host-tests.md).

## Git dependencies

Git dependencies are fetched at the lockfile's `resolved-ref`; the commit id
verifies its tree. Any remote URL supported by Git is accepted, including
HTTPS, SSH, `git://`, and scp-like forms. `file://` and local paths are
rejected. Git packages do not initialize submodules. A lock's relative `path`
selects the package root inside a monorepo; absolute paths and `..` segments are
rejected, and that root must contain `pubspec.yaml`.

The generated package repository name is `<hub>-<package>`. For example,
`openfoodfacts_flutter_lints` in the `pub` hub is
`@pub-openfoodfacts_flutter_lints`. Git fetching runs the host `git` binary and
is not held in Bazel's HTTP download cache.

### Replacing a Git package repository

Use Bzlmod's `override_repo` to replace the package repository. This complete
example overrides `openfoodfacts_flutter_lints` with a local repository:

```python
pub = use_extension("@rules_flutter_core//flutter:extensions.bzl", "pub")
pub.lock(name = "pub", lock = "//:pubspec.lock")
local_repo = use_repo_rule("@bazel_tools//tools/build_defs/repo:local.bzl", "local_repository")
local_repo(name = "local_lints", path = "third_party/lints")
override_repo(pub, **{"pub-openfoodfacts_flutter_lints": "local_lints"})
use_repo(pub, "pub", "pub-openfoodfacts_flutter_lints")
```

The replacement repository must contain an empty `REPO.bazel`, a root
`pubspec.yaml`, and a `BUILD.bazel` exporting `pubspec.yaml` and defining `lib`
and `all` filegroups:

```python
# third_party/lints/BUILD.bazel
package(default_visibility = ["//visibility:public"])
exports_files(["pubspec.yaml"])
filegroup(name = "lib", srcs = glob(["lib/**"]) + ["pubspec.yaml"])
filegroup(
    name = "all",
    srcs = glob(["**"], exclude = ["BUILD.bazel", "REPO.bazel"]),
)
```

`lib` provides the package source tree; `all` provides its complete source
tree. To use a Git mirror instead of replacing the repository, configure Git's
normal URL rewrite in the user's Git configuration:

```sh
git config --global url."ssh://git.example.com/".insteadOf "https://github.com/"
```

Git applies that rewrite to the lock's original URL during fetch; the rules do
not read or manage Git credentials or configuration.
