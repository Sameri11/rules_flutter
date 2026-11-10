"""Android facade that supplies ABI data to the platform-neutral core macro."""

load("@rules_flutter_core//flutter:abis.bzl", "ABIS")
load("@rules_flutter_core//flutter:defs.bzl", _flutter_core = "flutter_core")


def flutter_android_core(**kwargs):
    _flutter_core(
        android_target_data = [
            struct(
                abi = abi,
                target_platform = info.target_platform,
                native_assets_key = info.manifest_key,
            )
            for abi, info in ABIS.items()
        ],
        **kwargs
    )
