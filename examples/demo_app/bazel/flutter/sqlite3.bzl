"""Recipe for sqlite3's prebuilt Android library.

sqlite3 is not a Flutter plugin; its Dart build hook normally downloads this
asset. flutter build bundle emits the NativeAssetsManifest that consumes the
code asset below.
"""

# Resolve these repositories in this module, where MODULE.bazel declares them.
# Bare apparent names would resolve in the generated repository's mapping.
load("@rules_flutter//tools/flutter:recipe.bzl", "flutter_native_contribution")

_LIBRARIES = {
    "arm64-v8a": Label("@libsqlite3_android_arm64_v8a//file"),
    "x86_64": Label("@libsqlite3_android_x86_64//file"),
    "armeabi-v7a": Label("@libsqlite3_android_armeabi_v7a//file"),
}

def sqlite3_recipe(name, info):
    """Attach sqlite3's prebuilt native library.

    Args:
      name: Generated package target name.
      info: Package metadata.
    """
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
        # Verify the filename required by NativeAssetsManifest.
        code_assets = {
            "package:sqlite3/src/ffi/libsqlite3.g.dart": "libsqlite3.so",
        },
    )

    # The aggregate expects every recipe package to provide this target.
    native.filegroup(name = name, srcs = [])
