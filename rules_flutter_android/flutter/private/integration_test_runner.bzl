"""Dart host runner for Android integration-test APKs."""

load("@rules_flutter_core//flutter:composition.bzl", "FlutterIntegrationTestInfo")

_TOOLCHAIN = "@rules_flutter_core//flutter:toolchain_type"

def _runfile(ctx, file):
    if file.short_path.startswith("../"):
        return file.short_path[len("../"):]
    return ctx.workspace_name + "/" + file.short_path

def _shell_quote(value):
    return "'" + value.replace("'", "'\"'\"'") + "'"

def _runner_impl(ctx):
    apk_files = [
        file
        for file in ctx.attr.apk[DefaultInfo].files.to_list()
        if file.basename.endswith(".apk") and not file.basename.endswith("_unsigned.apk")
    ]
    if len(apk_files) != 1:
        fail("{}: expected one installable APK from {}, got {}".format(ctx.label, ctx.attr.apk.label, apk_files))
    toolchain = ctx.toolchains[_TOOLCHAIN].flutter
    launcher = ctx.actions.declare_file(ctx.label.name + ".sh")
    lines = [
        "#!/bin/bash",
        "set -euo pipefail",
        'ROOT="${TEST_SRCDIR:?TEST_SRCDIR is not set}"',
        'DART="$ROOT/%s"' % _runfile(ctx, toolchain.dart),
        'ADB="$ROOT/%s"' % _runfile(ctx, ctx.executable._adb),
        'APK="$ROOT/%s"' % _runfile(ctx, apk_files[0]),
        'RUN_ID="$(printf %s%s%s "$$" "$RANDOM" "$RANDOM" | cut -c1-24)"',
        'exec "$DART" run "$ROOT/%s" --adb "$ADB" --apk "$APK" --package %s --activity %s --run-id "$RUN_ID"' % (
            _runfile(ctx, ctx.file._kernel),
            _shell_quote(ctx.attr.package),
            _shell_quote(ctx.attr.activity),
        ),
    ]
    ctx.actions.write(launcher, "\n".join(lines) + "\n", is_executable = True)
    files = [launcher, ctx.file._kernel, toolchain.dart, ctx.executable._adb, apk_files[0]]
    runfiles = ctx.runfiles(files = files, transitive_files = toolchain.sdk_packages)
    return [DefaultInfo(executable = launcher, runfiles = runfiles), RunEnvironmentInfo(inherited_environment = ["ANDROID_SERIAL", "ANDROID_ADB_SERVER_PORT"])]

flutter_android_integration_test = rule(
    implementation = _runner_impl,
    test = True,
    attrs = {
        "apk": attr.label(mandatory = True),
        "integration_test": attr.label(mandatory = True, providers = [FlutterIntegrationTestInfo]),
        "package": attr.string(mandatory = True),
        "activity": attr.string(mandatory = True),
        "_kernel": attr.label(default = Label("//flutter/private:integration_test_runner_kernel"), allow_single_file = True),
        "_adb": attr.label(default = Label("@androidsdk//:platform-tools/adb"), allow_single_file = True, executable = True, cfg = "exec"),
    },
    toolchains = [_TOOLCHAIN],
)

def _kernel_impl(ctx):
    toolchain = ctx.toolchains[_TOOLCHAIN].flutter
    decoder_sources = [file for file in ctx.files._decoder_srcs if file.basename == "device_decoder.dart"]
    frame_sources = [file for file in ctx.files._decoder_srcs if file.basename == "frame.dart"]
    logic_source = ctx.file._logic_src
    if len(decoder_sources) != 1 or len(frame_sources) != 1:
        fail("core decoder source target must contain one device_decoder.dart and one frame.dart")
    generated = ctx.actions.declare_file(ctx.label.name + "_main.dart")

    # The core sources live in another repository, so the program imports them
    # by execroot path rather than relative to itself.
    ctx.actions.expand_template(
        template = ctx.file.src,
        output = generated,
        substitutions = {
            "{{DECODER_IMPORT}}": "org-dartlang-root:///" + decoder_sources[0].path,
            "{{FRAME_IMPORT}}": "org-dartlang-root:///" + frame_sources[0].path,
            "{{LOGIC_IMPORT}}": "org-dartlang-root:///" + logic_source.path,
        },
    )
    kernel = ctx.actions.declare_file(ctx.label.name + ".dill")
    command = " ".join([
        toolchain.dartaotruntime.path,
        toolchain.frontend_server.path,
        "--target=vm",
        "--no-print-incremental-dependencies",
        "--platform=" + toolchain.vm_platform_strong.basename,
        "--sdk-root=" + toolchain.vm_platform_strong.dirname + "/",
        "--filesystem-root=.",
        "--filesystem-scheme=org-dartlang-root",
        "--output-dill=" + kernel.path,
        "org-dartlang-root:///" + generated.path,
    ])
    ctx.actions.run_shell(
        outputs = [kernel],
        inputs = depset(
            direct = [generated, logic_source] + ctx.files._decoder_srcs + [toolchain.frontend_server, toolchain.vm_platform_strong],
            transitive = [toolchain.sdk_packages],
        ),
        tools = [toolchain.dartaotruntime],
        command = "set -eu\n" + command + "\n",
        mnemonic = "DartAndroidIntegrationRunner",
        progress_message = "Compiling Dart program %{label}",
    )
    return [DefaultInfo(files = depset([kernel]))]

flutter_android_integration_test_kernel = rule(
    implementation = _kernel_impl,
    attrs = {
        "src": attr.label(mandatory = True, allow_single_file = [".dart"]),
        "_decoder_srcs": attr.label(default = Label("@rules_flutter_core//flutter:device_test_decoder")),
        "_logic_src": attr.label(default = Label("//flutter/private:integration_test_runner_logic.dart"), allow_single_file = True),
    },
    toolchains = [_TOOLCHAIN],
)

def _logic_test_impl(ctx):
    toolchain = ctx.toolchains[_TOOLCHAIN].flutter
    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(
        script,
        "\n".join([
            "#!/bin/bash",
            "set -euo pipefail",
            'ROOT="${TEST_SRCDIR:?TEST_SRCDIR is not set}"',
            'exec "$ROOT/%s" run "$ROOT/%s"' % (_runfile(ctx, toolchain.dart), _runfile(ctx, ctx.file.kernel)),
        ]) + "\n",
        is_executable = True,
    )
    return [DefaultInfo(
        executable = script,
        runfiles = ctx.runfiles(files = [toolchain.dart, ctx.file.kernel], transitive_files = toolchain.sdk_packages),
    )]

flutter_android_integration_test_logic_test = rule(
    implementation = _logic_test_impl,
    test = True,
    attrs = {
        "kernel": attr.label(mandatory = True, allow_single_file = [".dill"]),
    },
    toolchains = [_TOOLCHAIN],
)
