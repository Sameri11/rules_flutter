"""Plugin native libraries as raw Files, one aggregate per Android ABI."""

load("@rules_cc//cc:find_cc_toolchain.bzl", "find_cpp_toolchain", "use_cc_toolchain")
load("@rules_flutter_core//flutter:abis.bzl", "ABIS", "ABI_PLATFORM_ATTRS")
load(":abis.bzl", "bazel_platform", "check_platform_abi")
load(":native_strip.bzl", "strip_native_file")
load(":recipe.bzl", "FlutterNativeInfo")

visibility("public")

FlutterNativeFilesByAbiInfo = provider(
    doc = "One plugin repository's native libraries as Files, keyed by declared ABI.",
    fields = {"files": "dict[str, depset[File]]: each declared ABI to its libraries."},
)

def _check_abi(where, abi):
    if abi not in ABIS:
        fail("{}: unknown ABI '{}'. Supported: {}.".format(where, abi, sorted(ABIS)))

def _platform_impl(_settings, attr):
    return {"//command_line_option:platforms": [attr.platform]}

_platform = transition(
    implementation = _platform_impl,
    inputs = [],
    outputs = ["//command_line_option:platforms"],
)

def _flutter_native_files_impl(ctx):
    abi = check_platform_abi(ctx)
    _check_abi(ctx.label, abi)
    toolchain = find_cpp_toolchain(ctx)
    libs = []
    seen = {}

    for dep in ctx.attr.deps:
        info = dep[FlutterNativeInfo]
        if info.platform != "android":
            fail("{}: contribution {} targets platform '{}', but this aggregate is android.".format(
                ctx.label,
                dep.label,
                info.platform,
            ))
        if info.libraries and abi not in info.libraries:
            fail("{}: contribution {} has no library for ABI '{}'; it has {}.".format(
                ctx.label,
                dep.label,
                abi,
                sorted(info.libraries),
            ))
        for src in info.libraries.get(abi, depset()).to_list():
            if src.basename in seen:
                fail("{}: two contributions provide {}: {} and {}".format(
                    ctx.label,
                    src.basename,
                    seen[src.basename],
                    src.path,
                ))
            seen[src.basename] = src.path
            libs.append(strip_native_file(ctx, src, abi, toolchain))

    for target in ctx.attr.generated:
        for src in target[DefaultInfo].files.to_list():
            if src.basename in seen:
                fail("{}: two contributions provide {}: {} and {}".format(
                    ctx.label,
                    src.basename,
                    seen[src.basename],
                    src.path,
                ))
            seen[src.basename] = src.path
            libs.append(src)

    return [DefaultInfo(files = depset(libs))]

flutter_native_files = rule(
    implementation = _flutter_native_files_impl,
    cfg = _platform,
    doc = "One ABI's stripped recipe and generated native libraries as Files.",
    attrs = dict(
        ABI_PLATFORM_ATTRS,
        abi = attr.string(mandatory = True),
        platform = attr.string(mandatory = True),
        deps = attr.label_list(providers = [FlutterNativeInfo]),
        generated = attr.label_list(allow_files = True),
    ),
    fragments = ["cpp"],
    toolchains = use_cc_toolchain(),
)

def _flutter_native_files_by_abi_impl(ctx):
    for abi in ctx.attr.abis:
        _check_abi(ctx.label, abi)

    by_abi = {}
    for target, abi in ctx.attr.libs.items():
        if abi not in ctx.attr.abis:
            fail("{}: {} is for ABI '{}', which the project does not declare; its abis are {}.".format(
                ctx.label,
                target.label,
                abi,
                ctx.attr.abis,
            ))
        if abi in by_abi:
            fail("{}: two aggregates are for ABI '{}': {} and {}.".format(
                ctx.label,
                abi,
                by_abi[abi].label,
                target.label,
            ))
        by_abi[abi] = target

    for abi in ctx.attr.abis:
        if abi not in by_abi:
            fail("{}: ABI '{}' is declared but has no native files aggregate.".format(ctx.label, abi))

    return [FlutterNativeFilesByAbiInfo(
        files = {abi: target[DefaultInfo].files for abi, target in by_abi.items()},
    )]

flutter_native_files_by_abi = rule(
    implementation = _flutter_native_files_by_abi_impl,
    doc = "Every declared ABI's native library aggregate of one plugin repository, keyed by ABI.",
    attrs = {
        "abis": attr.string_list(mandatory = True),
        "libs": attr.label_keyed_string_dict(),
    },
)
