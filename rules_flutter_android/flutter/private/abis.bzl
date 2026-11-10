"""Android-only toolchain and SDK facts."""

load("//flutter:abis.bzl", "ABIS", "abi_from_platform")

visibility(["//flutter/...", "//tests/..."])

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

MIN_SDK = 21

def check_abis(abis, where):
    if not abis:
        fail("{}: `abis` must name at least one ABI, one of {}.".format(where, sorted(ABIS)))
    for abi in abis:
        if abi not in ABIS:
            fail("{}: unknown ABI '{}'. Supported: {}.".format(where, abi, sorted(ABIS)))

def check_platform_abi(ctx):
    found = abi_from_platform(ctx)
    if found == None:
        fail("{}: target platform '{}' is not Android, or names no CPU.".format(ctx.label, ctx.attr.platform))
    if found not in ABIS:
        fail("{}: target platform '{}' is Android/{}, which this ruleset does not support (abi = '{}'). Supported: {}.".format(
            ctx.label,
            ctx.attr.platform,
            found,
            ctx.attr.abi,
            sorted(ABIS),
        ))
    if found != ctx.attr.abi:
        fail("{}: abi = '{}' but target platform '{}' carries the CPU constraint for '{}'. ABIS['{}'].cpu_constraint = {} names the wrong ABI.".format(
            ctx.label,
            ctx.attr.abi,
            ctx.attr.platform,
            found,
            ctx.attr.abi,
            ABIS[ctx.attr.abi].cpu_constraint,
        ))
    return found

