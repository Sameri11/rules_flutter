"""Public rule for platform-owned Flutter target toolchains."""

FlutterTargetToolchainInfo = provider(
    doc = "Target-platform data used by Flutter compilation rules.",
    fields = {
        "target_os": "Target OS passed to the AOT kernel compiler.",
        "gen_snapshots": "AOT mode to host executable mapping.",
        "snapshot_flags": "Target-specific gen_snapshot flags.",
        "native_assets_key": "Flutter native-assets manifest key.",
        "target_platform": "Flutter bundle target-platform spelling.",
        "slice_id": "Stable identifier for this target slice.",
    },
)


def _flutter_target_toolchain_impl(ctx):
    return [platform_common.ToolchainInfo(flutter_target = FlutterTargetToolchainInfo(
        target_os = ctx.attr.target_os,
        gen_snapshots = {"release": ctx.executable.gen_snapshot_release},
        snapshot_flags = ctx.attr.snapshot_flags,
        native_assets_key = ctx.attr.native_assets_key,
        target_platform = ctx.attr.target_platform,
        slice_id = ctx.attr.slice_id,
    ))]

flutter_target_toolchain = rule(
    implementation = _flutter_target_toolchain_impl,
    attrs = {
        "target_os": attr.string(mandatory = True),
        "gen_snapshot_release": attr.label(
            mandatory = True,
            executable = True,
            cfg = "exec",
            allow_single_file = True,
        ),
        "snapshot_flags": attr.string_list(),
        "native_assets_key": attr.string(mandatory = True),
        "target_platform": attr.string(mandatory = True),
        "slice_id": attr.string(mandatory = True),
    },
)
