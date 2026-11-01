"""Plugin native libraries as raw Files, one aggregate per Android ABI."""

load("@rules_flutter_core//flutter:abis.bzl", "ABIS")
load(":recipe.bzl", "FlutterNativeInfo")

visibility("public")

FlutterNativeFilesByAbiInfo = provider(
    doc = "One plugin repository's native libraries as Files, keyed by declared ABI.",
    fields = {"files": "dict[str, depset[File]]: each declared ABI to its libraries."},
)

def _check_abi(where, abi):
    if abi not in ABIS:
        fail("{}: unknown ABI '{}'. Supported: {}.".format(where, abi, sorted(ABIS)))

def _flutter_native_files_impl(ctx):
    abi = ctx.attr.slice
    _check_abi(ctx.label, abi)

    libs = []
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
        libs.extend(info.libraries.get(abi, depset()).to_list())

    for target in ctx.attr.generated:
        libs.extend(target[DefaultInfo].files.to_list())

    seen = {}
    for f in libs:
        if f.basename in seen:
            fail("{}: two contributions provide {}: {} and {}".format(
                ctx.label,
                f.basename,
                seen[f.basename].path,
                f.path,
            ))
        seen[f.basename] = f

    return [DefaultInfo(files = depset(libs))]

flutter_native_files = rule(
    implementation = _flutter_native_files_impl,
    doc = "One ABI's recipe and generated native libraries, as raw Files.",
    attrs = {
        "slice": attr.string(mandatory = True),
        "deps": attr.label_list(providers = [FlutterNativeInfo]),
        "generated": attr.label_list(allow_files = True),
    },
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
