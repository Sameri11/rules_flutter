"""Recipe for the `rive_native` pub package.

This file is *consumer* code, not part of the rules. It lives here because this
repository is its own test subject; in a real project it would sit in the app's
own workspace and the rules would be a bazel_dep.

`rive_native` ships an entirely ordinary Android module -- one Kotlin source, a
manifest, a namespace -- and never compiles its native half. Upstream, a Gradle
`Exec` task shells out to `dart run rive_native:setup -p android`, which
downloads a prebuilt archive and unpacks it into `src/main/jniLibs/`. Nothing in
this build runs Gradle, so without a recipe the `.so` never arrives and the
package is gated `prebuilt_jni_libs`.

So the recipe replaces exactly one thing: where the library comes from. The
Kotlin half is built the same way the generator would have built it.
"""

load("@rules_kotlin//kotlin:android.bzl", "kt_android_library")
load("@@//tools/flutter:recipe.bzl", "flutter_native_contribution")

def rive_native_recipe(name, info):
    """Build rive_native: Kotlin from source, .so from the archive pinned in MODULE.bazel."""
    if info.contract_version != 1:
        fail("rive_native_recipe understands contract 1, got {}".format(
            info.contract_version,
        ))

    # Identical in kind to what the generator emits for any Kotlin plugin, and
    # deliberately so -- the label a consumer names is @flutter_plugins//rive_native
    # either way. kt_android_library rather than android_library because the
    # source is .kt, and exports_manifest is the raw tri-state int there.
    kt_android_library(
        name = name,
        srcs = info.android_srcs,
        manifest = info.android_manifest,
        custom_package = info.namespace,
        exports_manifest = 1,
        deps = [info.embedding] + info.plugin_deps + info.coordinates,
    )

    # The plugin's Kotlin does System.loadLibrary("rive_native") in a companion
    # init, so the file has to be exactly librive_native.so under lib/<abi>/.
    # That is what the archive already calls it, so no renaming is involved --
    # but it is the reason this is not interchangeable with any other .so.
    flutter_native_contribution(
        name = name + "_flutter_native",
        jni_libs = ["@rive_native_android//:arm64_v8a"],
    )
