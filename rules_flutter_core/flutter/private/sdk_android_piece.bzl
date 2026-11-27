"""Lazy repositories for Android target artifacts from a pinned Flutter engine."""

visibility(["//flutter/private:__pkg__"])

def _android_piece_impl(ctx):
    if ctx.attr.failure_message:
        ctx.file("BUILD.bazel", """load(%s, "flutter_sdk_missing")

package(default_visibility = ["//visibility:public"])

flutter_sdk_missing(
    name = "files",
    message = %s,
)
flutter_sdk_missing(
    name = "gen_snapshot",
    message = %s,
)
""" % (
            repr(str(Label("//flutter:sdk_failure.bzl"))),
            repr(ctx.attr.failure_message),
            repr(ctx.attr.failure_message),
        ))
        return
    ctx.download_and_extract(
        url = ctx.attr.urls,
        output = ".",
        sha256 = ctx.attr.sha256,
        type = "zip",
    )
    ctx.file("BUILD.bazel", """package(default_visibility = [\"//visibility:public\"])
filegroup(name = \"files\", srcs = glob([\"**\"], allow_empty = True))
exports_files(glob([\"**\"], allow_empty = True))
""")

sdk_android_piece = repository_rule(
    implementation = _android_piece_impl,
    attrs = {
        "urls": attr.string_list(mandatory = True),
        "sha256": attr.string(mandatory = True),
        "failure_message": attr.string(),
    },
)
