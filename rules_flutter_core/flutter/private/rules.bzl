"""Rules for the Dart half of a Flutter build.

The Flutter build decomposes into two independent halves:

  1. Dart:     .dart sources -> app.dill -> platform-declared AOT artifact
  2. Platform: Flutter artifacts -> platform-native application

These rules cover the Dart half only, producing neutral Dart outputs that
platform rulesets package into their native applications. Nothing here shells
out to `flutter build`; the underlying frontend_server and gen_snapshot are
driven directly.

Platform packaging is per-platform and is not loaded from here. Keeping it
separate lets a consumer load only the platforms it builds.

Package resolution
------------------
Every package a compile or a bundle reads is a declared input. The `pub`
module extension (pub_lock.bzl) turns the app's `pubspec.lock` into a hub
repository holding a package config whose rootUris are all relative, hosted
packages as sha256-pinned repositories, and the Flutter SDK's own packages as
`toolchain.sdk_packages`. No package is resolved through `~/.pub-cache`,
`.dart_tool/` or the SDK by absolute path, so these actions are sandboxed and
their keys and outputs do not depend on where the packages sit. The flutter
tool the assets action runs is still a host input (see `_ASSETS_EXEC`).
"""

load("@bazel_skylib//lib:paths.bzl", "paths")
load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load(":hook_packages.bzl", "FlutterHookPackagesInfo", "staged_hook_packages")
load(":pubspec.bzl", "FlutterPubspecInfo")

FlutterTargetSliceInfo = provider(
    doc = "Platform metadata resolved for a configured Flutter target slice.",
    fields = [
        "target_platform",
        "slice_id",
        "target_os",
    ],
)

FlutterTargetSlicesInfo = provider(
    doc = "Platform metadata for the selected target slices.",
    fields = ["slices"],
)

FlutterAotSnapshotInfo = provider(
    doc = "The AOT artifact kind produced by a snapshot action.",
    fields = ["kind"],
)

def _platform_slice_transition_impl(_settings, attr):
    return {
        str(platform): {"//command_line_option:platforms": [str(platform)]}
        for platform in attr.target_platforms
    }

_platform_slice_transition = transition(
    implementation = _platform_slice_transition_impl,
    inputs = [],
    outputs = ["//command_line_option:platforms"],
)

def _flutter_target_slice_impl(ctx):
    target = ctx.toolchains["//flutter/private:flutter_target_toolchain_type"]
    if target == None:
        return [FlutterTargetSliceInfo(
            target_platform = "",
            slice_id = "",
            target_os = "",
        )]
    target = target.flutter_target
    return [FlutterTargetSliceInfo(
        target_platform = target.target_platform,
        slice_id = target.slice_id,
        target_os = target.target_os,
    )]

flutter_target_slice = rule(
    implementation = _flutter_target_slice_impl,
    toolchains = [config_common.toolchain_type(
        Label("//flutter/private:flutter_target_toolchain_type"),
        mandatory = False,
    )],
)

def _flutter_target_slices_impl(ctx):
    return [FlutterTargetSlicesInfo(slices = [
        ctx.split_attr.targets[str(platform.label)][0][FlutterTargetSliceInfo]
        for platform in ctx.attr.target_platforms
    ])]

def flutter_target_slices_rule(slice_transition):
    """Creates a split rule keyed by `str(platform_label)` for target-slice metadata."""
    return rule(
        implementation = _flutter_target_slices_impl,
        attrs = {
            "target_platforms": attr.label_list(mandatory = True),
            "targets": attr.label_list(
                default = [Label("//flutter/private:target_slice")],
                cfg = slice_transition,
                providers = [FlutterTargetSliceInfo],
            ),
        },
    )

flutter_target_slices = flutter_target_slices_rule(_platform_slice_transition)

visibility(["//flutter"])

# The bundle action runs `flutter build bundle`, and the flutter tool is still a
# host input: it is found through the SDK symlinks, not declared, so a remote
# worker would not have it. The action is otherwise sandboxed and cacheable. It
# takes no mode and compiles only the stub's closure for record-use (no app lib/), so its
# key is the same in every build mode and a `lib/` edit never reruns it. Deliberately
# absent: `local`, which would disable remote caching outright.
_ASSETS_EXEC = {"no-remote-exec": "1"}

def _repository_path(ctx, file, attribute):
    """A source file's path within the repository owning this rule."""
    short_path = file.short_path
    if not ctx.label.repo_name:
        if short_path.startswith("../"):
            fail("{}: {} must be in the main repository, got {}.".format(
                ctx.label,
                attribute,
                short_path,
            ))
        return short_path

    prefix = "../{}/".format(ctx.label.repo_name)
    if not short_path.startswith(prefix):
        fail("{}: {} must be in repository {}, got {}.".format(
            ctx.label,
            attribute,
            ctx.label.repo_name,
            short_path,
        ))
    return short_path[len(prefix):]

def library_path(ctx, file, attribute):
    """A source file's path within its package, as a `package:` URI suffix.

    `package:<name>/x.dart` resolves to `lib/x.dart`, so the URI carries the
    path under lib/ and nothing else. Taking it from a label rather than asking
    for the URI is what keeps the package name out of BUILD files -- and a
    typo fails here instead of producing a URI that resolves to nothing.

    Args:
      ctx: the rule context.
      file: the source File.
      attribute: the attribute name, for error messages.

    Returns:
      The path under lib/, without the package name.
    """
    path = _repository_path(ctx, file, attribute)
    prefix = (ctx.label.package + "/" if ctx.label.package else "") + "lib/"
    if not path.startswith(prefix):
        fail("{}: {} must be a .dart file under {}, got {}.".format(
            ctx.label,
            attribute,
            prefix,
            path,
        ))
    return path[len(prefix):]

def _execroot_path(file):
    """A file's path from the execroot, which is also its path under the virtual root.

    A file in another repository has a `../<repo>/` short_path and lives at
    `external/<repo>/` in the execroot.
    """
    if file.short_path.startswith("../"):
        return "external/" + file.short_path[len("../"):]
    return file.short_path

def lib_root(label):
    """The execroot prefix of a package's lib/ directory, as dart_entry_uri matches it.

    A package's lib/ files are its `package:` libraries, so the prefix must be
    the package that owns the files, not the target that compiles them.
    """
    root = "../{}/".format(label.repo_name) if label.repo_name else ""
    return root + (label.package + "/" if label.package else "") + "lib/"

def dart_entry_uri(lib, file):
    """A Dart source's frontend_server URI, as a `(scheme, path)` pair.

    A file under `lib` (see lib_root) is a `package:` library. Any other .dart
    file is addressed by its execroot path under org-dartlang-root, which
    resolves through whichever virtual root holds it.
    """
    if file.short_path.startswith(lib):
        return ("package", file.short_path[len(lib):])
    return ("org-dartlang-root", _execroot_path(file))

def _dart_entry_uri(ctx, file):
    return dart_entry_uri(lib_root(ctx.label), file)

def _dart_define_flags(defines):
    """`-D<name>=<value>` flags for frontend_server, sorted by name.

    Sorted rather than in dict order, so equal dart_defines written in a different
    order produce the same action key. An empty dict adds no flags.
    """
    return ["-D{}={}".format(name, defines[name]) for name in sorted(defines)]

def _sdk_root_for(platform_files, mode):
    """Directory holding platform_strong.dill, for a patched-SDK filegroup.

    `--sdk-root` wants the directory, not the file.
    """
    for f in platform_files:
        if f.basename == "platform_strong.dill":
            return f.dirname
    fail("platform_strong.dill not found for mode '{}'".format(mode))

# frontend_server flags for a debug (JIT) kernel. Used by dart_jit_kernel alone,
# so the debug flags have one definition.
_DEBUG_KERNEL_FLAGS = [
    "-Ddart.vm.profile=false",
    "-Ddart.vm.product=false",
    "--enable-asserts",
    "--track-widget-creation",
    "--no-link-platform",
]

# `--source`/`-D` triple that compiles a plugin registrant into the kernel and
# makes the engine's `dart_plugin_registrant` lookup match the exact URI
# frontend_server records for it. Shared by dart_aot_kernel and
# dart_jit_kernel; shell variables are resolved at run time.
_REGISTRANT_SOURCE_ARGS = '--source "{uri}" --source "package:flutter/src/dart_plugin_registrant.dart" "-Dflutter.dart_plugin_registrant={uri}"'

def _flutter_toolchain(ctx):
    return ctx.toolchains["//flutter/private:flutter_toolchain_type"].flutter

def _flutter_target_toolchain(ctx):
    return ctx.toolchains["//flutter/private:flutter_target_toolchain_type"].flutter_target

def _flutter_aot_toolchain(ctx):
    return ctx.toolchains["//flutter/private:flutter_aot_toolchain_type"].flutter_aot

def _dart_aot_kernel_impl(ctx):
    dill = ctx.actions.declare_file(ctx.label.name + ".dill")

    # The product SDK: this kernel is only ever gen_snapshot's input. Debug
    # kernels are dart_jit_kernel's.
    toolchain = _flutter_toolchain(ctx)
    platform_files = toolchain.platform_product

    # --sdk-root wants the directory holding platform_strong.dill.
    sdk_root = _sdk_root_for(platform_files, "release")

    args = ctx.actions.args()

    args.add(toolchain.dartaotruntime)
    args.add(toolchain.frontend_server)
    args.add("--sdk-root", sdk_root + "/")
    args.add("--target", "flutter")

    # frontend_server speaks its compiler-daemon protocol on every completion,
    # success included: one `+file:///...` line per source it read, absolute
    # host and execroot paths included, which drowns anything real. Turning the
    # flag off leaves only the `result <uuid>` handshake, which has no flag.
    #
    # Deliberately not done by capturing stdout in the wrapper instead: the
    # kernel is byte-identical either way, but a wrapper has to re-raise the
    # exit code by hand (frontend_server exits 254 on a compile error) and it
    # discards whatever the CFE prints on a *successful* compile, where
    # --verbosity defaults to `all`.
    args.add("--no-print-incremental-dependencies")
    args.add("--aot")
    args.add("--tfa")
    args.add("-Ddart.vm.product=true")

    target_os = ctx.attr.target_os
    if not target_os:
        target_slices = [
            slice
            for target in ctx.attr.target_slices
            for slice in target[FlutterTargetSlicesInfo].slices
        ]
        target_os_values = {
            target.target_os: True
            for target in target_slices
            if target.target_os
        }
        if not target_os_values:
            fail("dart_aot_kernel has no Flutter target toolchain for {}; set target_os or register a platform ruleset".format(ctx.label))
        if len(target_os_values) != 1:
            fail("dart_aot_kernel target platforms must agree on target_os; got {}".format(sorted(target_os_values.keys())))
        target_os = target_os_values.keys()[0]
    args.add("--target-os", target_os)

    args.add_all(_dart_define_flags(ctx.attr.dart_defines))

    # The package config is the pub hub's: every rootUri is relative, so it is
    # loaded through the virtual filesystem scheme rooted at the execroot. Source
    # URIs in the kernel are then `org-dartlang-root:///...`, never absolute host
    # paths, and nothing outside the action's declared inputs is readable.
    args.add("--filesystem-root", ".")
    args.add("--filesystem-scheme", "org-dartlang-root")
    args.add("--packages", "org-dartlang-root:///" + ctx.file.package_config.path)

    # The Dart half of plugin registration. GeneratedPluginRegistrant.java
    # covers a plugin's native class; a federated plugin also declares a
    # `dartPluginClass` implementing its platform interface, and that half lives
    # in a generated Dart library nothing imports. It is compiled in via
    # --source, and the engine locates it at runtime through the
    # `flutter.dart_plugin_registrant` define, which
    # package:flutter/src/dart_plugin_registrant.dart reads into a const.
    #
    # Without it the app builds, launches, and registers every plugin natively,
    # then throws MissingPluginException the first time a federated plugin is
    # used -- the platform interface never got its implementation, so calls fall
    # through to the default method-channel one.
    #
    # It is a `package:` URI, and has to be. The engine looks the library up by
    # this exact string, so it must match the URI frontend_server recorded for
    # it -- pass a relative path and the compiler canonicalises it to an
    # absolute file:// URI, the define keeps the relative form, the lookup
    # misses, and the registrant silently never runs.
    #
    # Matching them by passing absolute paths would work and is what
    # flutter_tools does, but the define is a const String *value* the engine
    # reads at runtime, so gen_snapshot --strip cannot discard it the way it
    # discards source URIs. That would put a machine-specific absolute path in a
    # shipped release artifact -- see "Path embedding" -- so the registrant is
    # addressed through the package config instead, exactly like the entrypoint.
    pubspec = ctx.attr.pubspec[FlutterPubspecInfo]

    # The app package name is file content, so the entrypoint URI is assembled
    # at execution. Registrants use their package URI when committed under this
    # app's lib/, or an execroot URI when generated in the external pub hub.
    registrant_scheme, registrant_path = _dart_entry_uri(ctx, ctx.file.dart_plugin_registrant) if ctx.file.dart_plugin_registrant else ("", "")
    scalars = ctx.actions.args()
    scalars.add(pubspec.package_name)
    scalars.add(library_path(ctx, ctx.file.entrypoint, "entrypoint"))
    scalars.add(registrant_scheme)
    scalars.add(registrant_path)
    scalars.add(dill)

    ctx.actions.run_shell(
        command = """set -euo pipefail
PKG="$(cat "$1")"; shift
ENTRYPOINT="$1"; shift
REGISTRANT_SCHEME="$1"; shift
REGISTRANT_PATH="$1"; shift
DILL="$1"; shift

if [ -n "$REGISTRANT_PATH" ]; then
    if [ "$REGISTRANT_SCHEME" = "package" ]; then
        REGISTRANT_URI="package:$PKG/$REGISTRANT_PATH"
    elif [ "$REGISTRANT_SCHEME" = "org-dartlang-root" ]; then
        REGISTRANT_URI="org-dartlang-root:///$REGISTRANT_PATH"
    else
        echo "ERROR: unsupported registrant URI scheme: $REGISTRANT_SCHEME" >&2
        exit 1
    fi
    set -- "$@" {registrant_args}
fi

exec "$@" --output-dill "$DILL" "package:$PKG/$ENTRYPOINT"
""".format(registrant_args = _REGISTRANT_SOURCE_ARGS.format(uri = "$REGISTRANT_URI")),
        arguments = [scalars, args],
        tools = [toolchain.dartaotruntime],
        # Every readable package is declared: the hub's package config (relative
        # roots only, so the key has no host path), hosted packages, and SDK
        # packages. Hosted content is sha256-pinned; path dependencies are covered
        # only by `srcs` / `path_deps`.
        inputs = depset(
            direct = [
                         toolchain.frontend_server,
                         toolchain.sdk_version,
                         ctx.file.package_config,
                         # The name alone, not pubspec.yaml: a version bump or an edit
                         # to the asset list must not invalidate the kernel.
                         pubspec.package_name,
                         # Declared as well as globbed into srcs. These two are labels,
                         # so an app whose srcs miss the entrypoint still rebuilds when
                         # it changes rather than serving a stale kernel.
                         ctx.file.entrypoint,
                     ] + ([ctx.file.dart_plugin_registrant] if ctx.file.dart_plugin_registrant else []) +
                     ctx.files.path_deps,
            transitive = [
                depset(platform_files),
                depset(ctx.files.srcs),
                depset(ctx.files.pub_srcs),
                toolchain.sdk_packages,
            ],
        ),
        outputs = [dill],
        mnemonic = "DartAotKernel",
        progress_message = "Compiling Dart AOT kernel %{label}",
    )

    return [DefaultInfo(files = depset([dill]))]

dart_aot_kernel = rule(
    implementation = _dart_aot_kernel_impl,
    doc = "Compiles Dart sources to an AOT kernel (.dill) for gen_snapshot. Release only; debug uses dart_jit_kernel.",
    attrs = {
        "srcs": attr.label_list(
            allow_files = [".dart"],
            doc = "Dart sources. Used for change detection, not passed directly.",
        ),
        "pubspec": attr.label(
            mandatory = True,
            providers = [FlutterPubspecInfo],
            doc = "A flutter_pubspec target; supplies the package name.",
        ),
        "entrypoint": attr.label(
            allow_single_file = [".dart"],
            mandatory = True,
            doc = """The app's entrypoint, e.g. `lib/main.dart`.

Reached as `package:<pubspec name>/<path under lib/>`, which is why it has to
live under lib/: nothing outside a package's lib/ has a package: URI.""",
        ),
        "dart_plugin_registrant": attr.label(
            allow_single_file = [".dart"],
            doc = """The generated Dart plugin registrant, e.g.
`lib/dart_plugin_registrant.dart`.

Registers the Dart half of federated plugins. Addressed by package: URI like
the entrypoint, so the value the engine looks up is machine-independent. Omit
for an app with no federated plugins.""",
        ),
        "package_config": attr.label(
            allow_single_file = True,
            mandatory = True,
            doc = """The pub hub's `package_config.json`.

Every rootUri is relative to the hub, so the compile reads it through
`--filesystem-root`. It is a declared input.""",
        ),
        "pub_srcs": attr.label_list(
            allow_files = True,
            allow_empty = False,
            mandatory = True,
            doc = "The pub hub's `:lib`: every hosted package's packageUri tree, and `package_config.json`.",
        ),
        "path_deps": attr.label_list(
            allow_files = True,
            doc = """Sources of `path:` dependencies from pubspec.yaml.

Hosted packages are covered by the pub hub's sha256-pinned repositories. Path
dependencies have no hash and a version that nobody bumps, so nothing else in
the action key observes their content -- editing one produces a silently stale
artifact, and with a shared cache that artifact is served to everyone.

Point this at a filegroup in the dependency's own package, e.g.
`path_deps = ["//packages/mylib:srcs"]`. Bazel globs cannot cross package
boundaries, so the dependency needs its own BUILD file.""",
        ),
        "dart_defines": attr.string_dict(
            doc = """Compile-time constants, passed as `-D<name>=<value>`.

Only const-evaluated reads see them: `const String.fromEnvironment("FOO")` (likewise
`bool`/`int.fromEnvironment`). A non-const call is evaluated by the VM, which does
not get these values, and returns the default. They are in the action key, so
changing a value recompiles the kernel; an empty dict adds no flags, so existing
keys are unchanged.""",
        ),
        "target_os": attr.string(
            doc = "Target OS override; otherwise derived from the registered platform toolchain.",
        ),
        "target_slices": attr.label_list(
            mandatory = True,
            providers = [FlutterTargetSlicesInfo],
            doc = "Per-platform target-toolchain metadata.",
        ),
    },
    toolchains = ["//flutter/private:flutter_toolchain_type"],
)

# A test kernel's undeclared import is absent from the sandbox, so the frontend
# reports it as not found. The hint says where the file has to be declared.
# Shared with flutter_debug_core, which has the same sandbox.
TEST_IMPORT_HINT = "hint: declare test-local imports in `srcs`"

def jit_kernel_action(ctx, dill, pkg, entrypoint, dart_defines, hint, mnemonic, what):
    """Declares the debug kernel action of dart_jit_kernel, dart_test_kernel and flutter_debug_core.

    `pkg` is a struct of the package's inputs: package_name, package_config,
    pub_srcs, path_deps, srcs, registrant, registrant_path, lib (lib_root of the
    package that owns the sources), and import_dill, the kernel to import with
    --import-dill, or None.

    Args:
      ctx: the rule context.
      dill: the output kernel File.
      pkg: the package struct described above.
      entrypoint: the Dart entrypoint File.
      dart_defines: a dict of compile-time defines.
      hint: text appended to failure messages, or "".
      mnemonic: the action mnemonic.
      what: the description shown in progress output.
    """
    toolchain = _flutter_toolchain(ctx)

    # Always debug: this action never reads //flutter:mode, so both modes ask
    # for the same action and get the same kernel. Debug keeps asserts and the
    # service protocol, so it uses the non-product platform.
    sdk_root = _sdk_root_for(toolchain.platform_debug, "debug")

    args = ctx.actions.args()

    args.add(toolchain.dartaotruntime)
    args.add(toolchain.frontend_server)
    args.add("--sdk-root", sdk_root + "/")
    args.add("--target", "flutter")
    args.add("--no-print-incremental-dependencies")
    args.add_all(_DEBUG_KERNEL_FLAGS)
    args.add_all(_dart_define_flags(dart_defines))
    if pkg.import_dill:
        args.add("--import-dill", pkg.import_dill)

        # frontend_server writes every library of an --import-dill compile with an
        # empty line table (filterExternal sets includeSources: false), so a stack
        # frame in the test's own libraries loses its line and column. One dill per
        # package keeps the line tables; the pieces are joined below. Source text is
        # left out, so a comment that changes neither line count nor offsets leaves
        # the bytes unchanged.
        args.add("--split-output-by-packages")
        args.add("--no-embed-source-text")

    # Two virtual roots, so that generated and source files resolve the same
    # way: sources from the execroot, generated files from bin_dir. The package
    # config is the pub hub's, read in place as dart_aot_kernel reads it.
    args.add("--filesystem-root", ".")
    args.add("--filesystem-root", ctx.bin_dir.path)
    args.add("--filesystem-scheme", "org-dartlang-root")
    args.add("--packages", "org-dartlang-root:///" + pkg.package_config.path)

    # The package name is file content, so the entrypoint URI is assembled by
    # the wrapper below, like dart_aot_kernel's.
    scheme, path = dart_entry_uri(pkg.lib, entrypoint)

    scalars = ctx.actions.args()
    scalars.add(pkg.package_name)
    scalars.add(scheme)
    scalars.add(path)
    scalars.add(pkg.registrant_path)
    scalars.add(dill)

    # With --split-output-by-packages (import_dill set), frontend_server writes one dill
    # per package beside its output; the pieces are joined into $DILL with the main
    # piece first, since the launcher runs the first component with a main. Without
    # import_dill the kernel goes straight to $DILL.
    on_fail = "    echo '" + hint + "' >&2\n" if hint else ""
    fail_exit = "|| {\n    status=$?\n" + on_fail + '    exit "$status"\n}\n'
    if pkg.import_dill:
        collect = """if [ -f "$WORK/kernel.dill-packages" ]; then
    {
        cat "$WORK/kernel.dill-main.dilp"
        while read -r pkg; do
            if [ "$pkg" != main ]; then cat "$WORK/kernel.dill-$pkg.dilp"; fi
        done < "$WORK/kernel.dill-packages"
    } > "$DILL"
else
    cat "$WORK/kernel.dill" > "$DILL"
fi"""
        run = 'WORK="$(mktemp -d)"\ntrap \'rm -rf "$WORK"\' EXIT\n"$@" --output-dill "$WORK/kernel.dill" "$ENTRY" ' + fail_exit + collect
    else:
        run = '"$@" --output-dill "$DILL" "$ENTRY" ' + fail_exit

    ctx.actions.run_shell(
        command = """set -euo pipefail
PKG="$(cat "$1")"; shift
SCHEME="$1"; shift
ENTRYPOINT="$1"; shift
REGISTRANT="$1"; shift
DILL="$1"; shift

if [ "$SCHEME" = package ]; then
    ENTRY="package:$PKG/$ENTRYPOINT"
else
    ENTRY="org-dartlang-root:///$ENTRYPOINT"
fi

if [ -n "$REGISTRANT" ]; then
    set -- "$@" {registrant_args}
fi

{run}
""".format(
            registrant_args = _REGISTRANT_SOURCE_ARGS.format(uri = "package:$PKG/$REGISTRANT"),
            run = run,
        ),
        arguments = [scalars, args],
        tools = [toolchain.dartaotruntime],
        # Every readable package is declared, as for dart_aot_kernel: the hub's
        # package config, hosted packages, path dependencies, and SDK packages.
        inputs = depset(
            direct = [
                         toolchain.frontend_server,
                         toolchain.sdk_version,
                         pkg.package_config,
                         pkg.package_name,
                         entrypoint,
                     ] + ([pkg.registrant] if pkg.registrant else []) +
                     pkg.path_deps + ([pkg.import_dill] if pkg.import_dill else []),
            transitive = [
                depset(toolchain.platform_debug),
                depset(pkg.srcs),
                depset(pkg.pub_srcs),
                toolchain.sdk_packages,
            ],
        ),
        outputs = [dill],
        mnemonic = mnemonic,
        progress_message = "Compiling " + what + " %{label}",
    )

def _dart_jit_kernel_impl(ctx):
    dill = ctx.actions.declare_file(ctx.label.name + ".dill")
    pubspec = ctx.attr.pubspec[FlutterPubspecInfo]
    registrant = ctx.file.dart_plugin_registrant

    jit_kernel_action(
        ctx,
        dill = dill,
        pkg = struct(
            package_name = pubspec.package_name,
            package_config = ctx.file.package_config,
            pub_srcs = ctx.files.pub_srcs,
            path_deps = ctx.files.path_deps,
            srcs = ctx.files.srcs,
            registrant = registrant,
            registrant_path = library_path(ctx, registrant, "dart_plugin_registrant") if registrant else "",
            lib = lib_root(ctx.label),
            import_dill = None,
        ),
        entrypoint = ctx.file.entrypoint,
        dart_defines = ctx.attr.dart_defines,
        hint = "",
        mnemonic = "DartJitKernel",
        what = "Dart JIT kernel",
    )
    return [DefaultInfo(files = depset([dill]))]

# resource_set must be a top-level function, so each fixed step is one. A reservation
# rounds up to the next step.
def _memory_1024(_os, _inputs):
    return {"cpu": 1, "memory": 1024}

def _memory_2048(_os, _inputs):
    return {"cpu": 1, "memory": 2048}

def _memory_3072(_os, _inputs):
    return {"cpu": 1, "memory": 3072}

def _memory_4096(_os, _inputs):
    return {"cpu": 1, "memory": 4096}

def _memory_6144(_os, _inputs):
    return {"cpu": 1, "memory": 6144}

def _memory_8192(_os, _inputs):
    return {"cpu": 1, "memory": 8192}

_MEMORY_RESOURCE_SETS = [
    (1024, _memory_1024),
    (2048, _memory_2048),
    (3072, _memory_3072),
    (4096, _memory_4096),
    (6144, _memory_6144),
    (8192, _memory_8192),
]

def _resource_set_for(mb):
    for step, resource_set in _MEMORY_RESOURCE_SETS:
        if mb <= step:
            return resource_set
    fail("test_kernel_memory_mb must be at most {}".format(_MEMORY_RESOURCE_SETS[-1][0]))

def _declare_prune(ctx, srcs):
    """The files of a pruned kernel: the manifest of the sources it may prune, and the unused list the driver writes."""
    manifest = ctx.actions.declare_file(ctx.label.name + ".prune_manifest")
    ctx.actions.write(manifest, "".join([f.path + "\n" for f in srcs]))
    return struct(
        manifest = manifest,
        unused = ctx.actions.declare_file(ctx.label.name + ".unused_inputs"),
    )

def _test_kernel_driver_action(ctx, dill, pkg, entrypoint, dart_defines, driver, resource_set, prune = None):
    """Declares the test kernel action on the test-kernel driver.

    Bazel starts the worker with the driver path as its only startup argument and
    appends --persistent_worker; the request arguments come from the param file.
    The same arguments serve a one-shot run, so the driver expands the param file.
    """
    toolchain = _flutter_toolchain(ctx)
    sdk_root = _sdk_root_for(toolchain.platform_debug, "debug")
    scheme, path = _dart_entry_uri(ctx, entrypoint)

    startup = ctx.actions.args()
    startup.add(driver)

    args = ctx.actions.args()
    args.set_param_file_format("multiline")
    args.use_param_file("@%s", use_always = True)
    args.add("--sdk-root", sdk_root + "/")
    args.add("--target", "flutter")
    args.add_all(_DEBUG_KERNEL_FLAGS)
    args.add_all(_dart_define_flags(dart_defines))
    args.add("--import-dill", pkg.import_dill)
    args.add("--filesystem-root", ".")
    args.add("--filesystem-root", ctx.bin_dir.path)
    args.add("--filesystem-scheme", "org-dartlang-root")
    args.add("--packages", "org-dartlang-root:///" + pkg.package_config.path)
    args.add("--entry-scheme", scheme)
    args.add("--entry-path", path)
    args.add("--package-name-file", pkg.package_name)
    args.add("--error-hint", TEST_IMPORT_HINT)
    args.add("--output-dill", dill)
    if prune:
        args.add("--prune-manifest", prune.manifest)
        args.add("--unused-inputs-list", prune.unused)

    ctx.actions.run(
        executable = toolchain.dart,
        arguments = [startup, args],
        tools = [toolchain.dart, driver],
        inputs = depset(
            direct = [
                driver,
                toolchain.sdk_version,
                pkg.package_config,
                pkg.package_name,
                entrypoint,
                pkg.import_dill,
            ] + pkg.path_deps + ([prune.manifest] if prune else []),
            transitive = [
                depset(toolchain.platform_debug),
                depset(pkg.srcs),
                depset(pkg.pub_srcs),
                toolchain.sdk_packages,
            ],
        ),
        outputs = [dill] + ([prune.unused] if prune else []),
        unused_inputs_list = prune.unused if prune else None,
        mnemonic = "DartTestKernel",
        progress_message = "Compiling Dart test kernel %{label}",
        resource_set = resource_set,
        execution_requirements = {
            "supports-workers": "1",
            "requires-worker-protocol": "json",
        },
    )

def _dart_test_kernel_impl(ctx):
    dill = ctx.actions.declare_file(ctx.label.name + ".dill")
    package = ctx.attr.app[FlutterPackageInfo]
    pkg = struct(
        package_name = package.pubspec.package_name,
        package_config = package.package_config,
        pub_srcs = package.pub_srcs,
        path_deps = package.path_deps,
        srcs = ctx.files.srcs + ctx.files.prunable_srcs + package.srcs,
        registrant = None,
        registrant_path = "",
        lib = lib_root(ctx.label),
        # A test with dart_defines compiles its package's libraries itself,
        # since deps_lib was compiled without the test's constants.
        import_dill = package.test_deps if ctx.attr.dart_defines else package.deps_lib,
    )

    # Without a pin for the Flutter version there is no driver. frontend_server, or no
    # driver, selects the frontend_server action.
    drivers = ctx.files._test_kernel_driver
    use_driver = bool(drivers) and ctx.attr._test_kernel_compiler[BuildSettingInfo].value == "worker"

    # frontend_server's --depfile cannot name the org-dartlang-root sources of a test, so only the
    # driver writes a read list; other compilers take every prunable source as an input.
    prune = _declare_prune(ctx, ctx.files.prunable_srcs) if use_driver and ctx.files.prunable_srcs else None
    if use_driver:
        _test_kernel_driver_action(
            ctx,
            dill = dill,
            pkg = pkg,
            entrypoint = ctx.file.entrypoint,
            dart_defines = ctx.attr.dart_defines,
            driver = drivers[0],
            resource_set = _resource_set_for(ctx.attr._test_kernel_memory_mb[BuildSettingInfo].value),
            prune = prune,
        )
    else:
        jit_kernel_action(
            ctx,
            dill = dill,
            pkg = pkg,
            entrypoint = ctx.file.entrypoint,
            dart_defines = ctx.attr.dart_defines,
            hint = TEST_IMPORT_HINT,
            mnemonic = "DartTestKernel",
            what = "Dart test kernel",
        )
    return [DefaultInfo(files = depset([dill]))]

FlutterPackageInfo = provider(
    doc = "A Dart package's inputs to host tests. Built by flutter_package.",
    fields = {
        "pubspec": "The package's FlutterPubspecInfo.",
        "srcs": "The package's lib/ Dart sources, as a list.",
        "package_config": "The pub hub's package_config.json.",
        "pub_srcs": "The pub hub's lib tree, as a list.",
        "path_deps": "Sources of path dependencies, as a list.",
        "assets": "The flutter_assets directory, or None.",
        "test_deps": "The pub hub's test deps kernel, from dart_test_deps. deps_lib builds on it; a test with dart_defines imports it alone.",
        "deps_lib": "The kernel a test kernel imports with --import-dill: the lib tier appended to test_deps, or test_deps alone when there is no lib tier.",
    },
)

dart_test_kernel = rule(
    implementation = _dart_test_kernel_impl,
    doc = """The debug kernel of one flutter_test.

Compiles the test's debug kernel over the package inputs its `app` provides, through the
test-kernel driver as a persistent worker when the Flutter version has a pin. Set
`//flutter:test_kernel_compiler=frontend_server` to use frontend_server instead, as
dart_jit_kernel does; a Flutter version without a pin uses frontend_server too.
It takes the test's own dart_defines and none of the app's: `flutter test` reads
defines from its command line only, so an app's defines never reach a test.

It imports the package's deps_lib, or test_deps alone when it has dart_defines:
the lib tier is compiled without the test's constants, so such a test compiles its
package's libraries itself.""",
    attrs = {
        "app": attr.label(
            mandatory = True,
            providers = [FlutterPackageInfo],
            doc = "The flutter_package the test belongs to.",
        ),
        "srcs": attr.label_list(
            allow_files = [".dart"],
            doc = "The test's own sources: the test file, flutter_test_config.dart and the driver. The package's sources come from `app`.",
        ),
        "entrypoint": attr.label(
            allow_single_file = [".dart"],
            mandatory = True,
            doc = "The bootstrap generated by flutter_test.",
        ),
        "dart_defines": attr.string_dict(
            doc = "Compile-time constants of this test; see dart_aot_kernel.dart_defines.",
        ),
        "prunable_srcs": attr.label_list(
            allow_files = [".dart"],
            doc = "Test sources the kernel may leave out of its inputs. On the worker path a source the compile does not read is listed as unused, so an edit to it re-runs neither this kernel nor, through it, the test. Other compilers take every one as an input.",
        ),
        # Empty for frontend_server, so that compiler never loads the driver's sources.
        "_test_kernel_driver": attr.label(
            default = "//flutter/private/test_kernel_driver:compiler_driver",
            allow_files = True,
        ),
        "_test_kernel_compiler": attr.label(
            default = "//flutter:test_kernel_compiler",
            providers = [BuildSettingInfo],
        ),
        "_test_kernel_memory_mb": attr.label(
            default = "//flutter:test_kernel_memory_mb",
            providers = [BuildSettingInfo],
        ),
    },
    toolchains = ["//flutter/private:flutter_toolchain_type"],
)

# Packages every host test of a hub imports, compiled once per hub. Tests that import
# these libraries take them from this kernel with --import-dill, so the test kernel
# holds only the app's and the test's own libraries. The driver's imports are listed
# here too, so the deps kernel covers everything the test bootstrap imports.
_DRIVER_PACKAGE_URIS = [
    "package:async/async.dart",
    "package:flutter_test/flutter_test.dart",
    "package:stream_channel/stream_channel.dart",
    "package:test_api/backend.dart",
    "package:test_api/hooks.dart",
]

def _dart_test_deps_impl(ctx):
    toolchain = _flutter_toolchain(ctx)
    dill = ctx.actions.declare_file(ctx.label.name + ".dill")
    entry = ctx.actions.declare_file(ctx.label.name + "_entry.dart")

    host = [f for f in ctx.files._driver if f.basename == "host.dart"]
    if len(host) != 1:
        fail("{}: the driver needs exactly one host.dart".format(ctx.label))

    uris = sorted({uri: True for uri in ctx.attr.libraries + _DRIVER_PACKAGE_URIS}.keys())

    # The entrypoint imports every library the kernel holds. The driver is imported
    # by URI, as the test bootstrap imports it, so both kernels name one library.
    lines = ["// Generated by dart_test_deps for hub {}: the deps kernel's entrypoint.".format(ctx.attr.lock_name)]
    lines += ["import '{}';".format(uri) for uri in uris]
    lines.append("import 'org-dartlang-root:///{}';".format(_execroot_path(host[0])))
    lines += ["", "void main() {}", ""]
    ctx.actions.write(entry, "\n".join(lines))

    # The test kernel's debug flags, so the deps kernel and the test kernels agree on
    # what they compile. No dart_defines: see dart_test_deps.
    sdk_root = _sdk_root_for(toolchain.platform_debug, "debug")

    args = ctx.actions.args()
    args.add(toolchain.dartaotruntime)
    args.add(toolchain.frontend_server)
    args.add("--sdk-root", sdk_root + "/")
    args.add("--target", "flutter")
    args.add("--no-print-incremental-dependencies")
    args.add_all(_DEBUG_KERNEL_FLAGS)
    args.add("--filesystem-root", ".")
    args.add("--filesystem-root", ctx.bin_dir.path)
    args.add("--filesystem-scheme", "org-dartlang-root")
    args.add("--packages", "org-dartlang-root:///" + ctx.file.package_config.path)

    scalars = ctx.actions.args()
    scalars.add(ctx.attr.hub)
    scalars.add(ctx.attr.lock_name)

    # The shell script consumes a name argument even when there are no direct packages.
    package_names = ctx.attr.packages if ctx.attr.packages else ["__no_direct_packages__"]
    scalars.add_joined(package_names, join_with = " ")
    scalars.add(dill)
    scalars.add("org-dartlang-root:///" + _execroot_path(entry))

    ctx.actions.run_shell(
        command = """set -euo pipefail
HUB="$1"; shift
LOCK="$1"; shift
NAMES="$1"; shift
DILL="$1"; shift
ENTRY="$1"; shift

LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT
if "$@" --output-dill "$DILL" "$ENTRY" >"$LOG" 2>&1; then
    exit 0
fi
cat "$LOG" >&2

# Attribution: the first direct package whose repository holds an error's location.
# Context lines name Flutter APIs, so only ': Error: ' locations are matched.
locs="$(grep -F ': Error: ' "$LOG" | sed 's/: Error: .*//' || true)"
culprit=""
for name in $NAMES; do
    if grep -F -q -e "package:$name/" -e "$HUB-$name/" <<< "$locs"; then
        culprit="$name"
        break
    fi
done
if [ -n "$culprit" ]; then
    echo "dart_test_deps: pub.lock hub $LOCK's deps kernel does not compile package \\`$culprit\\`." >&2
else
    echo "dart_test_deps: pub.lock hub $LOCK's deps kernel does not compile; no direct package is named in the errors above." >&2
fi
echo "  Leave the failing package out with test_deps_exclude on pub.lock(name = \\"$LOCK\\"); its tests then compile it per test." >&2
echo "  If another package in the deps kernel imports it, exclude that importer too." >&2
exit 1
""",
        arguments = [scalars, args],
        tools = [toolchain.dartaotruntime],
        inputs = depset(
            direct = [
                toolchain.frontend_server,
                toolchain.sdk_version,
                ctx.file.package_config,
                entry,
            ],
            transitive = [
                depset(toolchain.platform_debug),
                depset(ctx.files._driver),
                depset(ctx.files.pub_srcs),
                toolchain.sdk_packages,
            ],
        ),
        outputs = [dill],
        mnemonic = "DartTestDeps",
        progress_message = "Compiling test deps kernel %{label}",
    )
    return [DefaultInfo(files = depset([dill]))]

dart_test_deps = rule(
    implementation = _dart_test_deps_impl,
    doc = """The debug kernel of a pub hub's direct packages, shared by its host tests.

One per `pub.lock` hub, declared in the hub's BUILD file. Its entrypoint imports the
`package:` libraries of every direct main and dev package (`<name>/<name>.dart`, or
the top-level libraries of an SDK package without one), and the driver. Every test
kernel on the hub passes it to frontend_server as --import-dill, so libraries it
holds are not recompiled per test.

It is built with the test kernel's flags and no dart_defines: a pub package in it
sees the fixed debug defines only. A test's own defines reach the app's and the
test's libraries, which compile per test.""",
    attrs = {
        "hub": attr.string(
            mandatory = True,
            doc = "The hub's repository name prefix; its packages' repositories are `<hub>-<name>`.",
        ),
        "lock_name": attr.string(
            mandatory = True,
            doc = "The hub's name in pub.lock, shown in errors and in the generated entrypoint.",
        ),
        "libraries": attr.string_list(
            mandatory = True,
            doc = "The `package:` URIs of the direct packages' libraries, from the hub.",
        ),
        "packages": attr.string_list(
            mandatory = True,
            doc = "The names of the direct packages, which the errors are attributed to.",
        ),
        "package_config": attr.label(
            allow_single_file = True,
            mandatory = True,
            doc = "The pub hub's `package_config.json`.",
        ),
        "pub_srcs": attr.label_list(
            allow_files = True,
            allow_empty = False,
            mandatory = True,
            doc = "The pub hub's `:lib`.",
        ),
        "_driver": attr.label_list(
            allow_files = [".dart"],
            default = [
                "//flutter/private/test/driver:host.dart",
                "//flutter/private/test/driver:core.dart",
                "//flutter/private/test/driver:guard.dart",
                "//flutter/private/test/driver:junit.dart",
                "//flutter/private/test/driver:results.dart",
            ],
        ),
    },
    toolchains = ["//flutter/private:flutter_toolchain_type"],
)

dart_jit_kernel = rule(
    implementation = _dart_jit_kernel_impl,
    doc = """Compiles Dart sources to a debug (JIT) kernel (.dill) via frontend_server.

Never reads //flutter:mode: the action is the same under both modes, so one
kernel serves a debug app and a debug test alike. Its entrypoint may be any .dart
file in the package; see _dart_entry_uri.""",
    attrs = {
        "srcs": attr.label_list(
            allow_files = [".dart"],
            doc = "Dart sources. Used for change detection, not passed directly.",
        ),
        "pubspec": attr.label(
            mandatory = True,
            providers = [FlutterPubspecInfo],
            doc = "A flutter_pubspec target; supplies the package name.",
        ),
        "entrypoint": attr.label(
            allow_single_file = [".dart"],
            mandatory = True,
            doc = """The entrypoint, e.g. `lib/main.dart` or `integration_test/app_test.dart`.

A file under lib/ is compiled as `package:`. Any other .dart file -- in the
package, generated into bin_dir, or in another repository -- is compiled by its
execroot path under `org-dartlang-root:`.""",
        ),
        "dart_plugin_registrant": attr.label(
            allow_single_file = [".dart"],
            doc = """The generated Dart plugin registrant, e.g. `lib/dart_plugin_registrant.dart`.

See dart_aot_kernel.dart_plugin_registrant. Omit for an app with no federated plugins.""",
        ),
        "package_config": attr.label(
            allow_single_file = True,
            mandatory = True,
            doc = """The pub hub's `package_config.json`, read in place.

Every rootUri is relative to the hub, so the compile reads it through
`--filesystem-root`. It is a declared input.""",
        ),
        "pub_srcs": attr.label_list(
            allow_files = True,
            allow_empty = False,
            mandatory = True,
            doc = "The pub hub's `:lib`: every hosted package's packageUri tree, and `package_config.json`.",
        ),
        "path_deps": attr.label_list(
            allow_files = True,
            doc = "Sources of `path:` dependencies. See dart_aot_kernel.path_deps.",
        ),
        "dart_defines": attr.string_dict(
            doc = """Compile-time constants, passed as `-D<name>=<value>`.

Only const-evaluated reads see them; see dart_aot_kernel.dart_defines. They are in
the action key, so changing a value recompiles the kernel; an empty dict adds no
flags, so existing keys are unchanged.""",
        ),
    },
    toolchains = ["//flutter/private:flutter_toolchain_type"],
)

def _dart_aot_snapshot_impl(ctx):
    toolchain = _flutter_aot_toolchain(ctx)

    # Keep the toolchain's output basename under the target's directory. Different
    # targets can emit the same basename; the label path prevents duplicate outputs.
    artifact = ctx.actions.declare_file(ctx.label.name + "/" + toolchain.output_name)
    if ctx.file.dill == None:
        fail(
            "Target platform selection failed for label {} (slice {}): no AOT kernel is configured.".format(
                ctx.label,
                _flutter_target_toolchain(ctx).slice_id,
            ),
        )

    args = ctx.actions.args()

    # Deterministic output omits timestamps that would otherwise perturb caches.
    args.add("--deterministic")

    # gen_snapshot accepts these options only as --name=value.
    args.add("--snapshot_kind=" + toolchain.snapshot_kind)

    # armv7 requires compatibility flags provided by the target toolchain.
    args.add_all(_flutter_target_toolchain(ctx).snapshot_flags)
    args.add(artifact, format = toolchain.output_flag + "%s")
    if ctx.attr.strip and toolchain.strip_flag:
        args.add(toolchain.strip_flag)

    # Split-debug-info is deliberately not wired up. Without it the release
    # snapshot retains Dart's name table inline, so stack traces remain symbolic;
    # splitting trades that away for roughly 512 KB, which is not worthwhile here.
    args.add(ctx.file.dill)

    ctx.actions.run(
        executable = _flutter_aot_toolchain(ctx).gen_snapshot_release,
        arguments = [args],
        inputs = [ctx.file.dill],
        outputs = [artifact],
        mnemonic = "DartAotSnapshot",
        progress_message = "Generating AOT artifact %{label}",
    )
    return [
        DefaultInfo(files = depset([artifact])),
        FlutterAotSnapshotInfo(kind = toolchain.output_kind),
    ]

dart_aot_snapshot = rule(
    implementation = _dart_aot_snapshot_impl,
    doc = "Turns an AOT kernel into the artifact declared by its platform toolchain.",
    attrs = {
        "dill": attr.label(allow_single_file = [".dill"]),
        "strip": attr.bool(default = True),
    },
    toolchains = [
        "//flutter/private:flutter_target_toolchain_type",
        "//flutter/private:flutter_aot_toolchain_type",
    ],
)

def _pub_hub_labels(pub, who):
    """The hub labels a Dart rule takes from `pub = "@<hub>"`.

    Returns `(package_config, project_package_config, lib, all, lock, lock_dir)`.
    """
    if not pub or not pub.startswith("@") or "//" in pub or ":" in pub:
        fail((
            "{}: `pub` must be the repository of a `pub.lock` hub, e.g. \"@pub\" " +
            "(from `pub = use_extension(\"@rules_flutter_core//flutter:extensions.bzl\", \"pub\")`), got {}."
        ).format(who, repr(pub)))
    return (
        pub + "//:package_config.json",
        pub + "//:project_package_config.json",
        pub + "//:lib",
        pub + "//:all",
        pub + "//:pubspec.lock",
        pub + "//:lock_project_dir",
    )

def _lib_tier(ctx, pubspec):
    """Declares a package's lib tier, and the deps_lib its test kernels import.

    The tier is the package's lib/ libraries, compiled once against test_deps and so
    shared by the package's tests. lib_entry.py picks the libraries and writes their
    entrypoint; frontend_server writes one dill per package, joined main first as in
    jit_kernel_action. deps_lib is test_deps with the tier appended: the one
    --import-dill a test kernel takes, since frontend_server rejects two.

    A package with no lib/ sources has no tier: deps_lib is test_deps.
    """
    if not ctx.files.srcs:
        return ctx.file.test_deps

    toolchain = _flutter_toolchain(ctx)
    lib = ctx.actions.declare_file(ctx.label.name + "_lib.dill")
    deps_lib = ctx.actions.declare_file(ctx.label.name + "_deps_lib.dill")
    entry = ctx.actions.declare_file(ctx.label.name + "_lib_entry.dart")
    lib_list = ctx.actions.declare_file(ctx.label.name + "_lib_list.txt")
    pkg_dir = pubspec.src.short_path.rpartition("/")[0]
    prefix = pkg_dir + "/lib/" if pkg_dir else "lib/"
    entries = []
    for f in ctx.files.srcs:
        if not f.short_path.startswith(prefix):
            fail("{}: lib source {} is not under {}".format(ctx.label, f.short_path, prefix))
        entries.append(f.path + "\t" + f.short_path[len(prefix):])
    ctx.actions.write(lib_list, "\n".join(entries) + "\n")

    # The debug flags and line-table handling of jit_kernel_action, with the hub's
    # test deps as the import.
    args = ctx.actions.args()
    args.add(toolchain.dartaotruntime)
    args.add(toolchain.frontend_server)
    args.add("--sdk-root", _sdk_root_for(toolchain.platform_debug, "debug") + "/")
    args.add("--target", "flutter")
    args.add("--no-print-incremental-dependencies")
    args.add_all(_DEBUG_KERNEL_FLAGS)
    args.add("--import-dill", ctx.file.test_deps)
    args.add("--split-output-by-packages")
    args.add("--no-embed-source-text")
    args.add("--filesystem-root", ".")
    args.add("--filesystem-root", ctx.bin_dir.path)
    args.add("--filesystem-scheme", "org-dartlang-root")
    args.add("--packages", "org-dartlang-root:///" + ctx.file.package_config.path)

    scalars = ctx.actions.args()
    scalars.add(pubspec.package_name)
    scalars.add(ctx.file.package_config)
    scalars.add(pubspec.src.path.rpartition("/")[0] or ".")
    scalars.add(entry)
    scalars.add("org-dartlang-root:///" + _execroot_path(entry))
    scalars.add(lib_list)
    scalars.add(lib)
    scalars.add(deps_lib)
    scalars.add(ctx.file.test_deps)
    scalars.add(ctx.file._lib_entry)

    ctx.actions.run_shell(
        command = """set -euo pipefail
NAME_FILE="$1"; shift
CONFIG="$1"; shift
PKG_DIR="$1"; shift
ENTRY="$1"; shift
ENTRY_URI="$1"; shift
LIST="$1"; shift
LIB="$1"; shift
DEPS_LIB="$1"; shift
DEPS="$1"; shift
GEN="$1"; shift

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
python3 "$GEN" "$NAME_FILE" "$CONFIG" "$PKG_DIR" "$ENTRY" "$LIST"
"$@" --output-dill "$WORK/lib.dill" "$ENTRY_URI"
if [ -f "$WORK/lib.dill-packages" ]; then
    {
        cat "$WORK/lib.dill-main.dilp"
        while read -r pkg; do
            if [ "$pkg" != main ]; then cat "$WORK/lib.dill-$pkg.dilp"; fi
        done < "$WORK/lib.dill-packages"
    } > "$LIB"
else
    cat "$WORK/lib.dill" > "$LIB"
fi
cat "$DEPS" "$LIB" > "$DEPS_LIB"
""",
        arguments = [scalars, args],
        tools = [toolchain.dartaotruntime],
        inputs = depset(
            direct = [
                toolchain.frontend_server,
                toolchain.sdk_version,
                ctx.file.package_config,
                pubspec.package_name,
                ctx.file.test_deps,
                ctx.file._lib_entry,
                lib_list,
            ] + ctx.files.srcs + ctx.files.pub_srcs + ctx.files.path_deps,
            transitive = [
                depset(toolchain.platform_debug),
                toolchain.sdk_packages,
            ],
        ),
        outputs = [lib, deps_lib, entry],
        mnemonic = "DartLibKernel",
        progress_message = "Compiling lib kernel %{label}",
    )
    return deps_lib

def _flutter_package_impl(ctx):
    assets = ctx.attr.assets[DefaultInfo].files.to_list() if ctx.attr.assets else []
    if len(assets) > 1:
        fail("{}: assets must be one flutter_assets directory, got {} files".format(ctx.label, len(assets)))
    pubspec = ctx.attr.pubspec[FlutterPubspecInfo]
    deps_lib = _lib_tier(ctx, pubspec)
    validation = pub_path_deps_check_action(
        ctx,
        ctx.actions.declare_file(ctx.label.name + ".path_deps.checked"),
        ctx.file.pubspec_lock,
        ctx.files.path_deps,
        ctx.file._checker,
        ctx.file.lock_project_dir,
    )
    validations = [validation]
    if ctx.file.registrant:
        validations.append(pub_plugins_check_action(
            ctx,
            ctx.actions.declare_file(ctx.label.name + ".registrant.checked"),
            ctx.file.registrant,
            ctx.file.expected_registrant,
            ctx.attr.registrant_updater,
        ))
    return [
        OutputGroupInfo(_validation = depset(validations)),
        FlutterPackageInfo(
            pubspec = pubspec,
            srcs = ctx.files.srcs,
            package_config = ctx.file.package_config,
            test_deps = ctx.file.test_deps,
            deps_lib = deps_lib,
            pub_srcs = ctx.files.pub_srcs,
            path_deps = ctx.files.path_deps,
            assets = assets[0] if assets else None,
        ),
    ]

_flutter_package = rule(
    implementation = _flutter_package_impl,
    doc = "Declares a Dart package's inputs to host tests. See flutter_package.",
    attrs = {
        "pubspec_lock": attr.label(allow_single_file = True, mandatory = True),
        "lock_project_dir": attr.label(allow_single_file = True, mandatory = True),
        "_checker": attr.label(
            default = "//flutter/private:check_path_deps.py",
            allow_single_file = True,
        ),
        "pubspec": attr.label(
            mandatory = True,
            providers = [FlutterPubspecInfo],
            doc = "The package's flutter_pubspec target.",
        ),
        "srcs": attr.label_list(
            allow_files = [".dart"],
            doc = "The package's lib/ Dart sources.",
        ),
        "package_config": attr.label(
            allow_single_file = True,
            mandatory = True,
            doc = "The pub hub's `package_config.json`.",
        ),
        "test_deps": attr.label(
            allow_single_file = True,
            mandatory = True,
            doc = "The pub hub's test deps kernel, from dart_test_deps.",
        ),
        "pub_srcs": attr.label_list(
            allow_files = True,
            allow_empty = False,
            mandatory = True,
            doc = "The pub hub's `:lib`.",
        ),
        "path_deps": attr.label_list(
            allow_files = True,
            doc = "Sources of `path:` dependencies. See dart_aot_kernel.path_deps.",
        ),
        "assets": attr.label(
            doc = "A flutter_assets directory, passed to tests as --flutter-assets-dir.",
        ),
        "registrant": attr.label(allow_single_file = [".dart"]),
        "expected_registrant": attr.label(allow_single_file = [".dart"]),
        "registrant_updater": attr.label(),
        "_lib_entry": attr.label(
            default = "//flutter/private:lib_entry.py",
            allow_single_file = True,
        ),
    },
    toolchains = ["//flutter/private:flutter_toolchain_type"],
)

def flutter_package(name, pub, pubspec, srcs = None, path_deps = [], assets = None, **kwargs):
    """The inputs a host test reads from a Dart package, with no app build.

    Declares no app build. `flutter_core` declares a core artifact; a package
    without an app declares a pubspec and package by hand, as the conformance
    suite does:

        flutter_pubspec(name = "pubspec")
        flutter_package(name = "pkg", pub = "@pub", pubspec = ":pubspec")

    `pub` is the `pub.lock` hub of the package's dependencies.

    Args:
      name: the target's name.
      pub: the `pub.lock` hub repository, e.g. `"@pub"`.
      pubspec: the package's flutter_pubspec target.
      srcs: the package's lib/ Dart sources. Defaults to `glob(["lib/**/*.dart"])`.
      path_deps: sources of `path:` dependencies; checked against the pub hub's lock during build validation.
      assets: a flutter_assets target, passed to tests as --flutter-assets-dir.
      **kwargs: visibility, tags.
    """
    flutter_package_targets(name, pub, pubspec, srcs, path_deps, assets, registrant_check = None, **kwargs)

def flutter_package_targets(name, pub, pubspec, srcs = None, path_deps = [], assets = None, registrant_check = None, **kwargs):
    """Declare package targets, with optional validation for flutter_core.

    Args:
      name: the target's name.
      pub: the pub.lock hub repository.
      pubspec: the package's flutter_pubspec target.
      srcs: Dart sources for the package.
      path_deps: declared source files for path dependencies.
      assets: the flutter_assets target.
      registrant_check: optional (committed, expected, updater) labels.
      **kwargs: attributes passed to the declared package target.
    """
    package_config, _, pub_lib, _, pubspec_lock, lock_project_dir = _pub_hub_labels(pub, "flutter_package " + name)
    if srcs == None:
        srcs = native.glob(["lib/**/*.dart"])

    _flutter_package(
        name = name,
        pubspec_lock = pubspec_lock,
        lock_project_dir = lock_project_dir,
        pubspec = pubspec,
        srcs = srcs,
        package_config = package_config,
        test_deps = pub + "//:test_deps",
        pub_srcs = [pub_lib],
        path_deps = path_deps,
        assets = assets,
        registrant = registrant_check[0] if registrant_check else None,
        expected_registrant = registrant_check[1] if registrant_check else None,
        registrant_updater = registrant_check[2] if registrant_check else None,
        **kwargs
    )

def _bundle_dir(out, slice_id, index):
    """Where one target slice's bundle goes.

    The first is the declared output itself, so shared files are written once.
    Other slices use action-local scratch for comparison and manifest reading.
    """
    if index == 0:
        return "$EXECROOT/{}".format(out.path)
    return "$STAGE/bundles/{}".format(slice_id)

def _bundle_command(out, slice_id, index, target_platform):
    # `flutter_tool` (defined in the action preamble) runs the tool's snapshot
    # directly: bin/flutter writes engine.stamp into the SDK, which a sandbox
    # forbids. `--no-version-check` skips the update check, which runs `git fetch`
    # and writes a stamp in the SDK.
    #
    # Always --release, whatever //flutter:mode says: the stub fixes the project
    # directory, and record-use compiles only its closure (no app lib/), so the
    # bundle is the same under every mode.
    return """flutter_tool --no-version-check build bundle \
    --release \
    --no-pub \
    --target="$STUB" \
    --target-platform={platform} \
    --asset-dir="{dir}" \
    --suppress-analytics >/dev/null
rm -f "{dir}/.last_build_id"
rm -rf "{dir}/native_assets"
""".format(
        platform = target_platform,
        dir = _bundle_dir(out, slice_id, index),
    )

def _stage_flutter_assets(ctx, toolchain, platform_env):
    """Declares a flutter_assets bundle's inputs and stages them for flutter_tools.

    The application bundle and the tester bundle read the same files, so both stage
    them here. Returns the declared files, the manifest that lists them, and the
    shell that stages them and leaves it in the project root with FLUTTER_ROOT
    set. platform_env is shell that exports the platform's environment, if any.
    """

    # Every file the bundle can read is staged and declared.
    files = (
        [
            ctx.file.package_config,
            ctx.attr.pubspec[FlutterPubspecInfo].src,
        ] +
        ctx.files.assets +
        ctx.files.path_deps + ctx.files.pub_srcs + toolchain.sdk_packages.to_list()
    )

    # The set of files to stage, one execroot-relative path per line. Written to
    # a file rather than passed as arguments so the command cannot overflow the
    # argument limit on a large app.
    manifest = ctx.actions.declare_file(ctx.label.name + ".stage_manifest")
    ctx.actions.write(
        manifest,
        "".join([f.path + "\n" for f in files]),
    )

    # Stage project inputs so flutter_tools writes transient state outside the
    # source tree. Preserve execroot-relative paths: package_config.json uses
    # them to resolve relative path dependencies.
    #
    # Stream the manifest through tar to avoid an argument-size limit and
    # per-file process overhead. Sources may be read-only, hence chmod.
    #
    # --no-pub keeps dependency resolution and network access outside this
    # Bazel action.
    #
    # flutter_tools bookkeeping is nondeterministic, so remove it from the tree
    # artifact.
    project_dir = "/".join([
        component
        for component in [ctx.label.workspace_root, ctx.label.package]
        if component
    ])

    flutter_root = """FLUTTER_REAL="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$EXECROOT/{launcher}")"
export FLUTTER_ROOT="$(dirname "$(dirname "$FLUTTER_REAL")")"
""".format(launcher = toolchain.flutter.path)

    command = """set -euo pipefail
EXECROOT="$PWD"
export PATH="/usr/bin:/bin"
{platform_env}export FLUTTER_ALREADY_LOCKED="true"
# Refuse what this bundle does not model, before any flutter_tools work.
python3 "$EXECROOT/{bundle_guard}" --pubspec "$EXECROOT/{pubspec}"
STAGE="$(mktemp -d "${{TMPDIR:-/tmp}}/flutter_assets.XXXXXX")"
trap 'rm -rf "$STAGE" "$STAGE.tar"' EXIT
# flutter_tools needs writable state; use a stage-local HOME so the host HOME
# does not affect the action key.
export HOME="$STAGE/home"
mkdir -p "$HOME"

# Archive to a file rather than a pipe, so the writer cannot fail when the
# reader exits early.
tar -cf "$STAGE.tar" -T "{manifest}"
(cd "$STAGE" && tar -xf "$STAGE.tar")
rm -f "$STAGE.tar"
chmod -R u+w "$STAGE"
{place_config}
{flutter_root}cd "$STAGE/{project_dir}"
""".format(
        platform_env = platform_env,
        bundle_guard = ctx.file._bundle_guard.path,
        pubspec = ctx.attr.pubspec[FlutterPubspecInfo].src.path,
        manifest = manifest.path,
        place_config = (
            'mkdir -p "$STAGE/{d}.dart_tool" && cp "$EXECROOT/{c}" "$STAGE/{d}.dart_tool/package_config.json"\n' +
            'cp "$EXECROOT/{g}" "$STAGE/{d}.dart_tool/package_graph.json"\n'
        ).format(
            d = project_dir + "/" if project_dir else "",
            c = ctx.file.package_config.path,
            g = ctx.file.package_config.dirname + "/package_graph.json",
        ),
        flutter_root = flutter_root,
        project_dir = project_dir,
    )
    return struct(files = files, manifest = manifest, command = command)

# What a native build hook needs from its environment. `exports` is shell text run
# before the hook; `files` are the inputs that text reads, so the action running it
# must depend on them.
FlutterNativeBuildEnvInfo = provider(
    doc = "Shell exports and input files a native build environment provides.",
    fields = {
        "exports": "String: newline-terminated shell statements, or empty.",
        "files": "depset of File: inputs the exports read.",
    },
)

def _flutter_assets_impl(ctx):
    # The directory must be named flutter_assets: consumers derive the
    # runtime path from the artifact path with assets_dir stripped, and Flutter
    # requires the bundle at assets/flutter_assets/ at runtime.
    out = ctx.actions.declare_directory(ctx.label.name + "/flutter_assets")

    toolchain = _flutter_toolchain(ctx)
    build_env = ctx.attr.native_build_env[FlutterNativeBuildEnvInfo] if ctx.attr.native_build_env else None
    staged = _stage_flutter_assets(ctx, toolchain, build_env.exports if build_env else "")
    hook_packages = None
    for target in ctx.attr.pub_srcs:
        if FlutterHookPackagesInfo in target:
            hook_packages = target[FlutterHookPackagesInfo]
            break
    if build_env == None and hook_packages:
        missing_env_packages = staged_hook_packages(
            hook_packages.package_dirs,
            [file.path for file in staged.files],
        )
        if missing_env_packages:
            fail(
                "{}: native_build_env is required because staged package `{}` declares hook/build.dart".format(
                    ctx.label,
                    missing_env_packages[0],
                ),
            )

    target_slices = [
        slice
        for target in ctx.attr.target_slices
        for slice in target[FlutterTargetSlicesInfo].slices
    ]
    if not target_slices:
        fail("{}: flutter_assets requires at least one target slice.".format(ctx.label))
    for target_slice in target_slices:
        if not target_slice.slice_id or not target_slice.target_platform:
            fail("{}: flutter_assets has no Flutter target toolchain for slice metadata.".format(ctx.label))

    # Code assets belong in platform native libraries, not the asset tree.
    # Packaging recipes install them in native library directories; discard
    # flutter_tools' duplicate. NativeAssetsManifest.json stays beside the bundle for runtime lookup.
    cmd = staged.command + """# flutter_tools takes the project directory as two levels above --target, so
# the stub sits in its own directory. It is compiled only for record-use and
# imports nothing.
mkdir -p .flutter_bazel
printf 'void main() {{}}\\n' > .flutter_bazel/stub.dart
STUB=".flutter_bazel/stub.dart"
mkdir -p "$STAGE/bundles"
flutter_tool() {{
    "$FLUTTER_ROOT/bin/cache/dart-sdk/bin/dart" --packages="$FLUTTER_ROOT/packages/flutter_tools/.dart_tool/package_config.json" "$EXECROOT/{snapshot}" "$@"
}}
{bundles}
# Keep the shell alive so its EXIT trap removes STAGE after the merger.
python3 "$EXECROOT/{merger}" {merge_args}
""".format(
        snapshot = toolchain.tools_snapshot.path,
        merger = ctx.file._merger.path,
        bundles = "\n".join([
            _bundle_command(
                out,
                target_slice.slice_id,
                i,
                target_slice.target_platform,
            )
            for i, target_slice in enumerate(target_slices)
        ]),
        merge_args = " ".join([
            '--bundle "{}={}"'.format(
                target_slice.slice_id,
                _bundle_dir(out, target_slice.slice_id, i),
            )
            for i, target_slice in enumerate(target_slices)
        ]),
    )

    ctx.actions.run_shell(
        command = cmd,
        inputs = depset(
            direct = staged.files + [staged.manifest, toolchain.sdk_version, ctx.file._merger, ctx.file._bundle_guard, toolchain.flutter, toolchain.tools_snapshot],
            transitive = [build_env.files] if build_env else [],
        ),
        outputs = [out],
        mnemonic = "FlutterAssets",
        progress_message = "Bundling Flutter assets %{label}",
        execution_requirements = _ASSETS_EXEC,
    )

    return [DefaultInfo(files = depset([out]))]

flutter_assets = rule(
    implementation = _flutter_assets_impl,
    doc = """Produces a flutter_assets/ tree (AssetManifest.bin, FontManifest.json,
NOTICES.Z, fonts, shaders, declared assets) for packaging into an APK.

Mode-independent, and free of app Dart: it takes no sources, entrypoint or kernel, and
its action key is the same under every `//flutter:mode`. flutter_tools still compiles the
stub's package closure for record-use, so SDK and pub/path `.dart` are inputs; app `lib/`
is not. The debug kernel and snapshots are not part of it: the core's debug
asset bundle adds them.

It fails, when the action runs, on a pubspec with `deferred-components:` or an
asset `transformers:`: rules_flutter supports neither.

The action runs `flutter build bundle --release` against a generated stub
entrypoint, because flutter_tools derives the project directory from `--target`.
That is an interim mechanism: the standalone-asset-bundle epic replaces the
action's internals, not this interface.""",
    attrs = {
        "assets": attr.label_list(
            allow_files = True,
            doc = "Files declared under `assets:` in pubspec.yaml.",
        ),
        "pubspec": attr.label(
            mandatory = True,
            providers = [FlutterPubspecInfo],
            doc = """A flutter_pubspec target.

`flutter build bundle` parses the pubspec itself -- assets, fonts and
uses-material-design all come from it -- so this rule stages the file rather
than a fact read out of it.""",
        ),
        "package_config": attr.label(
            allow_single_file = True,
            mandatory = True,
            doc = """The pub hub's `project_package_config.json`, staged as the project's
`.dart_tool/package_config.json`. Its rootUris are relative to that directory.""",
        ),
        "pub_srcs": attr.label_list(
            allow_files = True,
            allow_empty = False,
            mandatory = True,
            doc = "The pub hub's `:all`: hosted package files and `package_graph.json`.",
        ),
        "path_deps": attr.label_list(
            allow_files = True,
            doc = "Sources of `path:` dependencies, staged and declared. See dart_aot_kernel.path_deps.",
        ),
        "target_slices": attr.label_list(
            mandatory = True,
            providers = [FlutterTargetSlicesInfo],
            doc = """Target slices to bundle for. Required, always a list.

`flutter build bundle` runs once per target slice inside this action, because
NativeAssetsManifest.json is keyed by target architecture. The manifests are
merged and everything else is compared, so an architecture-varying bundle fails
instead of shipping.""",
        ),
        "native_build_env": attr.label(
            providers = [FlutterNativeBuildEnvInfo],
            doc = """The native build environment: shell exports and the input files they read,
provided by a platform-specific native build environment rule. Omit it for a
build that has no native SDK.""",
        ),
        "_merger": attr.label(
            default = "//flutter/private:merge_native_assets.py",
            allow_single_file = True,
        ),
        "_bundle_guard": attr.label(
            default = "//flutter/private:check_bundle_pubspec.py",
            allow_single_file = True,
        ),
    },
    toolchains = ["//flutter/private:flutter_toolchain_type"],
)

def _flutter_test_assets_impl(ctx):
    # Native build hooks do not run here, so the bundle carries no
    # native-library outputs and no NativeAssetsManifest.json.
    out = ctx.actions.declare_directory(ctx.label.name + "/flutter_assets")

    toolchain = _flutter_toolchain(ctx)
    staged = _stage_flutter_assets(ctx, toolchain, "")
    cmd = staged.command + """"$EXECROOT/{dart}" "$EXECROOT/{builder}" "$EXECROOT/{out}"
""".format(
        dart = toolchain.dart.path,
        builder = ctx.file._builder_dill.path,
        out = out.path,
    )

    ctx.actions.run_shell(
        command = cmd,
        inputs = depset(
            direct = staged.files + [staged.manifest, toolchain.sdk_version, toolchain.flutter, toolchain.dart, toolchain.dart_sdk_revision, toolchain.vm_platform_strong, ctx.file._bundle_guard, ctx.file._builder_dill],
        ),
        outputs = [out],
        mnemonic = "FlutterTestAssets",
        progress_message = "Bundling test assets %{label}",
        execution_requirements = _ASSETS_EXEC,
    )

    return [DefaultInfo(files = depset([out]))]

flutter_test_assets = rule(
    implementation = _flutter_test_assets_impl,
    doc = """The asset bundle host tests read, built for flutter_tester's platform.

Takes the flutter_assets inputs (pubspec, package config, pub hub, declared assets,
path dependencies), but no target slices or native SDK. Built through flutter_tools'
AssetBundle and writeBundle with TargetPlatform.tester, as `flutter test` builds it:
`flutter build bundle` does not accept that platform.""",
    attrs = {
        "assets": attr.label_list(
            allow_files = True,
            doc = "Files declared under `assets:` in pubspec.yaml.",
        ),
        "pubspec": attr.label(
            mandatory = True,
            providers = [FlutterPubspecInfo],
            doc = "A flutter_pubspec target. See flutter_assets.",
        ),
        "package_config": attr.label(
            allow_single_file = True,
            mandatory = True,
            doc = "The pub hub's `project_package_config.json`. See flutter_assets.",
        ),
        "pub_srcs": attr.label_list(
            allow_files = True,
            allow_empty = False,
            mandatory = True,
            doc = "The pub hub's `:all`. See flutter_assets.",
        ),
        "path_deps": attr.label_list(
            allow_files = True,
            doc = "Sources of `path:` dependencies. See flutter_assets.",
        ),
        "_bundle_guard": attr.label(
            default = "//flutter/private:check_bundle_pubspec.py",
            allow_single_file = True,
        ),
        "_builder_dill": attr.label(
            default = "//flutter/private:tester_assets_dill",
            allow_single_file = True,
        ),
    },
    toolchains = ["//flutter/private:flutter_toolchain_type"],
)

def pub_path_deps_check_action(ctx, marker, pubspec_lock, path_deps, checker, lock_project_dir = None, expected_path_deps = None):
    """Declares a validation action for a package's path dependencies.

    Args:
      ctx: the rule context.
      marker: the validation output file.
      pubspec_lock: the package's lock file.
      path_deps: declared source files for path dependencies.
      checker: the path dependency checker script.
      lock_project_dir: directory containing the pub hub lock, when different from this package.
      expected_path_deps: optional JSON list of path dependencies reachable from this package.

    Returns:
      The validation marker output.
    """
    args = ctx.actions.args()
    args.add(checker)
    args.add("--lock", pubspec_lock)
    package_dir = paths.join(ctx.label.workspace_root, ctx.label.package)
    if lock_project_dir:
        args.add("--package-dir-file", lock_project_dir)
    else:
        args.add("--package-dir", package_dir)
    if expected_path_deps:
        args.add("--expected-path-deps", expected_path_deps)
    args.add("--out", marker)
    args.add_all("--declared", path_deps)

    # Bazel 9 has no native py_binary and rules_python is not worth a dependency
    # for one check script, so invoke the interpreter directly.
    # run_shell reserves $0; the argument vector begins at $1.
    ctx.actions.run_shell(
        command = 'exec python3 "$@"',
        arguments = [args],
        inputs = [pubspec_lock, checker] + ([lock_project_dir] if lock_project_dir else []) + ([expected_path_deps] if expected_path_deps else []) + path_deps,
        outputs = [marker],
        mnemonic = "PubPathDepsCheck",
        progress_message = "Checking path: dependencies %{label}",
    )
    return marker

def _pub_path_deps_check_impl(ctx):
    marker = ctx.actions.declare_file(ctx.label.name + ".checked")
    pub_path_deps_check_action(ctx, marker, ctx.file.pubspec_lock, ctx.files.path_deps, ctx.file._checker)
    return [DefaultInfo(files = depset([marker]))]

pub_path_deps_check = rule(
    implementation = _pub_path_deps_check_impl,
    doc = """Fails the build if a `path:` dependency is not declared in path_deps.

The `flutter_core` and `flutter_package` macros run this validation automatically.
Use this target to check a `pubspec.lock` that is not owned by either macro.""",
    attrs = {
        "pubspec_lock": attr.label(allow_single_file = True, mandatory = True),
        "path_deps": attr.label_list(allow_files = True),
        "_checker": attr.label(
            default = "//flutter/private:check_path_deps.py",
            allow_single_file = True,
        ),
    },
)

def pub_plugins_check_action(ctx, marker, committed, expected, updater_target):
    """Check the committed generated Dart registrant and expose a marker on match.

    Args:
      ctx: action context for the owning target.
      marker: output file touched when the registrant matches.
      committed: checked-in Dart registrant.
      expected: generated Dart registrant.
      updater_target: optional target that regenerates the registrant.

    Returns:
      The marker output file.
    """
    updater = ""
    if updater_target:
        updater_label = updater_target.label
        updater = (
            "//{}:{}".format(updater_label.package, updater_label.name) if updater_label.repo_name == ctx.label.repo_name else str(updater_label)
        )

    ctx.actions.run_shell(
        command = """
set -eu
expected="$1"; committed="$2"; marker="$3"; updater="$4"
if ! diff -u "$committed" "$expected" > /dev/null 2>&1; then
    echo "ERROR: $committed is out of date." >&2
    echo "Replace it with the generated file:" >&2
    sed 's/^/    /' "$expected" >&2
    if [[ -n "$updater" ]]; then
        echo "To regenerate it, run:" >&2
        echo "    bazel run $updater" >&2
    fi
    diff -u "$committed" "$expected" >&2 || true
    exit 1
fi
touch "$marker"
""",
        arguments = [
            expected.path,
            committed.path,
            marker.path,
            updater,
        ],
        inputs = [expected, committed],
        outputs = [marker],
        mnemonic = "PubFileCheck",
        progress_message = "Checking generated pub file %{label}",
    )
    return marker

def _pub_plugins_check_impl(ctx):
    marker = ctx.actions.declare_file(ctx.label.name + ".checked")
    pub_plugins_check_action(ctx, marker, ctx.file.committed, ctx.file.expected, ctx.attr.updater)
    return [DefaultInfo(files = depset([marker]))]

pub_plugins_check = rule(
    implementation = _pub_plugins_check_impl,
    doc = "Fails when a committed file differs from the file generated by the pub hub.",
    attrs = {
        "committed": attr.label(
            allow_single_file = True,
            mandatory = True,
            doc = "The checked-in generated file.",
        ),
        "expected": attr.label(
            allow_single_file = True,
            mandatory = True,
            doc = "The generated file from the pub hub.",
        ),
        "updater": attr.label(
            doc = "Optional updater command to print when this guard drifts.",
        ),
    },
)
