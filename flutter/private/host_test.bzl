"""Host test: one Dart test file, run in-process on flutter_tester.

A host test is three targets:

  <name>_bootstrap  expand_template of bootstrap.dart.tmpl: imports the test,
                    its flutter_test_config.dart (if any) and the driver.
  <name>_kernel     dart_jit_kernel over the bootstrap, the test sources and the
                    driver. Always debug: tests never read //flutter:mode.
  <name>            the launcher test, which runs the toolchain's flutter_tester
                    on the kernel.

The launcher is a test so that Bazel sets TEST_SRCDIR, TEST_TMPDIR and the
filter/shard variables for it.
"""

load(":pubspec.bzl", "FlutterPubspecInfo")
load(":rules.bzl", "dart_jit_kernel")

visibility(["//flutter", "//tests/flutter_test_conformance"])

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

def _host_test_bootstrap_impl(ctx):
    test = ctx.file.src
    pubspec = ctx.attr.pubspec[FlutterPubspecInfo].src
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
            "{{PACKAGE_ROOT}}": _execroot_path(pubspec).rpartition("/")[0],
            "{{TEST_FILE}}": _runfile(ctx, test),
            "{{TEST_MAIN}}": test_main,
            "{{TEST_URI}}": uri(test),
        },
    )
    return [DefaultInfo(files = depset([out]))]

_host_test_bootstrap = rule(
    implementation = _host_test_bootstrap_impl,
    doc = "Generates the bootstrap that a host test compiles as its entrypoint.",
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
        "pubspec": attr.label(
            mandatory = True,
            providers = [FlutterPubspecInfo],
            doc = "The flutter_pubspec target of the package the test belongs to.",
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

def _host_test_launcher_impl(ctx):
    toolchain = ctx.toolchains["//flutter/private:flutter_toolchain_type"].flutter
    pubspec = ctx.attr.pubspec[FlutterPubspecInfo]
    pkg_dir = _parent(_runfile(ctx, pubspec.src))

    assets_flag = ""
    assets_export = ""
    assets_files = []
    if ctx.attr.assets:
        assets_files = ctx.attr.assets[DefaultInfo].files.to_list()
        if len(assets_files) != 1:
            fail("{}: assets must be one directory, got {} files".format(ctx.label, len(assets_files)))
        assets_path = _runfile(ctx, assets_files[0])
        assets_export = 'export UNIT_TEST_ASSETS="$ROOT/{}"'.format(assets_path)
        assets_flag = '--flutter-assets-dir="$ROOT/{}"'.format(assets_path)

    runner = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.write(
        runner,
        """#!/bin/bash
# Host test launcher generated from flutter/private/host_test.bzl.
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

_host_launcher_test = rule(
    implementation = _host_test_launcher_impl,
    test = True,
    doc = "Runs a host test kernel on the toolchain's flutter_tester.",
    attrs = {
        "dill": attr.label(
            allow_single_file = [".dill"],
            mandatory = True,
            doc = "The debug kernel from dart_jit_kernel.",
        ),
        "pubspec": attr.label(
            mandatory = True,
            providers = [FlutterPubspecInfo],
            doc = "The flutter_pubspec target: the package name and the working directory.",
        ),
        "srcs": attr.label_list(
            allow_files = True,
            doc = "Test sources, in runfiles for golden files and the like.",
        ),
        "data": attr.label_list(
            allow_files = True,
            doc = "Runtime data the test reads.",
        ),
        "assets": attr.label(
            doc = "A flutter_assets directory. Sets --flutter-assets-dir and UNIT_TEST_ASSETS.",
        ),
    },
    toolchains = ["//flutter/private:flutter_toolchain_type"],
)

def host_test(name, src, pubspec, pub, srcs = [], data = [], path_deps = [], assets = None, **kwargs):
    """Runs one Dart test file in-process on flutter_tester.

    Args:
      name: the launcher's name. Also prefixes the bootstrap and kernel targets.
      src: the test file, relative to the package.
      pubspec: the package's flutter_pubspec target.
      pub: the pub hub repository, e.g. "@flutter_test_conformance".
      srcs: the package's test sources, including any flutter_test_config.dart.
      data: runtime files the test reads.
      path_deps: path-dependency packages the test imports.
      assets: a flutter_assets directory. Sets --flutter-assets-dir and UNIT_TEST_ASSETS.
      **kwargs: forwarded to the launcher test rule.
    """
    bootstrap = name + "_bootstrap"
    _host_test_bootstrap(
        name = bootstrap,
        src = src,
        srcs = srcs,
        pubspec = pubspec,
    )
    all_srcs = srcs if src in srcs else [src] + srcs
    dart_jit_kernel(
        name = name + "_kernel",
        srcs = all_srcs + _DRIVER_SRCS,
        entrypoint = ":" + bootstrap,
        pubspec = pubspec,
        package_config = pub + "//:package_config.json",
        pub_srcs = [pub + "//:lib"],
        path_deps = path_deps,
    )
    _host_launcher_test(
        name = name,
        dill = ":" + name + "_kernel",
        pubspec = pubspec,
        srcs = srcs,
        data = data,
        assets = assets,
        **kwargs
    )
