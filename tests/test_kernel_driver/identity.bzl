"""Output identity: the test-kernel driver's one-shot output equals frontend_server's.

The rule builds a seed kernel, then compiles one test against it twice with the same argv:
once with frontend_server, joining its per-package pieces, and once with the driver. The test
passes when the two outputs are byte-identical.
"""

load("@bazel_skylib//lib:shell.bzl", "shell")

# frontend_server flags of a debug (JIT) test kernel; the same set as rules.bzl.
_DEBUG_FLAGS = [
    "-Ddart.vm.profile=false",
    "-Ddart.vm.product=false",
    "--enable-asserts",
    "--track-widget-creation",
    "--no-link-platform",
]

def _sdk_root(platform_files):
    for f in platform_files:
        if f.basename == "platform_strong.dill":
            return f.dirname
    fail("test_kernel_identity: the toolchain has no platform_strong.dill")

def _quote(args):
    return " ".join([shell.quote(a) for a in args])

def _identity_test_impl(ctx):
    tc = ctx.toolchains["//flutter/private:flutter_toolchain_type"].flutter
    if len(ctx.files.driver) != 1:
        fail("test_kernel_identity: no test-kernel driver for this Flutter version; see flutter/private/test_kernel_driver/pins.bzl")
    driver = ctx.files.driver[0]

    sdk_root = _sdk_root(tc.platform_debug)
    pc = ctx.file.package_config.path
    entry = "org-dartlang-root:///" + ctx.file.entry.path
    defines = ["-D{}={}".format(k, ctx.attr.dart_defines[k]) for k in sorted(ctx.attr.dart_defines)]

    # The argv both tools get. Only the executable and the output path differ.
    shared = [
        "--sdk-root",
        sdk_root + "/",
        "--target",
        "flutter",
        "--no-print-incremental-dependencies",
    ] + _DEBUG_FLAGS + defines + [
        "--filesystem-root",
        ".",
        "--filesystem-scheme",
        "org-dartlang-root",
        "--packages",
        "org-dartlang-root:///" + pc,
    ]
    inputs = depset(
        direct = ctx.files.srcs + [ctx.file.package_config, ctx.file.entry],
        transitive = [depset(tc.platform_debug)],
    )

    seed = ctx.actions.declare_file(ctx.label.name + ".seed.dill")
    ctx.actions.run_shell(
        outputs = [seed],
        inputs = depset([tc.frontend_server], transitive = [inputs]),
        tools = [tc.dartaotruntime],
        command = "set -eu\n" + _quote([
            tc.dartaotruntime.path,
            tc.frontend_server.path,
        ] + shared + [
            "--output-dill",
            seed.path,
            "package:kernel_fixture/seed.dart",
        ]) + "\n",
        mnemonic = "TestKernelIdentitySeed",
    )

    shared_with_seed = shared + ["--import-dill", seed.path, "--split-output-by-packages", "--no-embed-source-text"]

    ref = ctx.actions.declare_file(ctx.label.name + ".frontend.dill")
    ctx.actions.run_shell(
        outputs = [ref],
        inputs = depset([seed, tc.frontend_server], transitive = [inputs]),
        tools = [tc.dartaotruntime],
        command = "\n".join([
            "set -eu",
            "work=" + shell.quote(ref.path + ".work"),
            'mkdir -p "$work"',
            _quote([tc.dartaotruntime.path, tc.frontend_server.path] + shared_with_seed) +
            ' --output-dill "$work/kernel.dill" ' + shell.quote(entry),
            # frontend_server writes one piece per package. The driver's output is these pieces
            # joined, main first; the reference joins them the same way.
            'cat "$work/kernel.dill-main.dilp" > ' + shell.quote(ref.path),
            'while read -r p; do [ -z "$p" ] || [ "$p" = main ] || cat "$work/kernel.dill-$p.dilp" >> ' +
            shell.quote(ref.path) + ' ; done < "$work/kernel.dill-packages"',
        ]) + "\n",
        mnemonic = "TestKernelIdentityFrontend",
    )

    drv = ctx.actions.declare_file(ctx.label.name + ".driver.dill")
    ctx.actions.run_shell(
        outputs = [drv],
        inputs = depset([seed, driver], transitive = [inputs]),
        tools = [tc.dart],
        command = "set -eu\n" + _quote([tc.dart.path, driver.path] + shared_with_seed) +
                  " --output-dill " + shell.quote(drv.path) + " " + shell.quote(entry) + "\n",
        mnemonic = "TestKernelIdentityDriver",
    )

    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(script, "\n".join([
        "set -eu",
        'r="$TEST_SRCDIR/{ws}/{ref}"'.format(ws = ctx.workspace_name, ref = ref.short_path),
        'd="$TEST_SRCDIR/{ws}/{drv}"'.format(ws = ctx.workspace_name, drv = drv.short_path),
        'test -s "$r"',
        'cmp "$r" "$d"',
        "",
    ]), is_executable = True)
    return [DefaultInfo(
        executable = script,
        runfiles = ctx.runfiles(files = [ref, drv]),
    )]

test_kernel_identity_test = rule(
    implementation = _identity_test_impl,
    test = True,
    doc = "Passes when the driver's one-shot test kernel is byte-identical to frontend_server's.",
    attrs = {
        "entry": attr.label(allow_single_file = [".dart"], mandatory = True, doc = "The test's entrypoint."),
        "srcs": attr.label_list(allow_files = True, doc = "Every source the seed and the test read."),
        "package_config": attr.label(allow_single_file = [".json"], mandatory = True),
        "dart_defines": attr.string_dict(doc = "-D constants for both compiles."),
        "driver": attr.label(
            allow_files = True,
            default = "//flutter/private/test_kernel_driver:driver",
            doc = "The driver.dill; unset when the Flutter version has no pin.",
        ),
    },
    toolchains = ["//flutter/private:flutter_toolchain_type"],
)
