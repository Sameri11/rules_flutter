"""Public descriptor for the second consumer-test platform."""

load("@rules_flutter_core//flutter:defs.bzl", "flutter_platform")

def _fake_files_transition_impl(_settings, _attr):
    return {"//command_line_option:platforms": [Label("//fake_platform:fake_target")]}

_fake_files_transition = transition(
    implementation = _fake_files_transition_impl,
    inputs = [],
    outputs = ["//command_line_option:platforms"],
)

def _fake_neutral_files_impl(ctx):
    (src,) = ctx.files.src
    if src.is_directory:
        out = ctx.actions.declare_directory(ctx.label.name + "/files")
        command = 'cp -RL "$1"/. "$2"/'
        command += ' && touch "$2/FAKE_PLATFORM_MARKER"'
        ctx.actions.run_shell(
            inputs = [src],
            outputs = [out],
            arguments = [src.path, out.path],
            command = command,
        )
    else:
        out = ctx.actions.declare_file(ctx.label.name + "/" + src.basename)
        ctx.actions.run_shell(
            inputs = [src],
            outputs = [out],
            arguments = [src.path, out.path],
            command = 'cp "$1" "$2"',
        )
    return [DefaultInfo(files = depset([out]))]

_fake_neutral_files = rule(
    implementation = _fake_neutral_files_impl,
    attrs = {
        "src": attr.label(mandatory = True, allow_files = True, cfg = _fake_files_transition),
    },
)

FLUTTER_FAKE = flutter_platform(
    name = "fake",
    target_platforms = [Label("//fake_platform:fake_target")],
    constraint = Label("//fake_platform:fake_os_value"),
    neutral_files_rule = _fake_neutral_files,
)
