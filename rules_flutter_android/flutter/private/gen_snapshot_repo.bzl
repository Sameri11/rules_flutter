"""Host-platform repositories exposing Android gen_snapshot from pinned engine archives."""

def _gen_snapshot_file_impl(ctx):
    files = ctx.attr.files[DefaultInfo].files.to_list()
    candidates = [file for file in files if file.basename == "gen_snapshot"]
    if len(candidates) != 1:
        fail("Pinned engine archive for {} contains {} gen_snapshot files; expected exactly one.".format(ctx.attr.engine_dir, len(candidates)))
    output = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.symlink(output = output, target_file = candidates[0], is_executable = True)
    return [DefaultInfo(files = depset([output]), executable = output)]

gen_snapshot_file = rule(
    implementation = _gen_snapshot_file_impl,
    executable = True,
    attrs = {
        "engine_dir": attr.string(mandatory = True),
        "files": attr.label(mandatory = True),
    },
)

def _gen_snapshot_impl(ctx):
    host_os = ctx.os.name.lower()
    if host_os.startswith("mac os"):
        artifact = ctx.attr.macos_artifact
    elif host_os.startswith("linux"):
        artifact = ctx.attr.linux_artifact
    else:
        fail("Unsupported host OS for a Flutter build: '{}'.".format(ctx.os.name))
    ctx.file("BUILD.bazel", """load(%s, "gen_snapshot_file")
load("@rules_flutter_core//flutter:target_toolchain.bzl", "flutter_aot_toolchain")

package(default_visibility = ["//visibility:public"])

gen_snapshot_file(
    name = "gen_snapshot",
    files = %s,
    engine_dir = %s,
)

flutter_aot_toolchain(
    name = "aot_toolchain",
    gen_snapshot_release = ":gen_snapshot",
    output_kind = "elf",
    output_name = "libapp.so",
    snapshot_kind = "app-aot-elf",
    output_flag = "--elf=",
    strip_flag = "--strip",
)
""" % (
        repr(str(Label("//flutter/private:gen_snapshot_repo.bzl"))),
        repr(str(artifact)),
        repr(ctx.attr.engine_dir),
    ))

flutter_gen_snapshot = repository_rule(
    implementation = _gen_snapshot_impl,
    attrs = {
        "engine_dir": attr.string(mandatory = True),
        "macos_artifact": attr.label(mandatory = True),
        "linux_artifact": attr.label(mandatory = True),
    },
)
