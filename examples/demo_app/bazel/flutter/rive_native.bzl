"""Recipe for rive_native's Kotlin plugin and prebuilt Android libraries."""

# Load from the defining module; @@// is root-module-relative.
load("@rules_flutter//tools/flutter:recipe.bzl", "flutter_native_contribution")
load("@rules_kotlin//kotlin:android.bzl", "kt_android_library")

# The archive's supported ABIs. Label() resolves repositories in this module.
_LIBRARIES = {
    "arm64-v8a": Label("@rive_native_android//:arm64_v8a"),
    "x86_64": Label("@rive_native_android//:x86_64"),
    "armeabi-v7a": Label("@rive_native_android//:armeabi_v7a"),
}

def rive_native_recipe(name, info):
    """Build the Kotlin plugin and attach its prebuilt native libraries.

    Args:
      name: Generated package target name.
      info: Package metadata.
    """

    # Match the generator's Kotlin plugin target.
    kt_android_library(
        name = name,
        srcs = info.android_srcs,
        manifest = info.android_manifest,
        custom_package = info.namespace,
        exports_manifest = 1,
        deps = [info.embedding] + info.plugin_deps + info.coordinates,
    )

    # The archive supplies one librive_native.so for each requested ABI.
    for abi in info.abis:
        if abi not in _LIBRARIES:
            fail("rive_native_recipe has no prebuilt for {}; the archive holds {}.".format(
                abi,
                sorted(_LIBRARIES),
            ))

    flutter_native_contribution(
        name = name + "_flutter_native",
        libraries = {abi: _LIBRARIES[abi] for abi in info.abis},
    )
