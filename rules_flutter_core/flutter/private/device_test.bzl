# Device flavor rules: the device test macro, Dart programs built from the
# toolchain's dart, the device stream decoder, and the codec test that checks it.
#
# A device kernel is compiled by `dart compile kernel` from declared inputs only:
# the toolchain's dart, its SDK packages and its VM platform dill. Nothing reads
# HOME, the pub cache or the host environment.

visibility(["//flutter/...", "//tests/..."])

load(":flutter_test.bzl", _flutter_test_device = "flutter_test_device")

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
    ctx.actions.run(
        executable = toolchain.dart,
        arguments = ["compile", "kernel", ctx.file.entrypoint.path, "-o", dill.path],
        tools = [toolchain.dart],
        inputs = depset(
            direct = ctx.files.srcs + [ctx.file.entrypoint, toolchain.vm_platform_strong],
            transitive = [toolchain.sdk_packages],
        ),
        outputs = [dill],
        mnemonic = "DartDeviceKernel",
        progress_message = "Compiling device kernel %{label}",
    )
    return [DefaultInfo(files = depset([dill]))]

device_kernel = rule(
    implementation = _device_kernel_impl,
    doc = "A Dart program built from the declared toolchain: `dart compile kernel` of entrypoint.",
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
