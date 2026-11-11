"""Supported convenience BUILD API for Flutter Android consumer modules."""

load("@rules_flutter_core//flutter:composition.bzl", _core_flutter_assets = "flutter_assets")
load("@rules_flutter_core//flutter:defs.bzl", _flutter_platform = "flutter_platform", _flutter_target_slices_rule = "flutter_target_slices_rule", _platform_neutral_files_rule = "platform_neutral_files_rule")
load("//flutter:abis.bzl", "ABIS")
load("//flutter/private:abis.bzl", "bazel_platform")
load("//flutter/private:android_app.bzl", _FLUTTER_DEBUG_UNCOMPRESSED_ASSETS = "FLUTTER_DEBUG_UNCOMPRESSED_ASSETS", _flutter_android_app = "flutter_android_app")
load("//flutter/private:plugin_deps_guards.bzl", _flutter_plugin_deps_guards = "flutter_plugin_deps_guards")
load("//flutter/private:recipe.bzl", _flutter_native_contribution = "flutter_native_contribution")

# Clear outer split settings so each descriptor applies exactly its own target slice.
# rules_android's bytecode_transformer option is not an output: a consumer that
# sets it gets a second kernel and bundle configuration instead of sharing the
# split's host-neutral configuration.
_ANDROID_SLICE_OUTPUTS = [
    "//command_line_option:Android configuration distinguisher",
    "//command_line_option:android_compiler",
    "//command_line_option:android_platforms",
    "//command_line_option:compiler",
    "//command_line_option:dynamic_mode",
    "//command_line_option:platforms",
]

def _android_slice_transition_impl(_settings, attr):
    return {
        str(platform): {
            "//command_line_option:Android configuration distinguisher": "main",
            "//command_line_option:android_compiler": None,
            "//command_line_option:android_platforms": [],
            "//command_line_option:compiler": None,
            "//command_line_option:dynamic_mode": "default",
            "//command_line_option:platforms": [str(platform)],
        }
        for platform in attr.target_platforms
    }

_android_slice_transition = transition(
    implementation = _android_slice_transition_impl,
    inputs = [],
    outputs = _ANDROID_SLICE_OUTPUTS,
)

# One configuration keeps shared files from being rebuilt for each outer Android split.
def _android_neutral_transition_impl(_settings, _attr):
    return {
        "//command_line_option:Android configuration distinguisher": "main",
        "//command_line_option:android_compiler": None,
        "//command_line_option:android_platforms": [],
        "//command_line_option:compiler": None,
        "//command_line_option:dynamic_mode": "default",
        "//command_line_option:platforms": ["@platforms//host:host"],
    }

_android_neutral_transition = transition(
    implementation = _android_neutral_transition_impl,
    inputs = [],
    outputs = _ANDROID_SLICE_OUTPUTS,
)
_android_neutral_files = _platform_neutral_files_rule(_android_neutral_transition)

_android_target_slices = _flutter_target_slices_rule(_android_slice_transition)

_ANDROID_NATIVE_BUILD_ENV = Label("//flutter:native_build_env")

FLUTTER_ANDROID = _flutter_platform(
    name = "android",
    target_platforms = [bazel_platform(abi) for abi in ABIS],
    constraint = Label("@platforms//os:android"),
    slices_rule = _android_target_slices,
    neutral_files_rule = _android_neutral_files,
)

def flutter_assets(name, target_platforms, native_build_env = _ANDROID_NATIVE_BUILD_ENV, **kwargs):
    """Declares a public FlutterAssets action with Android target slices.

    Args:
      name: Name of the generated target.
      target_platforms: Android target platforms whose slices are bundled.
      native_build_env: Native build environment label.
      **kwargs: Arguments forwarded to the core flutter_assets rule.
    """
    if "target_slices" not in kwargs:
        slices_name = name + "_target_slices"
        _android_target_slices(
            name = slices_name,
            target_platforms = target_platforms,
        )
        kwargs["target_slices"] = [":" + slices_name]
    _core_flutter_assets(name = name, native_build_env = native_build_env, **kwargs)

def flutter_android_app(name, **kwargs):
    """Declares an Android app, wiring its debug artifacts to FLUTTER_ANDROID."""
    _flutter_android_app(name = name, debug_platforms = [FLUTTER_ANDROID], **kwargs)

flutter_plugin_deps_guards = _flutter_plugin_deps_guards
flutter_native_contribution = _flutter_native_contribution
FLUTTER_DEBUG_UNCOMPRESSED_ASSETS = _FLUTTER_DEBUG_UNCOMPRESSED_ASSETS
