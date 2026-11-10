visibility(["//"])
"""Registers Android target toolchains for the current execution host."""


def _host_constraints(ctx):
    name = ctx.os.name.lower()
    if name.startswith("mac os"):
        host_os = "macos"
    elif name.startswith("linux"):
        host_os = "linux"
    elif name.startswith("windows"):
        host_os = "windows"
    else:
        return None

    host_cpu = {
        "aarch64": "arm64",
        "amd64": "x86_64",
        "arm64": "arm64",
        "riscv64": "riscv64",
        "x86_64": "x86_64",
    }.get(ctx.os.arch.lower())
    if host_cpu == None:
        return None
    return ["@platforms//os:" + host_os, "@platforms//cpu:" + host_cpu]


def _android_toolchains_impl(ctx):
    host = _host_constraints(ctx)
    if host == None:
        ctx.file("BUILD.bazel", "# No Android Flutter target toolchains for this host.\n")
        return

    lines = ['package(default_visibility = ["//visibility:public"])', ""]
    cpu_constraints = {
        "arm64-v8a": "arm64",
        "armeabi-v7a": "armv7",
        "x86_64": "x86_64",
    }
    for abi in sorted(ctx.attr.toolchain_targets.keys()):
        lines.extend([
            "toolchain(",
            '    name = "flutter_android_' + abi.replace("-", "_") + '",',
            '    toolchain = "' + ctx.attr.toolchain_targets[abi] + '",',
            '    toolchain_type = "' + ctx.attr.toolchain_type + '",',
            "    exec_compatible_with = " + repr(host) + ",",
            '    target_compatible_with = ["@platforms//os:android", "@platforms//cpu:' + cpu_constraints[abi] + '"],',
            ")",
            "",
        ])
    ctx.file("BUILD.bazel", "\n".join(lines))


_android_toolchains = repository_rule(
    implementation = _android_toolchains_impl,
    attrs = {
        "toolchain_targets": attr.string_dict(mandatory = True),
        "toolchain_type": attr.string(mandatory = True),
    },
)


def _android_toolchains_extension_impl(_ctx):
    _android_toolchains(
        name = "flutter_android_target_toolchains",
        toolchain_targets = {
            "arm64-v8a": str(Label("//flutter:target_toolchain_arm64_v8a")),
            "armeabi-v7a": str(Label("//flutter:target_toolchain_armeabi_v7a")),
            "x86_64": str(Label("//flutter:target_toolchain_x86_64")),
        },
        toolchain_type = str(Label("@rules_flutter_core//flutter:target_toolchain_type")),
    )


flutter_android_toolchains = module_extension(
    implementation = _android_toolchains_extension_impl,
)
