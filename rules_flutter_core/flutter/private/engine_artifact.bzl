"""Lazy repositories for engine artifacts declared by platform rulesets."""

visibility(["//flutter"])

def _engine_artifact_impl(ctx):
    if ctx.attr.failure_message:
        ctx.file("BUILD.bazel", """load(%s, "flutter_sdk_missing")

package(default_visibility = ["//visibility:public"])

flutter_sdk_missing(
    name = "files",
    message = %s,
)
""" % (
            repr(str(Label("//flutter/private:sdk_failure.bzl"))),
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

engine_artifact_repo = repository_rule(
    implementation = _engine_artifact_impl,
    attrs = {
        "urls": attr.string_list(mandatory = True),
        "sha256": attr.string(mandatory = True),
        "failure_message": attr.string(),
    },
)
