"""Repositories for the Java embedding and Android engine artifacts."""

load("@rules_flutter_core//flutter:modes.bzl", "MODES")
load("//flutter:abis.bzl", "ABIS")

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

def _engine_impl(ctx):
    version = json.decode(ctx.read(ctx.path(ctx.attr.version_file)))
    artifact = ctx.attr.artifact
    url = "{}/{}/1.0.0-{}/{}-1.0.0-{}.jar".format(
        _BASE,
        artifact,
        version["engineRevision"],
        artifact,
        version["engineContentHash"],
    )
    ctx.download(url = url, output = "jar/{}.jar".format(artifact), canonical_id = url)
    ctx.extract(archive = ctx.path("jar/{}.jar".format(artifact)), output = "jar")
    ctx.file("jar/BUILD.bazel", """filegroup(
    name = "file",
    srcs = ["{}.jar"],
    visibility = ["//visibility:public"],
)

filegroup(
    name = "libs",
    srcs = glob(["lib/**/*.so"], allow_empty = True),
    visibility = ["//visibility:public"],
)
""".format(artifact))

flutter_android_engine_jar = repository_rule(
    implementation = _engine_impl,
    attrs = {
        "artifact": attr.string(mandatory = True),
        "version_file": attr.label(
            allow_single_file = True,
            default = Label("@flutter_sdk//:flutter.version.json"),
        ),
    },
)

def _embedding_extension_impl(_ctx):
    for mode in MODES:
        flutter_embedding_jar(name = "flutter_embedding_" + mode, mode = mode)
    for abi, info in ABIS.items():
        for mode in MODES:
            flutter_android_engine_jar(
                name = "flutter_engine_{}_{}".format(abi.replace("-", "_"), mode),
                artifact = info.maven_artifact[mode],
            )

flutter_android_embedding = module_extension(implementation = _embedding_extension_impl)
