"""Analysis checks for the generated native carrier."""

# The generated hub exposes this provider to packaging rules.
# buildifier: disable=bzl-visibility
load("@rules_flutter_android//flutter/private:native_files.bzl", "FlutterNativeFilesByAbiInfo")

def _native_files_check_impl(ctx):
    files = ctx.attr.carrier[FlutterNativeFilesByAbiInfo].files
    expected_abis = ["arm64-v8a", "armeabi-v7a", "x86_64"]
    if sorted(files.keys()) != expected_abis:
        fail("unexpected carrier ABIs: {}".format(sorted(files.keys())))
    for abi in expected_abis:
        names = sorted([f.basename for f in files[abi].to_list()])
        if names != sorted(ctx.attr.expected):
            fail("{}: expected {}, got {}".format(abi, sorted(ctx.attr.expected), names))
        marker = [f for f in files[abi].to_list() if f.basename == "libcmake_marker.so"][0]
        is_override = "/composed_app/" in marker.path
        if is_override != ctx.attr.override:
            fail("{}: wrong CMake implementation: {}".format(abi, marker.path))
    return [DefaultInfo(files = depset())]

native_files_check = rule(
    implementation = _native_files_check_impl,
    attrs = {
        "carrier": attr.label(mandatory = True, providers = [FlutterNativeFilesByAbiInfo]),
        "expected": attr.string_list(),
        "override": attr.bool(),
    },
)
