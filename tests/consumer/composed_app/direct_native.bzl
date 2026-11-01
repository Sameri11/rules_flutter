"""Consumer-owned handling of direct core native output groups."""

load("@rules_cc//cc:find_cc_toolchain.bzl", "find_cpp_toolchain", "use_cc_toolchain")

def _direct_native_impl(ctx):
    engines = ctx.files.engine
    if not engines:
        missing = ctx.actions.declare_file(ctx.label.name + "/libunconfigured.so")
        ctx.actions.run_shell(
            outputs = [missing],
            command = "echo 'direct core packaging needs an Android ABI; set --android_platforms' >&2; exit 1",
            mnemonic = "DirectCoreNoAbi",
        )
        return [DefaultInfo(files = depset([missing]))]

    toolchain = find_cpp_toolchain(ctx)
    libraries = list(ctx.files.libapp)
    for src in engines:
        out = ctx.actions.declare_file(ctx.label.name + "/" + src.basename)
        ctx.actions.run(
            executable = toolchain.strip_executable,
            arguments = ["--strip-unneeded", "-o", out.path, src.path],
            inputs = [src],
            tools = toolchain.all_files,
            outputs = [out],
            mnemonic = "DirectCoreEngineStrip",
        )
        libraries.append(out)
    if not libraries:
        fail("{}: the selected core has no engine or release AOT libraries".format(ctx.label))
    return [DefaultInfo(files = depset(libraries))]

direct_native = rule(
    implementation = _direct_native_impl,
    attrs = {
        "engine": attr.label(mandatory = True, allow_files = True),
        "libapp": attr.label(mandatory = True, allow_files = True),
    },
    fragments = ["cpp"],
    toolchains = use_cc_toolchain(),
)
