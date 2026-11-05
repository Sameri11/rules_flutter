"""Device flavor rules: the device test macro, Dart programs built by the
toolchain's frontend_server, the device stream decoder, and the codec test that checks it.

A device kernel is compiled by the toolchain's frontend_server from declared
inputs only: the frontend runtime and snapshot, the VM platform dill, the SDK
packages and the SDK revision. Paths are repository-relative under
org-dartlang-root, so the bytes depend on neither the checkout nor the sandbox,
and nothing reads HOME, the pub cache or the host environment.
"""

load(":flutter_test.bzl", _flutter_test_device = "flutter_test_device")

visibility(["//flutter/...", "//tests/..."])

_TOOLCHAIN = "//flutter/private:flutter_toolchain_type"

_DRIVER = "//flutter/private/test/driver:"

# The device flavor of flutter_test: its bootstrap calls deviceMain, and the
# kernel is built with the native report turned off.
flutter_test_device = _flutter_test_device

def _runfile(ctx, file):
    """A file's path under the runfiles root, as a test's shell sees it."""
    if file.short_path.startswith("../"):
        return file.short_path[len("../"):]
    return ctx.workspace_name + "/" + file.short_path

def _device_kernel_impl(ctx):
    toolchain = ctx.toolchains[_TOOLCHAIN].flutter
    dill = ctx.actions.declare_file(ctx.label.name + ".dill")

    # The frontend_server compile of test_kernel_driver.bzl. Paths are relative
    # to the execroot under org-dartlang-root, so no sandbox or checkout path
    # reaches the dill, and every tool and SDK file is a declared input.
    command = " ".join([
        "h=$(cut -c1-10 " + toolchain.dart_sdk_revision.path + ");",
        toolchain.dartaotruntime.path,
        toolchain.frontend_server.path,
        "--target=vm",
        "--no-print-incremental-dependencies",
        "--platform=" + toolchain.vm_platform_strong.basename,
        "--sdk-root=" + toolchain.vm_platform_strong.dirname + "/",
        "-Dsdk_hash=$h",
        "--filesystem-root=.",
        "--filesystem-scheme=org-dartlang-root",
        "--output-dill=" + dill.path,
        "org-dartlang-root:///" + ctx.file.entrypoint.path,
    ])
    ctx.actions.run_shell(
        outputs = [dill],
        inputs = depset(
            direct = ctx.files.srcs + [
                ctx.file.entrypoint,
                toolchain.dart_sdk_revision,
                toolchain.frontend_server,
                toolchain.vm_platform_strong,
            ],
            transitive = [toolchain.sdk_packages],
        ),
        tools = [toolchain.dartaotruntime],
        command = "set -eu\n" + command + "\n",
        mnemonic = "DartDeviceKernel",
        progress_message = "Compiling device kernel %{label}",
    )
    return [DefaultInfo(files = depset([dill]))]

device_kernel = rule(
    implementation = _device_kernel_impl,
    doc = "A Dart program compiled by the toolchain's frontend_server, as test kernels are: entrypoint and its srcs, repository-relative.",
    attrs = {
        "entrypoint": attr.label(
            allow_single_file = [".dart"],
            mandatory = True,
            doc = "The program's main library.",
        ),
        "srcs": attr.label_list(
            allow_files = [".dart"],
            doc = "Every Dart file the program imports, by relative import.",
        ),
    },
    toolchains = [_TOOLCHAIN],
)

def device_decoder(name, visibility = None):
    """The device stream decoder, built from the driver's codec files.

    Run as `dart <dill> [--run ID] [--suite NAME] [--xml OUT] [--transport OUT] INPUT`.
    """
    device_kernel(
        name = name,
        entrypoint = _DRIVER + "device_decoder.dart",
        srcs = [
            _DRIVER + "frame.dart",
            _DRIVER + "junit.dart",
            _DRIVER + "results.dart",
        ],
        visibility = visibility,
    )

def _device_codec_test_impl(ctx):
    toolchain = ctx.toolchains[_TOOLCHAIN].flutter
    fixtures = ctx.files.fixtures
    fixtures_dir = _runfile(ctx, fixtures[0]).rsplit("/", 1)[0]
    lines = [
        "#!/bin/bash",
        "set -euo pipefail",
        'ROOT="${TEST_SRCDIR:?TEST_SRCDIR is not set}"',
        'DART="$ROOT/%s"' % _runfile(ctx, toolchain.dart),
        'FIXTURES="$ROOT/%s"' % fixtures_dir,
        '"$DART" run "$ROOT/%s" "$FIXTURES"' % _runfile(ctx, ctx.file.dill),
    ]
    for name, sha in sorted(ctx.attr.transport_sha256.items()):
        lines += [
            'OUT="$TEST_TMPDIR/%s.payload"' % name,
            '"$DART" run "$ROOT/%s" --transport "$OUT" "$FIXTURES/%s"' % (
                _runfile(ctx, ctx.file.decoder),
                name,
            ),
            'GOT=$(shasum -a 256 "$OUT" | cut -d " " -f 1)',
            'if [ "$GOT" != "%s" ]; then echo "transport sha256 of %s is $GOT"; exit 1; fi' % (sha, name),
        ]
    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(script, "\n".join(lines) + "\n", is_executable = True)
    runfiles = ctx.runfiles(
        files = [toolchain.dart, toolchain.vm_platform_strong, ctx.file.dill, ctx.file.decoder] + fixtures,
        transitive_files = toolchain.sdk_packages,
    )
    return [DefaultInfo(executable = script, runfiles = runfiles)]

device_codec_test = rule(
    implementation = _device_codec_test_impl,
    test = True,
    doc = "Runs the codec tests and checks the transport payload digest of each fixture.",
    attrs = {
        "dill": attr.label(
            allow_single_file = [".dill"],
            mandatory = True,
            doc = "The codec tests, a device_kernel.",
        ),
        "decoder": attr.label(
            allow_single_file = [".dill"],
            mandatory = True,
            doc = "The device decoder, from device_decoder.",
        ),
        "fixtures": attr.label_list(
            allow_files = True,
            doc = "Captured streams. The test reads them from their common directory.",
        ),
        "transport_sha256": attr.string_dict(
            doc = "Fixture file name to the sha256 of its reassembled transport payload.",
        ),
    },
    toolchains = [_TOOLCHAIN],
)
