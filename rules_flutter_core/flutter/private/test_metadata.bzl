"""Library-level annotations of a test file, parsed at build time by test_core's parseMetadata.

parse_metadata writes a Dart library holding the file's Metadata as JSON, which the test's
bootstrap passes to the driver. A parse error, including an annotation whose arguments are not
literals, fails the build with the file and the source span. The parser is a host build tool;
its packages are not in any test or app kernel.
"""

visibility(["//flutter/...", "//tests/..."])

def _runfile(ctx, file):
    """A file's path under the runfiles root, as the launcher's shell sees it."""
    if file.short_path.startswith("../"):
        return file.short_path[len("../"):]
    return ctx.workspace_name + "/" + file.short_path

def _parse_metadata_impl(ctx):
    toolchain = ctx.toolchains["//flutter/private:flutter_toolchain_type"].flutter
    out = ctx.actions.declare_file(ctx.label.name + ".dart")
    ctx.actions.run(
        executable = toolchain.dart,
        arguments = [
            ctx.file._parser.path,
            ctx.file.src.short_path,
            ctx.file.src.path,
            out.path,
        ],
        inputs = [ctx.file._parser, ctx.file.src],
        tools = [toolchain.dart],
        outputs = [out],
        mnemonic = "TestMetadata",
        progress_message = "Parsing the test annotations of %{label}",
    )
    return [DefaultInfo(files = depset([out]))]

parse_metadata = rule(
    implementation = _parse_metadata_impl,
    doc = "The library-level annotations of one test file, as a Dart library with `testMetadataJson`.",
    attrs = {
        "src": attr.label(
            allow_single_file = [".dart"],
            mandatory = True,
            doc = "The test file.",
        ),
        "_parser": attr.label(
            allow_single_file = True,
            default = "//flutter/private/test_metadata:parser",
        ),
    },
    toolchains = ["//flutter/private:flutter_toolchain_type"],
)

_ERROR_LAUNCHER = """#!/bin/bash
# Generated from flutter/private/test_metadata.bzl.
set -euo pipefail
ROOT="${{TEST_SRCDIR:?TEST_SRCDIR is not set}}"
if "$ROOT/{dart}" "$ROOT/{parser}" "{display}" "$ROOT/{src}" "$TEST_TMPDIR/out.dart" \\
    2> "$TEST_TMPDIR/stderr"; then
  echo "the parser accepted {display}; it must fail" >&2
  exit 1
fi
if ! grep -F -- "{expect}" "$TEST_TMPDIR/stderr" > /dev/null; then
  echo "the parser's error does not contain: {expect}" >&2
  cat "$TEST_TMPDIR/stderr" >&2
  exit 1
fi
"""

def _parse_error_test_impl(ctx):
    toolchain = ctx.toolchains["//flutter/private:flutter_toolchain_type"].flutter
    runner = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.write(
        runner,
        _ERROR_LAUNCHER.format(
            dart = _runfile(ctx, toolchain.dart),
            parser = _runfile(ctx, ctx.file._parser),
            src = _runfile(ctx, ctx.file.src),
            display = ctx.file.src.short_path,
            expect = ctx.attr.expect,
        ),
        is_executable = True,
    )
    return [DefaultInfo(
        executable = runner,
        runfiles = ctx.runfiles(files = [toolchain.dart, ctx.file._parser, ctx.file.src]),
    )]

parse_error_test = rule(
    implementation = _parse_error_test_impl,
    test = True,
    doc = "Passes when the metadata parser rejects `src` and its error contains `expect`.",
    attrs = {
        "src": attr.label(
            allow_single_file = [".dart"],
            mandatory = True,
            doc = "A test file the parser must reject.",
        ),
        "expect": attr.string(
            mandatory = True,
            doc = "A substring of the error, such as the file and the span.",
        ),
        "_parser": attr.label(
            allow_single_file = True,
            default = "//flutter/private/test_metadata:parser",
        ),
    },
    toolchains = ["//flutter/private:flutter_toolchain_type"],
)
