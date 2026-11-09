"""Repositories for the Java embedding used by Android consumers."""

visibility(["//:__pkg__"])

_BASE = "https://storage.googleapis.com/download.flutter.io/io/flutter"


def _embedding_impl(ctx):
    version = json.decode(ctx.read(ctx.path(ctx.attr.version_file)))
    artifact = "flutter_embedding_{}".format(ctx.attr.mode)
    url = "{}/{}/1.0.0-{}/{}-1.0.0-{}.jar".format(
        _BASE,
        artifact,
        version["engineRevision"],
        artifact,
        version["engineContentHash"],
    )
    ctx.download(url = url, output = "jar/{}.jar".format(artifact), canonical_id = url)
    ctx.file("jar/BUILD.bazel", """filegroup(
    name = "file",
    srcs = ["{}.jar"],
    visibility = ["//visibility:public"],
)
""".format(artifact))

flutter_embedding_jar = repository_rule(
    implementation = _embedding_impl,
    attrs = {
        "mode": attr.string(mandatory = True, values = ["debug", "release"]),
        "version_file": attr.label(
            allow_single_file = True,
            default = Label("@flutter_sdk//:flutter.version.json"),
        ),
    },
)


def _embedding_extension_impl(ctx):
    for mode in ["debug", "release"]:
        flutter_embedding_jar(name = "flutter_embedding_" + mode, mode = mode)

flutter_android_embedding = module_extension(implementation = _embedding_extension_impl)
