"""The plugin repository's native libraries as Files, one aggregate per ABI.

`flutter_native_libs` packs the same libraries into a jar for the jar carrier.
The split route packages them through CcInfo, which needs each library as its
own File, so the hub emits one `flutter_native_files` per ABI from the same
contributions and keys them with `flutter_native_files_by_abi`.
"""

load(":abis.bzl", "ABIS")
load(":recipe.bzl", "FlutterNativeInfo")

# Generated hub repositories load this file across a repository boundary.
visibility("public")

FlutterNativeFilesByAbiInfo = provider(
    doc = "One plugin repository's native libraries as Files, keyed by the ABIs it declares.",
    fields = {
        "files": "dict[str, depset[File]]: each declared ABI to its libraries.",
    },
)

def _check_abi(where, abi):
    if abi not in ABIS:
        fail("{}: unknown ABI '{}'. Supported: {}.".format(where, abi, sorted(ABIS)))

def _flutter_native_files_impl(ctx):
    _check_abi(ctx.label, ctx.attr.slice)

    libs = []
    for d in ctx.attr.deps:
        info = d[FlutterNativeInfo]
        if info.platform != "android":
            fail("{}: contribution {} targets platform '{}', but this aggregate is android.".format(
                ctx.label,
                d.label,
                info.platform,
            ))

        # Same rule as flutter_native_libs: a contribution that names some
        # slices must name this one, or the split would silently lack it.
        if info.libraries and ctx.attr.slice not in info.libraries:
            fail("{}: contribution {} has no library for slice '{}'; it has {}.".format(
                ctx.label,
                d.label,
                ctx.attr.slice,
                sorted(info.libraries),
            ))
        libs.extend(info.libraries.get(ctx.attr.slice, depset()).to_list())

    # Two packages shipping one soname would overwrite each other in the APK,
    # so the basename decides, as it does in the jar.
    seen = {}
    for f in libs:
        if f.basename in seen:
            fail("{}: two recipes contribute {}: {} and {}".format(
                ctx.label,
                f.basename,
                seen[f.basename].path,
                f.path,
            ))
        seen[f.basename] = f

    return [DefaultInfo(files = depset(libs))]

flutter_native_files = rule(
    implementation = _flutter_native_files_impl,
    doc = """One ABI's recipe native libraries, as Files.

Instantiated in the generated @flutter_plugins repository, not written by hand.
Its contributions are the same deps flutter_native_libs packs into the jar.""",
    attrs = {
        "slice": attr.string(
            mandatory = True,
            doc = "The ABI whose libraries are taken from each contribution.",
        ),
        "deps": attr.label_list(
            providers = [FlutterNativeInfo],
            doc = "flutter_native_contribution targets, one per recipe.",
        ),
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

    # A declared ABI with no aggregate would package nothing for its splits
    # and pass. Refuse it rather than emit an empty entry.
    for abi in ctx.attr.abis:
        if abi not in by_abi:
            fail("{}: ABI '{}' is declared but has no native files aggregate.".format(ctx.label, abi))

    return [FlutterNativeFilesByAbiInfo(
        files = {abi: target[DefaultInfo].files for abi, target in by_abi.items()},
    )]

flutter_native_files_by_abi = rule(
    implementation = _flutter_native_files_by_abi_impl,
    doc = """Every declared ABI's native library aggregate of one plugin repository, keyed by ABI.

Instantiated in the generated @flutter_plugins repository, not written by hand.
Its ABIs are the project's, so the split route takes the ABI list from the
project rather than from a global table.""",
    attrs = {
        "abis": attr.string_list(
            mandatory = True,
            doc = "The ABIs the plugin repository's project declares.",
        ),
        "libs": attr.label_keyed_string_dict(
            doc = "flutter_native_files target to the ABI it aggregates. One per declared ABI.",
        ),
    },
)
