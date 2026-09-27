"""Host-compatible registration for the statically defined Flutter toolchain."""

_TOOLCHAIN_BUILD_TEMPLATE = """package(default_visibility = ["//visibility:public"])

toolchain(
    name = "flutter",
    toolchain = "{toolchain_target}",
    toolchain_type = "{toolchain_type}",
    exec_compatible_with = {exec_compatible_with},
    target_compatible_with = [],
)
"""

def _host_constraints(ctx):
    name = ctx.os.name.lower()
    if name.startswith("mac os"):
        host_os = "macos"
    elif name.startswith("linux"):
        host_os = "linux"
    elif name.startswith("windows"):
        host_os = "windows"
    else:
        fail("Unsupported host OS for a Flutter toolchain: '{}'.".format(ctx.os.name))

    host_cpu = {
        "aarch64": "arm64",
        "amd64": "x86_64",
        "arm64": "arm64",
        "x86_64": "x86_64",
    }.get(ctx.os.arch.lower())
    if host_cpu == None:
        fail("Unsupported host architecture for a Flutter toolchain: '{}'.".format(ctx.os.arch))
    return [
        "@platforms//os:" + host_os,
        "@platforms//cpu:" + host_cpu,
    ]

def _flutter_toolchains_impl(ctx):
    ctx.file("BUILD.bazel", _TOOLCHAIN_BUILD_TEMPLATE.format(
        toolchain_target = ctx.attr.toolchain_target,
        toolchain_type = ctx.attr.toolchain_type,
        exec_compatible_with = repr(_host_constraints(ctx)),
    ))

_flutter_toolchains_repo = repository_rule(
    implementation = _flutter_toolchains_impl,
    attrs = {
        "toolchain_target": attr.string(mandatory = True),
        "toolchain_type": attr.string(mandatory = True),
    },
)

def _flutter_toolchains_extension_impl(_ctx):
    _flutter_toolchains_repo(
        name = "flutter_toolchains",
        toolchain_target = str(Label("//flutter/private:flutter_toolchain")),
        toolchain_type = str(Label("//flutter/private:flutter_toolchain_type")),
    )

flutter_toolchains = module_extension(
    implementation = _flutter_toolchains_extension_impl,
)
