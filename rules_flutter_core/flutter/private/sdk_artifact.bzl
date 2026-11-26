"""Pinned Flutter SDK artifact repositories."""

visibility(["//flutter"])

_DEFAULT_BUILD = """package(default_visibility = ["//visibility:public"])
exports_files(glob(["**"], allow_empty = True))
filegroup(name = "all", srcs = glob(["**"], allow_empty = True))
"""


def _sdk_artifact_impl(ctx):
    if ctx.attr.archive_type == "file":
        ctx.download(
            url = ctx.attr.urls,
            output = ctx.attr.file_name,
            sha256 = ctx.attr.sha256,
        )
        ctx.file("BUILD.bazel", "package(default_visibility = [\"//visibility:public\"])\nexports_files([\"{}\"])\nfilegroup(name = \"all\", srcs = [\"{}\"])\n".format(ctx.attr.file_name, ctx.attr.file_name))
    else:
        ctx.download_and_extract(
            url = ctx.attr.urls,
            sha256 = ctx.attr.sha256,
            type = ctx.attr.archive_type,
            strip_prefix = ctx.attr.strip_prefix,
        )
        ctx.file("BUILD.bazel", ctx.attr.build_file_content or _DEFAULT_BUILD)


sdk_artifact = repository_rule(
    implementation = _sdk_artifact_impl,
    attrs = {
        "urls": attr.string_list(mandatory = True),
        "sha256": attr.string(mandatory = True),
        "archive_type": attr.string(mandatory = True),
        "strip_prefix": attr.string(),
        "build_file_content": attr.string(),
        "file_name": attr.string(default = "artifact.json"),
    },
)
