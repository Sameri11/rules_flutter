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

def _abi(target_platform, engine_dir, maven_artifact, manifest_key, snapshot_flags = []):
    return struct(
        # `flutter build bundle --target-platform`.
        target_platform = target_platform,
        # Engine cache directory holding this ABI's gen_snapshot.
        engine_dir = engine_dir,
        # Maven artifact id on download.flutter.io.
        maven_artifact = maven_artifact,
        # The key the engine reads in NativeAssetsManifest.json. Baked in at
        # engine-compile time, so it is the engine that decides, not the build.
        manifest_key = manifest_key,
        # Extra gen_snapshot flags. Empty for everything but armv7.
        snapshot_flags = snapshot_flags,
    )

ABIS = {
    "arm64-v8a": _abi(
        target_platform = "android-arm64",
        engine_dir = "android-arm64-release",
        maven_artifact = "arm64_v8a_release",
        manifest_key = "android_arm64",
    ),
    "x86_64": _abi(
        target_platform = "android-x64",
        engine_dir = "android-x64-release",
        maven_artifact = "x86_64_release",
        manifest_key = "android_x64",
    ),
    "armeabi-v7a": _abi(
        target_platform = "android-arm",
        engine_dir = "android-arm-release",
        maven_artifact = "armeabi_v7a_release",
        manifest_key = "android_arm",
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

def gen_snapshot_label(abi):
    """The @flutter_sdk target holding this ABI's gen_snapshot.

    Args:
      abi: an Android ABI name, a key of ABIS.

    Returns:
      A label string.
    """
    return "@flutter_sdk//:gen_snapshot_" + abi

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
