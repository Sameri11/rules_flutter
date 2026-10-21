"""Recipe for the `sqlite3` pub package.

Consumer code, like rive_native.bzl beside it.

`sqlite3` is not a Flutter plugin. It has no `android/` module, so nothing in
`.flutter-plugins-dependencies` refers to it and the plugin generator could never
see it -- which is why recipes are keyed on pub package rather than on plugin.
Its native half comes from a Dart build hook (`hook/build.dart`), and the Dart VM
resolves the library by *asset id* rather than by library name.

The hook looks like arbitrary code, and is: it chooses at run time between
downloading a prebuilt binary, compiling C via `native_toolchain_c`, and linking
a system library. But its *default* path -- no user defines, which is this app's
case -- is `PrecompiledFromGithubAssets`: a download from a GitHub release whose
sha256 the package already publishes in `lib/src/hook/asset_hashes.dart`. Which
is an http_file, exactly. See docs_internal/package-recipes.md.

Nothing here generates the asset mapping. `flutter build bundle` already writes a
correct `NativeAssetsManifest.json` into the bundle and the engine reads it at
runtime; `code_assets` below is checked *against* that, not used to produce it.
"""

load("@rules_flutter//flutter:defs.bzl", "flutter_native_contribution")

# `Label()` rather than a bare string, and that is load bearing. This macro runs
# while the *generated* @flutter_plugins BUILD file is loaded, and a label string
# a macro hands to a rule resolves in the repo mapping of the package being
# loaded -- rules_flutter's, not ours. So `"@libsqlite3_android_arm64//file"`
# named the http_file in the *rules'* MODULE.bazel, not the one in ours, and
# picked up whatever they happened to call theirs. It resolved, built and shipped
# a real libsqlite3.so, so nothing said otherwise until they renamed it per ABI.
#
# Label() is evaluated here, against this file's own module, which is where the
# repo we mean is declared.
_LIBRARIES = {"arm64-v8a": Label("@libsqlite3_android_arm64//file")}

def sqlite3_recipe(name, info):
    """Attach the prebuilt libsqlite3.so the build hook would have downloaded."""
    if info.is_plugin:
        fail("sqlite3 is not expected to be a Flutter plugin; the generator saw one")

    for abi in info.abis:
        if abi not in _LIBRARIES:
            fail("sqlite3_recipe has no prebuilt for {}; MODULE.bazel pins {}.".format(
                abi,
                sorted(_LIBRARIES),
            ))

    flutter_native_contribution(
        name = name + "_flutter_native",
        libraries = {abi: _LIBRARIES[abi] for abi in info.abis},
        # Declared so the filename is checked rather than assumed. The VM
        # resolves this id through the bundle's NativeAssetsManifest.json, which
        # names the library by bare filename -- so a rename here is a runtime
        # failure with no build-time signal, and this turns it into one.
        code_assets = {
            "package:sqlite3/src/ffi/libsqlite3.g.dart": "libsqlite3.so",
        },
    )

    # There is no Android module, so there is no library target -- but `:<name>`
    # still has to exist, because the generated aggregate names every recipe'd
    # package uniformly. An empty filegroup is the honest answer.
    native.filegroup(name = name, srcs = [])
