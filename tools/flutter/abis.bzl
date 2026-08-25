"""One table mapping an Android ABI to every name the build needs for it.

The same architecture is spelled differently by the NDK, by `flutter build
bundle`, by the engine cache, by Maven, by rules_android's platforms and by the
native-assets manifest. **The ABI name is the public spelling** -- it is what
appears in the APK and what a consumer writes; the rest are derived here and
never typed by hand.

This is the Android half of the slice table the roadmap's convergences describe.
Apple slices belong beside it rather than in a second file: two tables would
have to agree about the same architectures forever.

`x86` is absent deliberately. The SDK precaches no `android-x86` engine, so
there is no `gen_snapshot` to pair with an x86 library however many a package
publishes.
"""

MODES = ["release", "debug"]

# Modes that require gen_snapshot.
AOT_MODES = ["release"]

def _abi(target_platform, engine_dir, maven_artifact, manifest_key, bazel_platform, snapshot_flags = []):
    return struct(
        # `flutter build bundle --target-platform`.
        target_platform = target_platform,
        engine_dir = engine_dir,
        maven_artifact = maven_artifact,
        # The key the engine reads in NativeAssetsManifest.json. Baked in at
        # engine-compile time, so it is the engine that decides, not the build.
        manifest_key = manifest_key,
        # rules_android's platform, which selects the NDK cc_toolchain that
        # cross-strips this ABI's libraries.
        bazel_platform = bazel_platform,
        # Extra gen_snapshot flags. Empty for everything but armv7.
        snapshot_flags = snapshot_flags,
    )

ABIS = {
    "arm64-v8a": _abi(
        target_platform = "android-arm64",
        engine_dir = {"release": "android-arm64-release"},
        maven_artifact = {
            "release": "arm64_v8a_release",
            "debug": "arm64_v8a_debug",
        },
        manifest_key = "android_arm64",
        bazel_platform = "@rules_android//:arm64-v8a",
    ),
    "x86_64": _abi(
        target_platform = "android-x64",
        engine_dir = {"release": "android-x64-release"},
        maven_artifact = {
            "release": "x86_64_release",
            "debug": "x86_64_debug",
        },
        manifest_key = "android_x64",
        bazel_platform = "@rules_android//:x86_64",
    ),
    "armeabi-v7a": _abi(
        target_platform = "android-arm",
        engine_dir = {"release": "android-arm-release"},
        maven_artifact = {
            "release": "armeabi_v7a_release",
            "debug": "armeabi_v7a_debug",
        },
        manifest_key = "android_arm",
        bazel_platform = "@rules_android//:armeabi-v7a",
        # The only ABI needing flags, and the reason they live in a table rather
        # than a rule body. flutter_tools passes both for armv7 (softfp, and no
        # integer division on 32-bit Pixels). Omitting them yields a snapshot
        # that builds, links and installs, then executes an unsupported
        # instruction on the affected device.
        snapshot_flags = [
            "--no-sim-use-hardfp",
            "--no-use-integer-division",
        ],
    ),
}

def engine_repo(abi, mode):
    """Name of the repository holding one ABI's prebuilt engine jar in one mode.

    Args:
      abi: an Android ABI name, a key of ABIS.
      mode: "release" or "debug".

    Returns:
      A repository name; `-` is not valid in one, so it becomes `_`.
    """
    return "flutter_engine_{}_{}".format(abi.replace("-", "_"), mode)

def engine_jar_label(abi, mode):
    """The prebuilt engine jar for one ABI in one mode.

    A `Label`, not a string: a string handed to an attribute from inside a macro
    resolves in the *caller's* repo mapping, and these repositories are our
    extension's. Resolving here is what keeps the engine out of consumer BUILD
    files.

    Args:
      abi: an Android ABI name, a key of ABIS.
      mode: "release" or "debug".

    Returns:
      A Label for the unstripped engine jar.
    """
    return Label("@{}//jar:file".format(engine_repo(abi, mode)))

def embedding_repo(mode):
    """Name of the repository holding the Java embedding jar for one mode.

    Architecture-independent -- unlike engine_repo, there is no ABI axis --
    but mode-keyed for the same reason: `BuildConfig.DEBUG` is a
    `static final boolean`, so the jar a `MainActivity` compiles against fixes
    the mode, and only the debug jar's carries service-protocol/JIT support.

    Args:
      mode: "release" or "debug".

    Returns:
      A repository name.
    """
    return "flutter_embedding_" + mode

def gen_snapshot_label(abi, mode):
    """The @flutter_sdk target holding this ABI's gen_snapshot for one AOT mode.

    A `Label`, for the same reason engine_jar_label returns one: a string handed
    to an attribute from inside a macro resolves in the *caller's* repo mapping,
    and @flutter_sdk is our extension's. Resolving here is what lets a consumer
    import nothing from the `flutter` extension at all.

    Args:
      abi: an Android ABI name, a key of ABIS.
      mode: an AOT_MODES entry.

    Returns:
      A Label for that ABI's gen_snapshot in that mode.
    """
    return Label("@flutter_sdk//:gen_snapshot_{}_{}".format(abi, mode))

def aot_target_compatible_with():
    """target_compatible_with for a rule that only runs under an AOT-capable mode.

    Built from AOT_MODES rather than naming "debug" directly, so adding
    "profile" to that one list is the whole edit needed to make an AOT rule
    compatible with it too -- see docs_internal/build-modes-plan.md. Every
    mode this omits reports "target incompatible with the current
    configuration" during analysis instead of reaching gen_snapshot with a
    kernel it rejects.

    Returns:
      A select() value for a `target_compatible_with` attribute.
    """
    conditions = {"//conditions:default": [Label("@platforms//:incompatible")]}
    for mode in AOT_MODES:
        conditions[Label("//tools/flutter:mode_" + mode)] = []
    return select(conditions)

def aot_gen_snapshot(abi):
    """select() choosing one ABI's gen_snapshot for whichever AOT mode is active.

    Built from AOT_MODES for the same reason as aot_target_compatible_with.
    The default branch is only a placeholder for configurations where the
    depending rule is itself target-incompatible (every mode outside
    AOT_MODES), so it is never actually consumed.

    Args:
      abi: an Android ABI name, a key of ABIS.

    Returns:
      A select() value for a `gen_snapshot` attribute.
    """
    conditions = {
        Label("//tools/flutter:mode_" + mode): gen_snapshot_label(abi, mode)
        for mode in AOT_MODES
    }
    conditions["//conditions:default"] = gen_snapshot_label(abi, AOT_MODES[0])
    return select(conditions)

# The API level the whole Android build targets: the `minSdkVersion` an APK
# declares, and the `ANDROID_PLATFORM` a plugin's CMake build compiles against.
# One constant because the two have to agree, and they are read from two
# different files -- android.bzl for the manifest, plugins.bzl for CMake.
#
# What an APK finally declares can be *higher*: rules_android applies its own
# min-SDK floor during resource processing (`bump_min_sdk`, currently 23) and
# clamps `manifest_values` against it, so this is the floor these rules ask for,
# not the floor that ships. See docs_internal/api-surface.md.
MIN_SDK = 21

# The generated plugin repository's per-slice aggregates. plugins.bzl emits these
# target names and android.bzl derives labels for them, so the contract lives
# here rather than as a string that happens to match in two files.
_PLUGIN_REPO_TARGETS = {
    # Every .so a package *recipe* contributed for one ABI.
    "recipe_libraries": "native_libs_{}",
    # Every .so the native *plugins* built for one ABI.
    "plugin_native_libraries": "plugin_libs_{}",
}

def plugin_repo_target(kind, abi):
    """Target name in @flutter_plugins holding one ABI's libraries.

    Args:
      kind: a key of _PLUGIN_REPO_TARGETS -- the contribution kind it feeds.
      abi: the ABI whose aggregate is wanted.

    Returns:
      A bare target name, without a repository or package.
    """
    if kind not in _PLUGIN_REPO_TARGETS:
        fail("plugin_repo_target: unknown kind '{}'. Known: {}.".format(
            kind,
            sorted(_PLUGIN_REPO_TARGETS),
        ))
    return _PLUGIN_REPO_TARGETS[kind].format(abi)

def check_abis(abis, where):
    """Fails with the supported set listed, rather than a KeyError.

    Args:
      abis: the ABI names a caller asked for.
      where: what to name in the failure, usually the calling target.
    """
    if not abis:
        fail("{}: `abis` must name at least one ABI, one of {}.".format(
            where,
            sorted(ABIS),
        ))
    for abi in abis:
        if abi not in ABIS:
            fail("{}: unknown ABI '{}'. Supported: {}.".format(
                where,
                abi,
                sorted(ABIS),
            ))
