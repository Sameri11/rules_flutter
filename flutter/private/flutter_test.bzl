"""Host test: one Dart test file, run in-process on flutter_tester.

A flutter_test is three targets:

  <name>_bootstrap  expand_template of bootstrap.dart.tmpl: imports the test,
                    its flutter_test_config.dart (if any) and the driver.
  <name>_kernel     dart_test_kernel over the bootstrap, the test sources, the
                    driver and the package. Always debug: tests never read
                    //flutter:mode.
  <name>            the launcher test, which runs the toolchain's flutter_tester
                    on the kernel.

The launcher is a test so that Bazel sets TEST_SRCDIR, TEST_TMPDIR and the
filter/shard variables for it.
"""

load(":rules.bzl", "FlutterPackageInfo", "dart_test_kernel")

visibility(["//flutter"])

_DRIVER_SRCS = [
    Label("//flutter/private/test/driver:core.dart"),
    Label("//flutter/private/test/driver:host.dart"),
]

_CONFIG_NAME = "flutter_test_config.dart"

def _parent(path):
    """The directory of a short path. `""` is the repository root."""
    return path.rpartition("/")[0]

def _join(dir, name):
    return dir + "/" + name if dir else name

def _execroot_path(file):
    """A file's path from the execroot, which is also its path under org-dartlang-root."""
    if file.short_path.startswith("../"):
        return "external/" + file.short_path[len("../"):]
    return file.short_path

def _runfile(ctx, file):
    """A file's path under the runfiles root, as the launcher's shell sees it."""
    if file.short_path.startswith("../"):
        return file.short_path[len("../"):]
    return ctx.workspace_name + "/" + file.short_path

def _find_config(test_path, pkg_dir, known):
    """The nearest flutter_test_config.dart from the test's dir up to the pubspec dir.

    Mirrors flutter_tools' test_config.dart:16-40. Only declared srcs count.
    """
    if not test_path.startswith(pkg_dir + "/") and pkg_dir:
        fail("{} is outside the pubspec directory {}".format(test_path, pkg_dir))
    dir = _parent(test_path)
    for _ in range(test_path.count("/") + 1):
        candidate = _join(dir, _CONFIG_NAME)
        if candidate in known:
            return candidate
        if dir == pkg_dir:
            break
        dir = _parent(dir)
    return None

def _flutter_test_bootstrap_impl(ctx):
    test = ctx.file.src
    pubspec = ctx.attr.app[FlutterPackageInfo].pubspec.src
    pkg_dir = _parent(pubspec.short_path)
    known = {f.short_path: f for f in ctx.files.srcs}
    config = _find_config(test.short_path, pkg_dir, known)

    # Imports are org-dartlang-root URIs of execroot paths, so the same
    # bootstrap compiles whichever repository the test is in.
    def uri(file):
        return "org-dartlang-root:///" + _execroot_path(file)

    if config:
        config_import = "import '{}' as testConfig;".format(uri(known[config]))

        # Future(test.main) awaits main's whole body, so tests declared after an
        # await are declared before the listener builds the suite (flutter_tools
        # flutter_platform.dart does the same).
        test_main = "await testConfig.testExecutable(() => Future(test.main));"
    else:
        config_import = ""
        test_main = "await Future(test.main);"

    out = ctx.actions.declare_file(ctx.label.name + ".dart")
    ctx.actions.expand_template(
        template = ctx.file._template,
        output = out,
        substitutions = {
            "{{CONFIG_IMPORT}}": config_import,
            "{{DRIVER_URI}}": uri(ctx.file._driver),
            "{{PACKAGE_ROOT}}": _parent(_execroot_path(pubspec)),
            "{{TEST_FILE}}": _runfile(ctx, test),
            "{{TEST_MAIN}}": test_main,
            "{{TEST_URI}}": uri(test),
        },
    )
    return [DefaultInfo(files = depset([out]))]

_flutter_test_bootstrap = rule(
    implementation = _flutter_test_bootstrap_impl,
    doc = "Generates the bootstrap that a flutter_test compiles as its entrypoint.",
    attrs = {
        "src": attr.label(
            allow_single_file = [".dart"],
            mandatory = True,
            doc = "The test file.",
        ),
        "srcs": attr.label_list(
            allow_files = [".dart"],
            doc = "The test's sources. Searched for flutter_test_config.dart.",
        ),
        "app": attr.label(
            mandatory = True,
            providers = [FlutterPackageInfo],
            doc = "The flutter_package the test belongs to.",
        ),
        "_template": attr.label(
            allow_single_file = True,
            default = "//flutter/private/test/driver:bootstrap.dart.tmpl",
        ),
        "_driver": attr.label(
            allow_single_file = True,
            default = "//flutter/private/test/driver:host.dart",
        ),
    },
)

def _tester_test_impl(ctx):
    toolchain = ctx.toolchains["//flutter/private:flutter_toolchain_type"].flutter
    package = ctx.attr.app[FlutterPackageInfo]
    pubspec = package.pubspec
    pkg_dir = _parent(_runfile(ctx, pubspec.src))

    assets_flag = ""
    assets_export = ""
    assets_files = []
    if package.assets:
        assets_files = [package.assets]
        assets_path = _runfile(ctx, package.assets)
        assets_export = 'export UNIT_TEST_ASSETS="$ROOT/{}"'.format(assets_path)
        assets_flag = '--flutter-assets-dir="$ROOT/{}"'.format(assets_path)

    runner = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.write(
        runner,
        """#!/bin/bash
# Host test launcher generated from flutter/private/flutter_test.bzl.
set -euo pipefail
ROOT="${{TEST_SRCDIR:-${{RUNFILES_DIR:-}}}}"
if [[ -z "$ROOT" ]]; then
  echo "neither TEST_SRCDIR nor RUNFILES_DIR is set" >&2
  exit 1
fi
export FLUTTER_TEST=true
export APP_NAME="$(cat "$ROOT/{package_name}")"
{assets_export}
# The package root is the working directory, as for `flutter test`. --packages
# is omitted: pub's package_config rootUris are execroot-relative and do not
# resolve in runfiles. The kernel already holds every imported library.
cd "$ROOT/{pkg_dir}"
exec "$ROOT/{tester}" --disable-vm-service --non-interactive --enable-checked-mode \\
  --verify-entry-points --enable-software-rendering --skia-deterministic-rendering \\
  --use-test-fonts --disable-asset-fonts --icu-data-file-path="$ROOT/{icu}" \\
  {assets_flag} "$ROOT/{dill}"
""".format(
            assets_export = assets_export,
            assets_flag = assets_flag,
            dill = _runfile(ctx, ctx.file.dill),
            icu = _runfile(ctx, toolchain.icu_data),
            package_name = _runfile(ctx, pubspec.package_name),
            pkg_dir = pkg_dir,
            tester = _runfile(ctx, toolchain.flutter_tester),
        ),
        is_executable = True,
    )

    runfiles = ctx.runfiles(
        files = [
            ctx.file.dill,
            pubspec.package_name,
            pubspec.src,
            toolchain.flutter_tester,
            toolchain.icu_data,
        ] + assets_files + ctx.files.srcs + ctx.files.data,
    )
    return [DefaultInfo(executable = runner, runfiles = runfiles)]

_tester_test = rule(
    implementation = _tester_test_impl,
    test = True,
    doc = "Runs a flutter_test kernel on the toolchain's flutter_tester.",
    attrs = {
        "dill": attr.label(
            allow_single_file = [".dill"],
            mandatory = True,
            doc = "The debug kernel from dart_test_kernel.",
        ),
        "app": attr.label(
            mandatory = True,
            providers = [FlutterPackageInfo],
            doc = "The flutter_package the test belongs to: the package name, the working directory and the assets.",
        ),
        "srcs": attr.label_list(
            allow_files = True,
            doc = "Test sources, in runfiles for golden files and the like.",
        ),
        "data": attr.label_list(
            allow_files = True,
            doc = "Runtime data the test reads.",
        ),
    },
    toolchains = ["//flutter/private:flutter_toolchain_type"],
)

def flutter_test(name, app, src, srcs = [], data = [], dart_defines = {}, **kwargs):
    """Runs one Dart test file in-process on flutter_tester.

    The package's inputs come from `app`, a flutter_package target: its pubspec,
    libraries, dependencies and assets. The test's own inputs are `src` and `srcs`.
    Plugins' host-platform Dart implementations are not registered.

        flutter_test(
            name = "widget_test",
            app = ":app",
            src = "test/widget_test.dart",
        )

    Args:
      name: the launcher's name. Also prefixes the bootstrap and kernel targets.
      app: the flutter_package target of the package the test belongs to.
      src: the test file, relative to the package.
      srcs: the test's other sources, including any flutter_test_config.dart.
        A test importing a file not listed here fails to compile.
      data: runtime files the test reads.
      dart_defines: `-D` constants this test compiles with. Not the app's.
      **kwargs: forwarded to the launcher test rule.
    """
    tags = kwargs.pop("tags", [])
    bootstrap = name + "_bootstrap"
    _flutter_test_bootstrap(
        name = bootstrap,
        app = app,
        src = src,
        srcs = srcs,
        tags = ["manual"],
    )
    all_srcs = srcs if src in srcs else [src] + srcs
    dart_test_kernel(
        name = name + "_kernel",
        app = app,
        srcs = all_srcs + _DRIVER_SRCS,
        entrypoint = ":" + bootstrap,
        dart_defines = dart_defines,
        tags = ["manual"],
    )
    _tester_test(
        name = name,
        dill = ":" + name + "_kernel",
        app = app,
        srcs = srcs,
        data = data,
        tags = tags,
        **kwargs
    )
