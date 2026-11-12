"""A consumer-side app rule that checks the public core artifact contract."""

load("@rules_flutter_core//flutter:composition.bzl", "FlutterArtifactInfo")

def _fake_platform_transition_impl(_settings, _attr):
    return {"//command_line_option:platforms": [Label("//fake_platform:fake_target")]}

_fake_platform_transition = transition(
    implementation = _fake_platform_transition_impl,
    inputs = [],
    outputs = ["//command_line_option:platforms"],
)

def _fake_app_impl(ctx):
    core_targets = ctx.attr.core
    if len(core_targets) != 1:
        fail("{}: expected one transitioned core target, got {}".format(ctx.label, len(core_targets)))
    artifact = core_targets[0][FlutterArtifactInfo]

    if artifact.mode == "release":
        if artifact.aot_kind != "assembly":
            fail("{}: expected the fake platform's assembly AOT artifact, got {}".format(ctx.label, artifact.aot_kind))
        if artifact.aot == None or artifact.aot.basename != "app.S":
            fail("{}: expected the toolchain-declared app.S artifact".format(ctx.label))
        return [DefaultInfo(files = depset([artifact.aot, artifact.assets]))]

    if artifact.mode == "debug":
        if artifact.aot != None:
            fail("{}: expected no AOT file in debug mode, got {}".format(ctx.label, artifact.aot))
        verified = ctx.actions.declare_file(ctx.label.name + ".verified")
        marker_check = 'test -f "$1/FAKE_PLATFORM_MARKER" || { echo "missing fake-platform asset marker" >&2; exit 1; }; ' if ctx.attr.expect_neutral_assets_marker else ""
        ctx.actions.run_shell(
            inputs = [artifact.assets],
            outputs = [verified],
            arguments = [artifact.assets.path, verified.path],
            command = 'test -f "$1/kernel_blob.bin" || { echo "missing debug kernel asset" >&2; exit 1; }; ' + marker_check + 'touch "$2"',
        )
        return [DefaultInfo(files = depset([artifact.assets, verified]))]

    fail("{}: unsupported artifact mode {}".format(ctx.label, artifact.mode))

flutter_fake_app = rule(
    implementation = _fake_app_impl,
    attrs = {
        "core": attr.label(
            mandatory = True,
            providers = [FlutterArtifactInfo],
            cfg = _fake_platform_transition,
        ),
        "expect_neutral_assets_marker": attr.bool(mandatory = True),
    },
)
