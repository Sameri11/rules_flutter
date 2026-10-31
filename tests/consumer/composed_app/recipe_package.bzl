"""Consumer-owned native contribution for recipe_package."""

load("@rules_android//rules:rules.bzl", "android_library")
load("@rules_flutter_android//flutter:defs.bzl", "flutter_native_contribution")

_LIBRARY = Label("//composed_app:librecipe_marker.so")
_OVERRIDE_LIBRARY = Label("//composed_app:libcmake_marker.so")
_PLATFORMS = {
    "arm64-v8a": Label("@rules_android//:arm64-v8a"),
    "x86_64": Label("@rules_android//:x86_64"),
    "armeabi-v7a": Label("@rules_android//:armeabi-v7a"),
}

def _platform_transition_impl(_settings, attr):
    return {"//command_line_option:platforms": [str(attr.platform)]}

_platform_transition = transition(
    implementation = _platform_transition_impl,
    inputs = [],
    outputs = ["//command_line_option:platforms"],
)

def _library_impl(ctx):
    return [DefaultInfo(files = ctx.attr.src[DefaultInfo].files)]

_library_for_platform = rule(
    implementation = _library_impl,
    cfg = _platform_transition,
    attrs = {
        "platform": attr.label(mandatory = True),
        "src": attr.label(mandatory = True, allow_single_file = True),
    },
)

def _contribution(name, info, library):
    libraries = {}
    for abi in info.abis:
        target = name + "_library_" + abi.replace("-", "_")
        _library_for_platform(name = target, src = library, platform = _PLATFORMS[abi])
        libraries[abi] = ":" + target
    flutter_native_contribution(name = name + "_flutter_native", libraries = libraries)

def recipe_package_recipe(name, info):
    _contribution(name, info, _LIBRARY)
    native.filegroup(name = name, srcs = [])

def cmake_override_recipe(name, info):
    _contribution(name, info, _OVERRIDE_LIBRARY)
    android_library(
        name = name,
        srcs = info.android_srcs,
        manifest = info.android_manifest,
        custom_package = info.namespace,
        deps = [info.embedding],
    )
