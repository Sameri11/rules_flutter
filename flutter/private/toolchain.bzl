"""Provider and implementation target for the host Flutter SDK toolchain."""

FlutterToolchainInfo = provider(
    doc = "Flutter SDK files used by compiler, AOT, and asset rules.",
    fields = {
        "flutter": "Flutter command launcher file.",
        "dartaotruntime": "Dart AOT runtime executable file.",
        "frontend_server": "Frontend server snapshot file.",
        "sdk_version": "Flutter SDK identity JSON file.",
        "platform_product": "Product patched SDK files.",
        "platform_debug": "Debug patched SDK files.",
        "gen_snapshots": "ABI to Android gen_snapshot executable file mapping.",
    },
)

def _flutter_toolchain_impl(ctx):
    gen_snapshots = {
        "arm64-v8a": ctx.executable._gen_snapshot_arm64_v8a,
        "armeabi-v7a": ctx.executable._gen_snapshot_armeabi_v7a,
        "x86_64": ctx.executable._gen_snapshot_x86_64,
    }
    return [platform_common.ToolchainInfo(flutter = FlutterToolchainInfo(
        flutter = ctx.file._flutter,
        dartaotruntime = ctx.executable._dartaotruntime,
        frontend_server = ctx.file._frontend_server,
        sdk_version = ctx.file._sdk_version,
        platform_product = ctx.files._platform_product,
        platform_debug = ctx.files._platform_debug,
        gen_snapshots = gen_snapshots,
    ))]

flutter_toolchain = rule(
    implementation = _flutter_toolchain_impl,
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
        "_gen_snapshot_arm64_v8a": attr.label(
            default = "@flutter_sdk//:gen_snapshot_arm64-v8a_release",
            executable = True,
            cfg = "exec",
            allow_single_file = True,
        ),
        "_gen_snapshot_armeabi_v7a": attr.label(
            default = "@flutter_sdk//:gen_snapshot_armeabi-v7a_release",
            executable = True,
            cfg = "exec",
            allow_single_file = True,
        ),
        "_gen_snapshot_x86_64": attr.label(
            default = "@flutter_sdk//:gen_snapshot_x86_64_release",
            executable = True,
            cfg = "exec",
            allow_single_file = True,
        ),
    },
)
