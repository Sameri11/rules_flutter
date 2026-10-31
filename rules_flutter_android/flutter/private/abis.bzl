"""Android-only facts for each ABI, keyed by the names in the public ABI table.

The table itself is public in `@rules_flutter_core//flutter:abis.bzl`. What only
the Android rules need lives here: the rules_android platform that selects an
ABI's NDK toolchain, the minimum SDK, and the names of the plugin repository's
per-ABI aggregates.
"""

load("@rules_flutter_core//flutter:abis.bzl", "ABIS", "abi_from_platform")

visibility(["//flutter/...", "//tests/..."])

# The platform rules_android packages an ABI's native libraries under. The name
# must equal the ABI: rules_android writes them to lib/<platform name>/, so a
# mismatch would place this ABI's libraries under another ABI's directory.
_BAZEL_PLATFORMS = {
    "arm64-v8a": "@rules_android//:arm64-v8a",
    "x86_64": "@rules_android//:x86_64",
    "armeabi-v7a": "@rules_android//:armeabi-v7a",
}

def _check_bazel_platforms():
    if sorted(_BAZEL_PLATFORMS) != sorted(ABIS):
        fail("abis.bzl: _BAZEL_PLATFORMS names {}, but ABIS names {}.".format(
            sorted(_BAZEL_PLATFORMS),
            sorted(ABIS),
        ))
    for abi, platform in _BAZEL_PLATFORMS.items():
        name = Label(platform).name
        if name != abi:
            fail((
                "abis.bzl: _BAZEL_PLATFORMS['{}'] names platform '{}', not '{}'. " +
                "rules_android packages native libraries under lib/<platform name>/, " +
                "so a mismatched name would place this ABI's libraries under another " +
                "ABI's directory."
            ).format(abi, name, abi))
    return True

# Checked when this file loads, so a mismatch fails every build that reads it.
# buildifier: disable=unused-variable
_ = _check_bazel_platforms()

def bazel_platform(abi):
    """The rules_android platform label that selects one ABI's toolchain."""
    return _BAZEL_PLATFORMS[abi]

# The floor these rules ask for. rules_android applies its own floor during
# resource processing and clamps manifest_values against it, so an APK can
# declare a higher minimum than this.
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

def check_platform_abi(ctx):
    """Verify that a platform transition selected the platform for `ctx.attr.abi`.

    Only valid on rules that transition `--platforms` from `abi`; returns
    `ctx.attr.abi`.

    Args:
      ctx: the rule context; must carry ABI_PLATFORM_ATTRS and an `abi` attribute.

    Returns:
      `ctx.attr.abi`, after verifying it against the target platform.
    """
    found = abi_from_platform(ctx)
    if found == None:
        fail((
            "{}: target platform '{}' is not Android, or names no CPU " +
            "constraint this ruleset recognizes, so it cannot be checked " +
            "against abi = '{}'. This rule transitions --platforms from its " +
            "own `abi` attribute; if that transition is ever removed, this " +
            "check should go with it."
        ).format(ctx.label, ctx.attr.platform, ctx.attr.abi))
    if found not in ABIS:
        fail((
            "{}: target platform '{}' is Android/{}, which this ruleset does " +
            "not support (abi = '{}'). Supported: {}."
        ).format(ctx.label, ctx.attr.platform, found, ctx.attr.abi, sorted(ABIS)))
    if found != ctx.attr.abi:
        fail((
            "{}: abi = '{}' but target platform '{}' carries the CPU " +
            "constraint for '{}'. ABIS['{}'].cpu_constraint = {} names the " +
            "wrong ABI."
        ).format(
            ctx.label,
            ctx.attr.abi,
            ctx.attr.platform,
            found,
            ctx.attr.abi,
            ABIS[ctx.attr.abi].cpu_constraint,
        ))
    return found
