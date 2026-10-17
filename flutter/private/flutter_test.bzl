"""Host test: one Dart test file, run in-process on flutter_tester.

A flutter_test is these targets:

  <name>                 the launcher test, which runs the toolchain's
                         flutter_tester on the kernel.
  <name>_update_goldens  a manual runnable that rewrites the goldens beside the
                         test file. Declared when `goldens` is passed.
  <name>_bootstrap       expand_template of bootstrap.dart.tmpl: imports the
                         test, its flutter_test_config.dart (if any) and the
                         driver.
  <name>_kernel          dart_test_kernel over the bootstrap, the test sources,
                         the driver and the package. Always debug: tests never
                         read //flutter:mode.

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

_UPDATE_SUFFIX = "_update_goldens"

_TEST_ROOT = """ROOT="${TEST_SRCDIR:-${RUNFILES_DIR:-}}"
if [[ -z "$ROOT" ]]; then
  echo "neither TEST_SRCDIR nor RUNFILES_DIR is set" >&2
  exit 1
fi"""

# bazel run clears the runfiles variables, so the tree is found beside the script.
_UPDATE_ROOT = """if [[ -z "${BUILD_WORKSPACE_DIRECTORY:-}" ]]; then
  echo "run this target with bazel run" >&2
  exit 1
fi
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
ROOT="$SELF.runfiles"
export RUNFILES_DIR="$ROOT\""""

_LAUNCHER = """#!/bin/bash
# Host test launcher generated from flutter/private/flutter_test.bzl.
set -euo pipefail
{root}
export FLUTTER_TEST=true
export APP_NAME="$(cat "$ROOT/{package_name}")"
{update_env}
{assets_export}
# The package root is the working directory, as for `flutter test`. --packages
# is omitted: pub's package_config rootUris are execroot-relative and do not
# resolve in runfiles. The kernel already holds every imported library.
{workdir}
exec "$ROOT/{tester}" --disable-vm-service --non-interactive --enable-checked-mode \\
  --verify-entry-points --enable-software-rendering --skia-deterministic-rendering \\
  --use-test-fonts --disable-asset-fonts --icu-data-file-path="$ROOT/{icu}" \\
  {assets_flag} "$ROOT/{dill}"
"""

_MATERIALIZE_COPY = """materialize() {
  if [[ "$(uname -s)" == Darwin ]]; then
    cp -RLc "$1" "$2" 2>/dev/null || { rm -rf "$2"; cp -RL "$1" "$2"; }
  else
    cp -RL --reflink=auto "$1" "$2"
  fi
  chmod -R u+w "$2"
}"""

_MATERIALIZE_HARDLINK = """materialize() {
  if cp -RLl "$1" "$2" 2>/dev/null; then
    return 0
  fi
  rm -rf "$2"
  cp -RL "$1" "$2"
  chmod -R u+w "$2"
}"""

def _parent(path):
    """The directory of a short path. `""` is the repository root."""
    return path.rpartition("/")[0]

def _join(dir, name):
    return dir + "/" + name if dir else name

def _depth(path):
    return path.count("/")

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

def _shell_quote(value):
    return "'" + value.replace("'", "'\"'\"'") + "'"

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
            "{{GOLDENS_DECLARED}}": "true" if ctx.attr.goldens_declared else "false",
            "{{TEST_LABEL}}": ctx.attr.test_label,
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
        "test_label": attr.string(
            mandatory = True,
            doc = "The test's label, named in golden hints.",
        ),
        "goldens_declared": attr.bool(
            doc = "Whether the test declares goldens, which picks the golden hint.",
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

def _materialize_script(pkg_dir, dirs, mode):
    """Shell that makes each materialized dir a real directory, and cd's to a mirror of the package.

    The mirror holds symlinks to the package's entries, except that each dir on
    the way to a materialized dir is a real directory of its own.
    """
    if not dirs:
        return 'cd "$ROOT/{}"'.format(pkg_dir)

    ancestors = {"": True}
    keep = {}
    for d in dirs:
        keep[d] = True
        parts = d.split("/")
        for i in range(1, len(parts)):
            ancestors["/".join(parts[:i])] = True
            keep["/".join(parts[:i])] = True

    lines = [
        'WORK="${TEST_TMPDIR:-$(mktemp -d)}"',
        'MIRROR="$WORK/mirror/{}"'.format(pkg_dir),
        'PKG="$ROOT/{}"'.format(pkg_dir),
        "shopt -s dotglob nullglob",
        _MATERIALIZE_HARDLINK if "hardlink" == mode else _MATERIALIZE_COPY,
    ]
    for a in sorted(ancestors, key = _depth):
        slash = "/" + a if a else ""
        skips = sorted([s.rpartition("/")[2] for s in keep if s.rpartition("/")[0] == a])
        lines += [
            'mkdir -p "$MIRROR{}"'.format(slash),
            'for entry in "$PKG{}"/*; do'.format(slash),
            '  name="${entry##*/}"',
            '  case "$name" in {}) continue ;; esac'.format("|".join([_shell_quote(s) for s in skips])),
            '  ln -s "$entry" "$MIRROR{}/$name"'.format(slash),
            "done",
        ]
    for d in sorted(dirs):
        lines.append('materialize "$PKG/{d}" "$MIRROR/{d}"'.format(d = d))
    lines.append('cd "$MIRROR"')
    return "\n".join(lines)

def _launcher(ctx, update):
    """Writes the launcher script and returns it with its runfiles."""
    toolchain = ctx.toolchains["//flutter/private:flutter_toolchain_type"].flutter
    package = ctx.attr.app[FlutterPackageInfo]
    pubspec = package.pubspec
    pkg_dir = _parent(_runfile(ctx, pubspec.src))

    files = ctx.files.srcs + ctx.files.data + ctx.files.goldens
    for d in ctx.attr.materialize:
        prefix = pkg_dir + "/" + d + "/"
        if not any([_runfile(ctx, f).startswith(prefix) for f in files]):
            fail("materialize: {} has no declared file under it; list its files in data, srcs or goldens".format(d))

    assets_flag = ""
    assets_export = ""
    assets_files = []
    if package.assets:
        assets_files = [package.assets]
        assets_path = _runfile(ctx, package.assets)
        assets_export = 'export UNIT_TEST_ASSETS="$ROOT/{}"'.format(assets_path)
        assets_flag = '--flutter-assets-dir="$ROOT/{}"'.format(assets_path)

    update_env = ""
    if update:
        update_env = "\n".join(
            ["export TZ=UTC"] +
            ["export {}={}".format(k, _shell_quote(v)) for k, v in sorted(ctx.attr.env.items())] +
            ['export FLUTTER_TEST_UPDATE_GOLDENS="$BUILD_WORKSPACE_DIRECTORY/{}"'.format(ctx.file.src.short_path)],
        )

    runner = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.write(
        runner,
        _LAUNCHER.format(
            root = _UPDATE_ROOT if update else _TEST_ROOT,
            update_env = update_env,
            assets_export = assets_export,
            assets_flag = assets_flag,
            dill = _runfile(ctx, ctx.file.dill),
            icu = _runfile(ctx, toolchain.icu_data),
            package_name = _runfile(ctx, pubspec.package_name),
            tester = _runfile(ctx, toolchain.flutter_tester),
            workdir = _materialize_script(pkg_dir, ctx.attr.materialize, ctx.attr.materialize_mode),
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
        ] + assets_files + files,
    )
    return runner, runfiles

def _tester_test_impl(ctx):
    runner, runfiles = _launcher(ctx, update = False)
    return [
        DefaultInfo(executable = runner, runfiles = runfiles),
        RunEnvironmentInfo(
            environment = ctx.attr.env,
            inherited_environment = ctx.attr.env_inherit,
        ),
    ]

def _golden_update_impl(ctx):
    src = ctx.file.src
    if not src.is_source or src.short_path.startswith("../"):
        fail("goldens can be updated only for a test file in the source tree, not {}".format(src.short_path))
    runner, runfiles = _launcher(ctx, update = True)
    return [DefaultInfo(
        executable = runner,
        files = depset([runner, ctx.file.dill]),
        runfiles = runfiles,
    )]

_LAUNCHER_ATTRS = {
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
    "src": attr.label(
        allow_single_file = [".dart"],
        mandatory = True,
        doc = "The test file. The update target writes goldens beside it.",
    ),
    "srcs": attr.label_list(
        allow_files = True,
        doc = "Test sources, in runfiles for golden files and the like.",
    ),
    "data": attr.label_list(
        allow_files = True,
        doc = "Runtime data the test reads.",
    ),
    "goldens": attr.label_list(
        allow_files = True,
        doc = "Golden files the test compares against.",
    ),
    "materialize": attr.string_list(
        doc = "Package-relative directories to copy into the working directory as real files.",
    ),
    "materialize_mode": attr.string(
        default = "copy",
        values = ["copy", "hardlink"],
        doc = "How materialize copies: `copy` (clones where the filesystem allows), or `hardlink`.",
    ),
    "env": attr.string_dict(
        doc = "Environment variables for the test, overriding Bazel's defaults.",
    ),
    "env_inherit": attr.string_list(
        doc = "Environment variables inherited from the invoking shell.",
    ),
}

_tester_test = rule(
    implementation = _tester_test_impl,
    test = True,
    doc = "Runs a flutter_test kernel on the toolchain's flutter_tester.",
    attrs = dict(_LAUNCHER_ATTRS),
    toolchains = ["//flutter/private:flutter_toolchain_type"],
)

_golden_update = rule(
    implementation = _golden_update_impl,
    executable = True,
    doc = "Runs a flutter_test kernel with goldens written to the source tree.",
    attrs = dict(_LAUNCHER_ATTRS),
    toolchains = ["//flutter/private:flutter_toolchain_type"],
)

def _materialize_dirs(dirs):
    """Checks that each directory is package-relative and that none contains another."""
    out = []
    for d in dirs:
        d = d.rstrip("/")
        if not d or d.startswith("/") or ".." in d.split("/"):
            fail("materialize: {} must be a directory relative to the package".format(d))
        out.append(d)
    for d in out:
        for e in out:
            if e != d and e.startswith(d + "/"):
                fail("materialize: {} lies under {}; materialize only the outer one".format(e, d))
    return out

def flutter_test(
        name,
        app,
        src,
        srcs = [],
        data = [],
        dart_defines = {},
        goldens = None,
        materialize = [],
        materialize_mode = "copy",
        env = {},
        env_inherit = [],
        **kwargs):
    """Runs one Dart test file in-process on flutter_tester.

    The package's inputs come from `app`, a flutter_package target: its pubspec,
    libraries, dependencies and assets. The test's own inputs are `src` and `srcs`.

        flutter_test(
            name = "widget_test",
            app = ":app",
            src = "test/widget_test.dart",
            goldens = glob(["test/goldens/**"], allow_empty = True),
        )

    `bazel test` never writes. To create or update goldens, run
    `bazel run :widget_test_update_goldens`, which rewrites the goldens the test
    requests beside the test file. It is declared whenever `goldens` is passed,
    including as `[]`, so pass `glob(..., allow_empty = True)` before the first
    golden exists. A golden must be declared here to be compared: a request for an
    undeclared one fails with the target to run.

    Goldens are compared against the pixels the test renders, so a golden that
    depends on the platform needs one file per platform, both declared here.

    The test's working directory is the package root, as for `flutter test`.
    `materialize` lists package directories to copy in as real files, for code
    that lists them with `Directory.listSync` (runfiles are symlinks). Each must
    have a file declared in `data`, `srcs` or `goldens`. `materialize_mode =
    "hardlink"` links the files instead of copying: a write through a link
    changes the file it links to, so use it only for read-only data.

    Bazel sets TZ=UTC for the test. Override it, or any other variable, with
    `env`, and inherit from the invoking shell with `env_inherit`.

    Args:
      name: the launcher's name. Also prefixes the bootstrap and kernel targets.
      app: the flutter_package target of the package the test belongs to.
      src: the test file, relative to the package.
      srcs: the test's other sources, including any flutter_test_config.dart.
        A test importing a file not listed here fails to compile.
      data: runtime files the test reads.
      dart_defines: `-D` constants this test compiles with. Not the app's.
      goldens: golden files the test compares against, as a list of labels.
        Passing a value, even `[]`, declares `<name>_update_goldens`.
      materialize: package-relative directories to copy in as real files.
      materialize_mode: `copy` (the default) or `hardlink`.
      env: environment variables for the test, as a dict.
      env_inherit: names of environment variables inherited from the shell.
      **kwargs: forwarded to the launcher test rule. The update target takes
        only `visibility` and `testonly`.
    """
    tags = kwargs.pop("tags", [])
    bootstrap = name + "_bootstrap"
    _flutter_test_bootstrap(
        name = bootstrap,
        app = app,
        src = src,
        srcs = srcs,
        test_label = "//{}:{}".format(native.package_name(), name),
        goldens_declared = goldens != None,
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
    launcher = dict(
        dill = ":" + name + "_kernel",
        app = app,
        src = src,
        srcs = srcs,
        data = data,
        goldens = goldens or [],
        materialize = _materialize_dirs(materialize),
        materialize_mode = materialize_mode,
        env = env,
        env_inherit = env_inherit,
    )
    _tester_test(
        name = name,
        tags = tags,
        **dict(launcher, **kwargs)
    )
    if goldens != None:
        _golden_update(
            name = name + _UPDATE_SUFFIX,
            tags = ["manual"],
            **dict(launcher, **{k: kwargs[k] for k in ["visibility", "testonly"] if k in kwargs})
        )
