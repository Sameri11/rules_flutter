"""Declares the Android target toolchain implementations."""

load("@rules_flutter_core//flutter:abis.bzl", "ABIS")
load("@rules_flutter_core//flutter:target_toolchain.bzl", "flutter_target_toolchain")

visibility(["//flutter:__pkg__"])


def flutter_android_target_toolchains():
    for abi, info in ABIS.items():
        flutter_target_toolchain(
            name = "target_toolchain_" + abi.replace("-", "_"),
            target_os = "android",
            gen_snapshot_release = "@flutter_sdk//:gen_snapshot_{}_release".format(abi),
            snapshot_flags = info.snapshot_flags,
            native_assets_key = info.manifest_key,
            target_platform = info.target_platform,
            slice_id = abi,
        )
