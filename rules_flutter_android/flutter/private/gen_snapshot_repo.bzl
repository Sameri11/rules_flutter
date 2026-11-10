"""Repositories exposing cached Android gen_snapshot payloads per ABI."""

visibility(["//:__pkg__"])

def _snapshot_path(ctx):
    version_file = ctx.path(ctx.attr.version_file).realpath
    sdk_root = version_file.dirname.dirname.dirname
    host_os = ctx.os.name.lower()
    host_arch = {
        "aarch64": "arm64",
        "amd64": "x64",
        "arm64": "arm64",
        "riscv64": "riscv64",
        "x86_64": "x64",
    }.get(ctx.os.arch.lower())
    if host_arch == None:
        fail("Unsupported host architecture for a Flutter build: '{}'.".format(ctx.os.arch))
    if host_os.startswith("mac os"):
        host = "darwin-x64"
    elif host_os.startswith("linux"):
        host = "linux-" + host_arch
    elif host_os.startswith("windows"):
        host = "windows-" + host_arch
    else:
        fail("Unsupported host OS for a Flutter build: '{}'.".format(ctx.os.name))

    # Flutter currently stores Android gen_snapshot in the x64 engine directory on macOS.
    return sdk_root.get_child("bin/cache/artifacts/engine").get_child(ctx.attr.engine_dir).get_child(host).get_child("gen_snapshot")

def _availability_impl(ctx):
    path = _snapshot_path(ctx)
    available = path.exists
    ctx.file("available", "available\n" if available else "missing\n")
    ctx.file("BUILD.bazel", "package(default_visibility = [\"//visibility:public\"])\nexports_files([\"available\"])\n")

flutter_gen_snapshot_availability = repository_rule(
    implementation = _availability_impl,
    attrs = {
        "engine_dir": attr.string(mandatory = True),
        "version_file": attr.label(allow_single_file = True, default = Label("@flutter_sdk//:flutter.version.json")),
    },
    local = True,
)

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
)
""")
    else:
        ctx.file("BUILD.bazel", "package(default_visibility = [\"//visibility:public\"])\n")

flutter_gen_snapshot = repository_rule(
    implementation = _gen_snapshot_impl,
    attrs = {
        "engine_dir": attr.string(mandatory = True),
        "version_file": attr.label(allow_single_file = True, default = Label("@flutter_sdk//:flutter.version.json")),
    },
    local = True,
)
