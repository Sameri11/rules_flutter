"""Repositories exposing cached Android gen_snapshot payloads per ABI."""

visibility(["//:__pkg__"])

def _snapshot_path(ctx):
    host_os = ctx.os.name.lower()
    if host_os.startswith("mac os"):
        return ctx.path(ctx.attr.macos_artifact)
    if host_os.startswith("linux"):
        return ctx.path(ctx.attr.linux_artifact)
    fail("Unsupported host OS for a Flutter build: '{}'.".format(ctx.os.name))

def _gen_snapshot_impl(ctx):
    path = _snapshot_path(ctx)
    if path.exists:
        ctx.symlink(path, "gen_snapshot")
        ctx.file("BUILD.bazel", """load("@rules_flutter_core//flutter:target_toolchain.bzl", "flutter_aot_toolchain")

package(default_visibility = ["//visibility:public"])

exports_files(["gen_snapshot"])

flutter_aot_toolchain(
    name = "aot_toolchain",
    gen_snapshot_release = ":gen_snapshot",
    output_kind = "elf",
    output_name = "libapp.so",
    snapshot_kind = "app-aot-elf",
    output_flag = "--elf=",
    strip_flag = "--strip",
)
""")
    else:
        fail("No pinned Android gen_snapshot archive for {} on {}.".format(ctx.attr.engine_dir, ctx.os.name))

flutter_gen_snapshot = repository_rule(
    implementation = _gen_snapshot_impl,
    attrs = {
        "engine_dir": attr.string(mandatory = True),
        "macos_artifact": attr.label(mandatory = True, allow_single_file = True),
        "linux_artifact": attr.label(mandatory = True, allow_single_file = True),
    },
    local = True,
)
