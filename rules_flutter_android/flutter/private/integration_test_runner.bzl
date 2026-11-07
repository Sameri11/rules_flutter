"""Dart host runner for Android integration-test APKs."""

load("@rules_flutter_core//flutter:defs.bzl", "FlutterIntegrationTestInfo")

_TOOLCHAIN = "@rules_flutter_core//flutter:toolchain_type"


def _runfile(ctx, file):
    if file.short_path.startswith("../"):
        return file.short_path[len("../"):]
    return ctx.workspace_name + "/" + file.short_path


def _shell_quote(value):
    return "'" + value.replace("'", "'\"'\"'") + "'"


def _runner_impl(ctx):
    info = ctx.attr.integration_test[FlutterIntegrationTestInfo]
    apk_files = [
        file
        for file in ctx.attr.apk[DefaultInfo].files.to_list()
        if file.basename.endswith(".apk") and not file.basename.endswith("_unsigned.apk")
    ]
    if len(apk_files) != 1:
        fail("{}: expected one installable APK from {}, got {}".format(ctx.label, ctx.attr.apk.label, apk_files))
    decoder_files = ctx.files._decoder_srcs
    decoder_sources = [file for file in decoder_files if file.basename == "device_decoder.dart"]
    if len(decoder_sources) != 1:
        fail("{}: core decoder source target must contain one device_decoder.dart".format(ctx.label))

    toolchain = ctx.toolchains[_TOOLCHAIN].flutter
    generated = ctx.actions.declare_file(ctx.label.name + "_main.dart")
    decoder_uri = "org-dartlang-root:///" + decoder_sources[0].path
    ctx.actions.expand_template(
        template = ctx.file._runner_src,
        output = generated,
        substitutions = {"{{DECODER_IMPORT}}": decoder_uri},
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
            direct = [generated, toolchain.frontend_server, toolchain.vm_platform_strong] + decoder_files,
            transitive = [toolchain.sdk_packages],
        ),
        tools = [toolchain.dartaotruntime],
        command = "set -eu\n" + command + "\n",
        mnemonic = "DartAndroidIntegrationRunner",
        progress_message = "Compiling integration-test runner %{label}",
    )

    launcher = ctx.actions.declare_file(ctx.label.name + ".sh")
    lines = [
        "#!/bin/bash",
        "set -euo pipefail",
        'ROOT="${TEST_SRCDIR:?TEST_SRCDIR is not set}"',
        'DART="$ROOT/%s"' % _runfile(ctx, toolchain.dart),
        'ADB="$ROOT/%s"' % _runfile(ctx, ctx.executable._adb),
        'APK="$ROOT/%s"' % _runfile(ctx, apk_files[0]),
        'RUN_ID="$(printf %s%s%s "$$" "$RANDOM" "$RANDOM" | cut -c1-24)"',
        'exec "$DART" run "$ROOT/%s" "$ADB" "$APK" %s %s "$RUN_ID"' % (
            _runfile(ctx, kernel),
            _shell_quote(ctx.attr.package),
            _shell_quote(ctx.attr.activity),
        ),
    ]
    ctx.actions.write(launcher, "\n".join(lines) + "\n", is_executable = True)
    files = [launcher, kernel, toolchain.dart, ctx.executable._adb, apk_files[0]] + info.data + decoder_files
    runfiles = ctx.runfiles(files = files, transitive_files = toolchain.sdk_packages)
    return [DefaultInfo(executable = launcher, runfiles = runfiles), RunEnvironmentInfo(environment = info.env)]


flutter_android_integration_test = rule(
    implementation = _runner_impl,
    test = True,
    attrs = {
        "apk": attr.label(mandatory = True),
        "integration_test": attr.label(mandatory = True, providers = [FlutterIntegrationTestInfo]),
        "package": attr.string(mandatory = True),
        "activity": attr.string(mandatory = True),
        "_runner_src": attr.label(default = "//flutter/private:integration_test_runner.dart", allow_single_file = True),
        "_decoder_srcs": attr.label(default = "@rules_flutter_core//flutter/private:device_decoder_library", allow_files = True),
        "_adb": attr.label(default = "@androidsdk//:platform-tools/adb", allow_single_file = True, executable = True, cfg = "exec"),
    },
    toolchains = [_TOOLCHAIN],
)
