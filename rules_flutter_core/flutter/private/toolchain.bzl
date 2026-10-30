"""Provider and implementation target for the host Flutter SDK toolchain."""

load("//flutter:abis.bzl", "ABIS", "AOT_MODES")

visibility(["//flutter"])

FlutterToolchainInfo = provider(
    doc = "Flutter SDK files used by compiler, AOT, and asset rules.",
    fields = {
        "flutter": "Flutter command launcher file.",
        "tools_snapshot": "flutter_tools snapshot file that the assets action executes.",
        "dartaotruntime": "Dart AOT runtime executable file.",
        "frontend_server": "Frontend server snapshot file.",
        "vm_isolate_snapshot": "Host engine's debug VM isolate snapshot file, shipped as the debug overlay's vm_snapshot_data.",
        "isolate_snapshot": "Host engine's debug isolate snapshot file, shipped as the debug overlay's isolate_snapshot_data.",
        "flutter_tester": "Flutter tester host executable, the test runtime that runs compiled kernel.",
        "icu_data": "ICU data file that flutter_tester loads.",
        "sdk_version": "Flutter SDK identity JSON file.",
        "platform_product": "Product patched SDK files.",
        "platform_debug": "Debug patched SDK files.",
        "sdk_packages": "Depset of the SDK's Dart package files: every `packages/<name>` package plus sky_engine, as lib/, pubspec.yaml and license files.",
        "gen_snapshots": "ABI and AOT mode to gen_snapshot executable file mapping.",
        "dart": "Dart SDK executable file, used to run the test-kernel driver.",
        "vm_platform_strong": "VM platform dill the test-kernel driver is compiled against.",
        "dart_sdk_revision": "Dart SDK revision file; the driver's sdk_hash comes from it.",
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
        tools_snapshot = ctx.file._tools_snapshot,
        dartaotruntime = ctx.executable._dartaotruntime,
        dart = ctx.executable._dart,
        vm_platform_strong = ctx.file._vm_platform_strong,
        dart_sdk_revision = ctx.file._dart_sdk_revision,
        frontend_server = ctx.file._frontend_server,
        vm_isolate_snapshot = ctx.file._vm_isolate_snapshot,
        isolate_snapshot = ctx.file._isolate_snapshot,
        flutter_tester = ctx.executable._flutter_tester,
        icu_data = ctx.file._icu_data,
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
        "_tools_snapshot": attr.label(
            default = "@flutter_sdk//:flutter_tools.snapshot",
            allow_single_file = True,
        ),
        "_dartaotruntime": attr.label(
            default = "@flutter_sdk//:dartaotruntime",
            executable = True,
            cfg = "exec",
            allow_single_file = True,
        ),
        "_dart": attr.label(
            default = "@flutter_sdk//:dart",
            executable = True,
            cfg = "exec",
            allow_single_file = True,
        ),
        "_vm_platform_strong": attr.label(
            default = "@flutter_sdk//:vm_platform_strong.dill",
            allow_single_file = True,
        ),
        "_dart_sdk_revision": attr.label(
            default = "@flutter_sdk//:dart_sdk_revision",
            allow_single_file = True,
        ),
        "_frontend_server": attr.label(
            default = "@flutter_sdk//:frontend_server.snapshot",
            allow_single_file = True,
        ),
        "_vm_isolate_snapshot": attr.label(
            default = "@flutter_sdk//:vm_isolate_snapshot.bin",
            allow_single_file = True,
        ),
        "_isolate_snapshot": attr.label(
            default = "@flutter_sdk//:isolate_snapshot.bin",
            allow_single_file = True,
        ),
        "_flutter_tester": attr.label(
            default = "@flutter_sdk//:flutter_tester",
            executable = True,
            cfg = "exec",
            allow_single_file = True,
        ),
        "_icu_data": attr.label(
            default = "@flutter_sdk//:icudtl.dat",
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
