"""ABI-pinned native compilation and stripping, without archive transport."""

load("@rules_cc//cc:find_cc_toolchain.bzl", "find_cpp_toolchain", "use_cc_toolchain")
load("@rules_flutter_core//flutter:abis.bzl", "ABI_PLATFORM_ATTRS")
load(":abis.bzl", "bazel_platform", "check_abis", "check_platform_abi")

# Generated plugin repositories load this implementation directly.
visibility("public")

def _platform_impl(_settings, attr):
    return {"//command_line_option:platforms": [attr.platform]}

_platform = transition(
    implementation = _platform_impl,
    inputs = [],
    outputs = ["//command_line_option:platforms"],
)

def _native_files_impl(ctx):
    abi = check_platform_abi(ctx)
    toolchain = find_cpp_toolchain(ctx)
    outputs = {}
    for target in ctx.attr.src:
        for src in target[DefaultInfo].files.to_list():
            if not src.basename.endswith(".so"):
                continue
            if src.basename in outputs:
                fail("{}: duplicate native library {}".format(ctx.label, src.basename))
            out = ctx.actions.declare_file("{}/lib/{}/{}".format(ctx.label.name, abi, src.basename))
            ctx.actions.run(
                executable = toolchain.strip_executable,
                arguments = ["--strip-unneeded", "-o", out.path, src.path],
                inputs = [src],
                tools = toolchain.all_files,
                outputs = [out],
                mnemonic = "AndroidNativeLibStrip",
                progress_message = "Stripping " + src.basename + " for %{label}",
            )
            outputs[src.basename] = out
    if not outputs:
        fail("{}: sources produced no .so files".format(ctx.label))
    return [DefaultInfo(files = depset(outputs.values()))]

_native_files = rule(
    implementation = _native_files_impl,
    cfg = _platform,
    attrs = dict(
        ABI_PLATFORM_ATTRS,
        src = attr.label_list(mandatory = True),
        abi = attr.string(mandatory = True),
        platform = attr.string(mandatory = True),
    ),
    toolchains = use_cc_toolchain(),
)

def android_native_files(name, src, abi, **kwargs):
    """Builds and strips source libraries with the selected Android ABI's tools."""
    check_abis([abi], "android_native_files " + name)
    _native_files(name = name, src = src, abi = abi, platform = bazel_platform(abi), **kwargs)
