"""Declares the Android target toolchain implementations."""

load("@rules_flutter_core//flutter:target_toolchain.bzl", "flutter_target_toolchain")
load("//flutter:abis.bzl", "ABIS")

visibility(["//flutter:__pkg__"])

def flutter_android_target_toolchains():
    for abi, info in ABIS.items():
        suffix = abi.replace("-", "_")
        flutter_target_toolchain(
            name = "target_toolchain_" + suffix,
            target_os = "android",
            snapshot_flags = info.snapshot_flags,
            native_assets_key = info.manifest_key,
            target_platform = info.target_platform,
            slice_id = abi,
        )
