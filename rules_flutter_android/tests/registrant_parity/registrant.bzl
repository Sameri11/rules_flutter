"""A repository rule that renders one pub hub's Android registrants for the parity check.

The same rendering the Android plugins repository performs, from the same
metadata, so diff_test can compare it with flutter_tools' output.
"""

load("//flutter/private:registrant.bzl", "package_roots", "write_android_registrants")

def _registrant_parity_android_impl(rctx):
    metadata = json.decode(rctx.read(rctx.attr.metadata))
    write_android_registrants(rctx, metadata, package_roots(rctx))
    rctx.file("BUILD.bazel", """package(default_visibility = ["//visibility:public"])

exports_files([
    "android/debug/GeneratedPluginRegistrant.java",
    "android/release/GeneratedPluginRegistrant.java",
])
""")

registrant_parity_android = repository_rule(
    implementation = _registrant_parity_android_impl,
    doc = "The Android GeneratedPluginRegistrant.java of one pub hub, for the parity check.",
    attrs = {
        "metadata": attr.label(allow_single_file = True, mandatory = True),
        "package_config": attr.label(allow_single_file = True, mandatory = True),
    },
)
