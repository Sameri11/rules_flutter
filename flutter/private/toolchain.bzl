"""Provider and implementation target for the host Flutter SDK toolchain."""

load(":abis.bzl", "ABIS", "AOT_MODES")

visibility(["//flutter"])

FlutterToolchainInfo = provider(
    doc = "Flutter SDK files used by compiler, AOT, and asset rules.",
    fields = {
        "flutter": "Flutter command launcher file.",
        "dartaotruntime": "Dart AOT runtime executable file.",
        "frontend_server": "Frontend server snapshot file.",
        "sdk_version": "Flutter SDK identity JSON file.",
        "platform_product": "Product patched SDK files.",
        "platform_debug": "Debug patched SDK files.",
        "sdk_packages": "Depset of the SDK's Dart package files: every `packages/<name>` package plus sky_engine, as lib/, pubspec.yaml and license files.",
        "gen_snapshots": "ABI and AOT mode to gen_snapshot executable file mapping.",
    },
)

def _gen_snapshot_attr_name(abi, mode):
    return "_gen_snapshot_{}_{}".format(abi.replace("-", "_"), mode)

def _flutter_toolchain_impl(ctx):
    gen_snapshots = {}
    for abi in sorted(ABIS.keys()):
        for mode in AOT_MODES:
            attr_name = _gen_snapshot_attr_name(abi, mode)
            gen_snapshots["{}_{}".format(abi, mode)] = getattr(ctx.executable, attr_name)
    return [platform_common.ToolchainInfo(flutter = FlutterToolchainInfo(
        flutter = ctx.file._flutter,
        dartaotruntime = ctx.executable._dartaotruntime,
        frontend_server = ctx.file._frontend_server,
        sdk_version = ctx.file._sdk_version,
        platform_product = ctx.files._platform_product,
        platform_debug = ctx.files._platform_debug,
        gen_snapshots = gen_snapshots,
        sdk_packages = depset(ctx.files._sdk_packages),
    ))]

def _toolchain_attrs():
    attrs = {
        "_flutter": attr.label(
            default = "@flutter_sdk//:flutter",
            allow_single_file = True,
        ),
        "_dartaotruntime": attr.label(
            default = "@flutter_sdk//:dartaotruntime",
            executable = True,
            cfg = "exec",
            allow_single_file = True,
        ),
        "_frontend_server": attr.label(
            default = "@flutter_sdk//:frontend_server.snapshot",
            allow_single_file = True,
        ),
        "_sdk_version": attr.label(
            default = "@flutter_sdk//:flutter.version.json",
            allow_single_file = True,
        ),
        "_platform_product": attr.label(
            default = "@flutter_sdk//:platform_product",
            allow_files = True,
        ),
        "_platform_debug": attr.label(
            default = "@flutter_sdk//:platform_debug",
            allow_files = True,
        ),
        "_sdk_packages": attr.label(
            default = "@flutter_sdk//:sdk_packages",
            allow_files = True,
        ),
    }
    for abi in sorted(ABIS.keys()):
        for mode in AOT_MODES:
            attrs[_gen_snapshot_attr_name(abi, mode)] = attr.label(
                default = "@flutter_sdk//:gen_snapshot_{}_{}".format(abi, mode),
                executable = True,
                cfg = "exec",
                allow_single_file = True,
            )
    return attrs

flutter_toolchain = rule(
    implementation = _flutter_toolchain_impl,
    attrs = _toolchain_attrs(),
)
