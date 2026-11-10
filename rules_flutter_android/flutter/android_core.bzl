"""Android facade that supplies ABI data to the platform-neutral core macro."""

load("//flutter:abis.bzl", "ABIS")
load("//flutter/private:abis.bzl", "bazel_platform")
load("@rules_flutter_core//flutter:defs.bzl", _flutter_core = "flutter_core")


def flutter_android_core(**kwargs):
    _flutter_core(
        android_target_platforms = [bazel_platform(abi) for abi in ABIS],
        **kwargs
    )


