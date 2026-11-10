"""Public rules for platform-owned Flutter target toolchains."""

FlutterTargetToolchainInfo = provider(
    doc = "Target-platform data used by Flutter compilation rules.",
    fields = {
        "target_os": "Target OS passed to the AOT kernel compiler.",
        "snapshot_flags": "Target-specific gen_snapshot flags.",
        "native_assets_key": "Flutter native-assets manifest key.",
        "target_platform": "Flutter bundle target-platform spelling.",
        "slice_id": "Stable identifier for this target slice.",
    },
)

FlutterAotToolchainInfo = provider(
    doc = "AOT compiler executable for a target platform.",
    fields = {
        "gen_snapshot_release": "Host executable used to produce the release AOT ELF.",
    },
)


def _flutter_target_toolchain_impl(ctx):
    return [platform_common.ToolchainInfo(flutter_target = FlutterTargetToolchainInfo(
        target_os = ctx.attr.target_os,
        snapshot_flags = ctx.attr.snapshot_flags,
        native_assets_key = ctx.attr.native_assets_key,
        target_platform = ctx.attr.target_platform,
        slice_id = ctx.attr.slice_id,
    ))]


def _flutter_aot_toolchain_impl(ctx):
    return [platform_common.ToolchainInfo(flutter_aot = FlutterAotToolchainInfo(
        gen_snapshot_release = ctx.executable.gen_snapshot_release,
    ))]


flutter_target_toolchain = rule(
    implementation = _flutter_target_toolchain_impl,
    attrs = {
        "target_os": attr.string(mandatory = True),
        "snapshot_flags": attr.string_list(),
        "native_assets_key": attr.string(mandatory = True),
        "target_platform": attr.string(mandatory = True),
        "slice_id": attr.string(mandatory = True),
    },
)

flutter_aot_toolchain = rule(
    implementation = _flutter_aot_toolchain_impl,
    attrs = {
        "gen_snapshot_release": attr.label(
            mandatory = True,
            executable = True,
            cfg = "exec",
            allow_single_file = True,
        ),
    },
)
