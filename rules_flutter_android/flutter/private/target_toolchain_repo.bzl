"""Registers Android target toolchains for the current execution host."""

load("//flutter:abis.bzl", "ABIS")
load(":gen_snapshot_repo.bzl", "flutter_gen_snapshot")

visibility(["//"])

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
    cpu_constraints = ctx.attr.cpu_constraints

    for abi in sorted(ctx.attr.toolchain_targets.keys()):
        lines.extend([
            "toolchain(",
            '    name = "flutter_android_' + abi.replace("-", "_") + '",',
            '    toolchain = "' + ctx.attr.toolchain_targets[abi] + '",',
            '    toolchain_type = "' + ctx.attr.toolchain_type + '",',
            "    exec_compatible_with = " + repr(host) + ",",
            '    target_compatible_with = ["@platforms//os:android", "' + cpu_constraints[abi] + '"],',
            ")",
            "",
        ])

    for abi in sorted(ctx.attr.aot_toolchain_targets.keys()):
        lines.extend([
            "toolchain(",
            '    name = "flutter_android_aot_' + abi.replace("-", "_") + '",',
            '    toolchain = "' + ctx.attr.aot_toolchain_targets[abi] + '",',
            '    toolchain_type = "' + ctx.attr.aot_toolchain_type + '",',
            "    exec_compatible_with = " + repr(host) + ",",
            '    target_compatible_with = ["@platforms//os:android", "' + cpu_constraints[abi] + '"],',
            ")",
            "",
        ])
    ctx.file("BUILD.bazel", "\n".join(lines))

_android_toolchains = repository_rule(
    implementation = _android_toolchains_impl,
    attrs = {
        "aot_toolchain_targets": attr.string_dict(mandatory = True),
        "aot_toolchain_type": attr.string(mandatory = True),
        "cpu_constraints": attr.string_dict(mandatory = True),
        "toolchain_targets": attr.string_dict(mandatory = True),
        "toolchain_type": attr.string(mandatory = True),
    },
)

def _android_toolchains_extension_impl(_ctx):
    toolchain_targets = {}
    aot_toolchain_targets = {}
    cpu_constraints = {}
    for abi, info in ABIS.items():
        suffix = abi.replace("-", "_")
        flutter_gen_snapshot(
            name = "flutter_gen_snapshot_" + suffix,
            engine_dir = info.engine_dir["release"],
        )
        toolchain_targets[abi] = str(Label("//flutter:target_toolchain_" + suffix))
        aot_toolchain_targets[abi] = str(Label("@flutter_gen_snapshot_" + suffix + "//:aot_toolchain"))

        cpu_constraints[abi] = str(info.cpu_constraint)
    _android_toolchains(
        name = "flutter_android_target_toolchains",
        aot_toolchain_targets = aot_toolchain_targets,
        aot_toolchain_type = str(Label("@rules_flutter_core//flutter:aot_toolchain_type")),
        cpu_constraints = cpu_constraints,
        toolchain_targets = toolchain_targets,
        toolchain_type = str(Label("@rules_flutter_core//flutter:target_toolchain_type")),
    )

flutter_android_toolchains = module_extension(
    implementation = _android_toolchains_extension_impl,
)
