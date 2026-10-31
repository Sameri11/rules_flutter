"""Checks on the test-kernel driver: its bytes per Flutter version and platform dill, its SDK-hash
guard, and the empty output of an unpinned version."""

load("@bazel_skylib//lib:shell.bzl", "shell")
load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

def _runfile(ctx, f):
    return '"$TEST_SRCDIR/{}/{}"'.format(ctx.workspace_name, f.short_path)

_SHA256 = 'if command -v sha256sum >/dev/null 2>&1; then sha256_of() { sha256sum "$1" | cut -d" " -f1; }; else sha256_of() { shasum -a 256 "$1" | cut -d" " -f1; }; fi'

def _golden_test_impl(ctx):
    if len(ctx.files.driver) != 1:
        fail("driver_golden_test: no test-kernel driver for this Flutter version; see flutter/private/test_kernel_driver/pins.bzl")
    tc = ctx.toolchains["//flutter/private:flutter_toolchain_type"].flutter
    drv = ctx.files.driver[0]
    version_file = ctx.file.version_file
    platform = tc.vm_platform_strong

    cases = "\n".join([
        "  {key}) want={sha} ;;".format(key = shell.quote(key), sha = shell.quote(sha))
        for key, sha in sorted(ctx.attr.goldens.items())
    ])
    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(script, "\n".join([
        "set -eu",
        _SHA256,
        "vf=" + _runfile(ctx, version_file),
        "d=" + _runfile(ctx, drv),
        "p=" + _runfile(ctx, platform),
        'v=$(sed -n \'s/.*"frameworkVersion": *"\\([^"]*\\)".*/\\1/p\' "$vf")',
        'plat=$(sha256_of "$p")',
        'got=$(sha256_of "$d")',
        'key="$v $plat"',
        "want=",
        'case "$key" in',
        cases,
        "  *) ;;",
        "esac",
        'if [ -z "$want" ]; then',
        '  echo "driver_golden_test: no golden for Flutter $v with platform dill sha256 $plat." >&2',
        '  echo "driver.dill sha256 is $got. Add this line under \\"$v\\" in GOLDEN in tests/test_kernel_driver/golden.bzl:" >&2',
        '  echo "    \\"$plat\\": \\"$got\\"," >&2',
        "  exit 1",
        "fi",
        'if [ "$got" != "$want" ]; then',
        '  echo "driver_golden_test: driver.dill for Flutter $v on platform dill $plat has sha256 $got; golden is $want." >&2',
        '  echo "If the change is intended, set the entry to \\"$got\\" in tests/test_kernel_driver/golden.bzl." >&2',
        "  exit 1",
        "fi",
        "",
    ]), is_executable = True)
    return [DefaultInfo(
        executable = script,
        runfiles = ctx.runfiles(files = [drv, version_file, platform]),
    )]

driver_golden_test = rule(
    implementation = _golden_test_impl,
    test = True,
    doc = "Passes when driver.dill's sha256 equals the golden for the Flutter version and the toolchain's platform dill.",
    attrs = {
        "driver": attr.label(allow_files = True, mandatory = True),
        "goldens": attr.string_dict(mandatory = True, doc = "\"<flutter version> <platform dill sha256>\" to expected driver sha256."),
        "version_file": attr.label(allow_single_file = True, mandatory = True),
    },
    toolchains = ["//flutter/private:flutter_toolchain_type"],
)

def _rejects_test_impl(ctx):
    tc = ctx.toolchains["//flutter/private:flutter_toolchain_type"].flutter
    drv = ctx.file.driver
    platform = tc.vm_platform_strong
    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(script, "\n".join([
        "set -eu",
        "dart=" + _runfile(ctx, tc.dart),
        "d=" + _runfile(ctx, drv),
        "p=" + _runfile(ctx, platform),
        "tmp=$(mktemp -d)",
        'trap \'rm -rf "$tmp"\' EXIT',
        # The import is the platform dill, which carries the real SDK hash; the driver must
        # refuse before it reads anything.
        'if "$dart" "$d" --sdk-root "${p%/*}/" --import-dill "$p" --output-dill "$tmp/out.dill" ' +
        '--entry-scheme org-dartlang-root --entry-path probe.dart 2>"$tmp/err"; then',
        '  echo "driver_rejects_test: a driver built from a wrong revision was accepted" >&2',
        "  exit 1",
        "fi",
        'grep -q -- \'-Dsdk_hash is\' "$tmp/err" || { cat "$tmp/err" >&2; exit 1; }',
        "",
    ]), is_executable = True)
    return [DefaultInfo(
        executable = script,
        runfiles = ctx.runfiles(files = [drv, tc.dart, platform]),
    )]

driver_rejects_test = rule(
    implementation = _rejects_test_impl,
    test = True,
    doc = "Passes when the driver built with a wrong -Dsdk_hash exits non-zero at its own check.",
    attrs = {
        "driver": attr.label(allow_single_file = [".dill"], mandatory = True),
    },
    toolchains = ["//flutter/private:flutter_toolchain_type"],
)

def _unpinned_impl(ctx):
    # driver_dill with no sources, which an unpinned version yields, must build no file.
    env = analysistest.begin(ctx)
    asserts.equals(env, [], analysistest.target_under_test(env)[DefaultInfo].files.to_list())
    return analysistest.end(env)

unpinned_driver_test = analysistest.make(_unpinned_impl)
