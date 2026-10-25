"""Rules for the Dart half of a Flutter build.

The Flutter build decomposes into two independent halves:

  1. Dart:     .dart sources -> app.dill (kernel) -> libapp.so (AOT ELF)
  2. Platform: libapp.so + libflutter.so + flutter_assets -> APK/IPA

These rules cover half 1 only, producing a plain `cc`-consumable .so that
rules_android / rules_apple can package in half 2. Nothing here shells out to
`flutter build`; the underlying frontend_server and gen_snapshot are driven
directly.

Half 2 is per-platform and is not loaded from here: see android.bzl. Keeping
them apart is what lets a consumer load only the platforms they build.

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

load("@bazel_skylib//lib:shell.bzl", "shell")
load("@bazel_skylib//rules:build_test.bzl", "build_test")
load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load(":abis.bzl", "ABIS", "aot_target_compatible_with", "check_abis")
load(":pubspec.bzl", "FlutterPubspecInfo", "flutter_pubspec")

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

def _library_path(ctx, file, attribute):
    """A source file's path within its package, as a `package:` URI suffix.

    `package:<name>/x.dart` resolves to `lib/x.dart`, so the URI carries the
    path under lib/ and nothing else. Taking it from a label rather than asking
    for the URI is what keeps the package name out of BUILD files -- and a
    typo fails here instead of producing a URI that resolves to nothing.
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

def _dart_entry_uri(ctx, file):
    """A debug entrypoint's frontend_server URI, as a `(scheme, path)` pair.

    A file under this package's lib/ is a `package:` library, which is how the
    engine and the plugin registrant address it in release too. Any other .dart
    file -- an integration_test/ or test/ file, or a bootstrap generated into
    bin_dir -- is addressed by its execroot path under org-dartlang-root, which
    resolves through whichever virtual root holds it. The URI never names bin_dir,
    so the kernel does not depend on the configuration that built it.
    """
    root = "../{}/".format(ctx.label.repo_name) if ctx.label.repo_name else ""
    lib = root + (ctx.label.package + "/" if ctx.label.package else "") + "lib/"
    if file.short_path.startswith(lib):
        return ("package", file.short_path[len(lib):])
    return ("org-dartlang-root", _execroot_path(file))

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

# `--source`/`-D` triple that compiles a federated plugin's generated Dart
# registrant into the kernel and makes the engine's `dart_plugin_registrant`
# lookup match the exact package: URI frontend_server recorded for it -- see
# the comment on `pubspec` below for why it must be a package: URI. Shared,
# verbatim, by dart_aot_kernel and dart_jit_kernel (formatted with shell variable
# names, resolved at run time).
_REGISTRANT_SOURCE_ARGS = '--source "package:{pkg}/{registrant}" --source "package:flutter/src/dart_plugin_registrant.dart" "-Dflutter.dart_plugin_registrant=package:{pkg}/{registrant}"'

def _flutter_toolchain(ctx):
    return ctx.toolchains["//flutter/private:flutter_toolchain_type"].flutter

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

    if ctx.attr.target_os:
        args.add("--target-os", ctx.attr.target_os)
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

    # The package name is file content, so the URIs cannot be built here -- an
    # attribute is read at analysis and a file is read at execution. The two
    # library paths are assembled against it by the wrapper below.
    scalars = ctx.actions.args()
    scalars.add(pubspec.package_name)
    scalars.add(_library_path(ctx, ctx.file.entrypoint, "entrypoint"))
    scalars.add(
        _library_path(ctx, ctx.file.dart_plugin_registrant, "dart_plugin_registrant") if ctx.file.dart_plugin_registrant else "",
    )
    scalars.add(dill)

    ctx.actions.run_shell(
        command = """set -euo pipefail
PKG="$(cat "$1")"; shift
ENTRYPOINT="$1"; shift
REGISTRANT="$1"; shift
DILL="$1"; shift

if [ -n "$REGISTRANT" ]; then
    set -- "$@" {registrant_args}
fi

exec "$@" --output-dill "$DILL" "package:$PKG/$ENTRYPOINT"
""".format(registrant_args = _REGISTRANT_SOURCE_ARGS.format(pkg = "$PKG", registrant = "$REGISTRANT")),
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
        "target_os": attr.string(
            default = "android",
            values = ["android", "ios", "macos", "linux", "windows", "fuchsia", ""],
            doc = """Target OS for `--target-os`, or "" to omit the flag.

Release-only: flutter_tools passes it under `--aot` alone.

""",
        ),
        "dart_defines": attr.string_dict(
            doc = """Compile-time constants, passed as `-D<name>=<value>`.

Only const-evaluated reads see them: `const String.fromEnvironment("FOO")` (likewise
`bool`/`int.fromEnvironment`). A non-const call is evaluated by the VM, which does
not get these values, and returns the default. They are in the action key, so
changing a value recompiles the kernel; an empty dict adds no flags, so existing
keys are unchanged.""",
        ),
    },
    toolchains = ["//flutter/private:flutter_toolchain_type"],
)

# A test kernel's undeclared import is absent from the sandbox, so the frontend
# reports it as not found. The hint says where the file has to be declared.
_TEST_IMPORT_HINT = "hint: declare test-local imports in `srcs`"

def _jit_kernel_action(ctx, dill, pkg, entrypoint, dart_defines, hint, mnemonic, what):
    """Declares the debug kernel action of dart_jit_kernel and dart_test_kernel.

    `pkg` is a struct of the package's inputs: package_name, package_config,
    pub_srcs, path_deps, srcs, registrant, registrant_path, and import_dill, the
    kernel to import with --import-dill, or None.
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
    scheme, path = _dart_entry_uri(ctx, entrypoint)

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
            registrant_args = _REGISTRANT_SOURCE_ARGS.format(pkg = "$PKG", registrant = "$REGISTRANT"),
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

    _jit_kernel_action(
        ctx,
        dill = dill,
        pkg = struct(
            package_name = pubspec.package_name,
            package_config = ctx.file.package_config,
            pub_srcs = ctx.files.pub_srcs,
            path_deps = ctx.files.path_deps,
            srcs = ctx.files.srcs,
            registrant = registrant,
            registrant_path = _library_path(ctx, registrant, "dart_plugin_registrant") if registrant else "",
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
    args.add("--error-hint", _TEST_IMPORT_HINT)
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
        _jit_kernel_action(
            ctx,
            dill = dill,
            pkg = pkg,
            entrypoint = ctx.file.entrypoint,
            dart_defines = ctx.attr.dart_defines,
            hint = _TEST_IMPORT_HINT,
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
    scalars.add_joined(ctx.attr.packages, join_with = " ")
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

def _dart_aot_elf_impl(ctx):
    # Under the target name, not at the package root. The basename is fixed --
    # the engine's Dart_LoadELF is given "libapp.so" by the embedder, and
    # jni_lib_jar packages whatever basename it is handed -- so the target name
    # is the only thing left to disambiguate with. Two targets in one package
    # (two ABIs, or Android beside iOS) both declaring `libapp.so` at the root
    # is a duplicate-output analysis error.
    so = ctx.actions.declare_file(ctx.label.name + "/libapp.so")

    args = ctx.actions.args()

    # --deterministic is what makes this output byte-stable across runs, and
    # therefore safe to cache. Verified: identical sha256 over repeat builds.
    args.add("--deterministic")
    args.add("--snapshot_kind=app-aot-elf")
    args.add_all(ctx.attr.snapshot_flags)

    # gen_snapshot only accepts the --flag=value form here; a space-separated
    # pair makes it print usage and exit non-zero.
    args.add(so, format = "--elf=%s")
    if ctx.attr.strip:
        args.add("--strip")

    # Note Flutter's --split-debug-info (--save-debugging-info plus
    # --dwarf-stack-traces) is deliberately not wired up. Without it a release
    # snapshot keeps Dart's name table inline, so stack traces are already
    # symbolic; the flag trades that away for ~512 KB. Not worth it here.
    args.add(ctx.file.dill)

    ctx.actions.run(
        executable = _flutter_toolchain(ctx).gen_snapshots["{}_{}".format(
            ctx.attr.abi,
            ctx.attr._mode[BuildSettingInfo].value,
        )],
        arguments = [args],
        inputs = [ctx.file.dill],
        outputs = [so],
        mnemonic = "DartAotElf",
        progress_message = "Generating AOT ELF %{label}",
    )

    return [DefaultInfo(files = depset([so]))]

dart_aot_elf = rule(
    implementation = _dart_aot_elf_impl,
    doc = "Turns a kernel .dill into a stripped AOT libapp.so via gen_snapshot.",
    attrs = {
        "dill": attr.label(
            allow_single_file = [".dill"],
            mandatory = True,
        ),
        "strip": attr.bool(
            default = True,
            doc = "Drop DWARF debug info from the ELF.",
        ),
        "abi": attr.string(
            mandatory = True,
            values = sorted(ABIS.keys()),
        ),
        "_mode": attr.label(
            default = "//flutter:mode",
            providers = [BuildSettingInfo],
        ),
        "snapshot_flags": attr.string_list(
            doc = """Extra gen_snapshot flags for this ABI.

Table-driven rather than derived here: armv7 is the only ABI that needs any,
and omitting them yields a snapshot that installs and then executes an
unsupported instruction.""",
        ),
    },
    toolchains = ["//flutter/private:flutter_toolchain_type"],
)

def _pub_hub_labels(pub, who):
    """The hub labels a Dart rule takes from `pub = "@<hub>"`.

    Returns `(package_config, project_package_config, lib, all)`.
    """
    if not pub or not pub.startswith("@") or "//" in pub or ":" in pub:
        fail((
            "{}: `pub` must be the repository of a `pub.lock` hub, e.g. \"@pub\" " +
            "(from `pub = use_extension(\"@rules_flutter//flutter:extensions.bzl\", \"pub\")`), got {}."
        ).format(who, repr(pub)))
    return (
        pub + "//:package_config.json",
        pub + "//:project_package_config.json",
        pub + "//:lib",
        pub + "//:all",
    )

def flutter_aot_library(name, srcs, abis, pubspec, entrypoint, pub, path_deps = [], dart_plugin_registrant = None, target_os = "android", strip = True, dart_defines = {}, **kwargs):
    """Convenience wrapper: Dart sources straight through to libapp.so.

    Produces an AOT-shaped `.dill` and its `libapp.so` per ABI. The kernel is
    `dart_aot_kernel`, which compiles `--aot --tfa` only. Both it and each
    `dart_aot_elf` are `target_compatible_with` only the modes `AOT_MODES` lists,
    so under `mode=debug` this target reports incompatibility rather than
    building a kernel gen_snapshot rejects.

    Also declares `<name>_jit_kernel`, the debug (JIT) kernel: a manual
    `dart_jit_kernel` over the same sources, which the debug overlay in
    `flutter_android_binary` ships as `kernel_blob.bin`. It is mode-independent
    and so not restricted by `target_compatible_with`. See
    docs_internal/build-modes-plan.md.

    Every rule-specific attribute is a named parameter here, and **kwargs
    carries only what both targets should share -- visibility, tags,
    `target_compatible_with`. Forwarding kwargs to both instead means an
    attribute that exists on only one of them cannot be passed at all, which
    stops being a footnote as soon as either rule grows a per-platform or
    per-ABI attribute. `target_compatible_with` is the one exception: each
    `dart_aot_elf` already sets it (see below), so a caller-supplied value is
    pulled out of kwargs once and concatenated in rather than passed twice.

    `abis` is required and always a list. There is no default: one would mean a
    consumer ships a single ABI, or three, without ever saying which.

    Produces `<name>_<abi>` per entry, and no `<name>` -- an unsuffixed target
    would have to pick an ABI silently.

    Args:
      name: prefix for the generated targets.
      srcs: Dart sources, for change detection.
      abis: Android ABIs to snapshot for. Required, always a list.
      pubspec: a flutter_pubspec target; supplies the package name.
      entrypoint: the app's entrypoint under lib/, as a label.
      pub: the `pub.lock` hub repository, e.g. `"@pub"`: its package config and
        hosted package files are the compile's package inputs.
      path_deps: sources of `path:` dependencies.
      dart_plugin_registrant: the Dart plugin registrant under lib/, as a label.
      target_os: OS the kernel is compiled for; see dart_aot_kernel.
      strip: drop DWARF from each ELF.
      dart_defines: `-D` constants the kernel compiles with; see dart_aot_kernel.dart_defines.
      **kwargs: shared rule attributes.
    """
    check_abis(abis, "flutter_aot_library " + name)
    package_config, _, pub_lib, _ = _pub_hub_labels(pub, "flutter_aot_library " + name)

    # Avoid passing target_compatible_with twice.
    caller_compatible_with = kwargs.pop("target_compatible_with", [])

    dart_aot_kernel(
        name = name + "_kernel",
        srcs = srcs,
        pubspec = pubspec,
        entrypoint = entrypoint,
        package_config = package_config,
        pub_srcs = [pub_lib],
        path_deps = path_deps,
        dart_plugin_registrant = dart_plugin_registrant,
        target_os = target_os,
        dart_defines = dart_defines,
        target_compatible_with = caller_compatible_with + aot_target_compatible_with(),
        **kwargs
    )

    # The debug kernel. It reads no mode, so it is the same action under either
    # one; manual keeps it out of `//...`. Only the debug overlay reaches it.
    dart_jit_kernel(
        name = name + "_jit_kernel",
        srcs = srcs,
        pubspec = pubspec,
        entrypoint = entrypoint,
        package_config = package_config,
        pub_srcs = [pub_lib],
        path_deps = path_deps,
        dart_plugin_registrant = dart_plugin_registrant,
        dart_defines = dart_defines,
        target_compatible_with = caller_compatible_with,
        **_internal_kwargs(kwargs)
    )

    # One kernel feeds every ABI: the kernel is architecture-independent, and
    # only the platform axis fans it out (see dart_aot_kernel's target_os).
    for abi in abis:
        dart_aot_elf(
            name = "{}_{}".format(name, abi),
            dill = ":" + name + "_kernel",
            abi = abi,
            snapshot_flags = ABIS[abi].snapshot_flags,
            strip = strip,
            # AOT targets are incompatible with debug; retain caller constraints.
            target_compatible_with = caller_compatible_with + aot_target_compatible_with(),
            **kwargs
        )

# Sentinel distinguishes the default from an explicit `None`.
_DEFAULT_DART_PLUGIN_REGISTRANT = struct()

# Keep macro-internal targets out of wildcard roots.
def _internal_tags(kwargs):
    tags = list(kwargs.get("tags", []))
    if "manual" not in tags:
        tags.append("manual")
    return tags

def _internal_kwargs(kwargs):
    internal = dict(kwargs)
    internal["tags"] = _internal_tags(kwargs)
    return internal

def _workspace_label(label):
    """Resolve a committed destination and reject external repositories."""
    requested = str(label)
    label = native.package_relative_label(label)
    workspace = native.package_relative_label("//:__pkg__")
    if label.repo_name != workspace.repo_name:
        fail(
            (
                "flutter_app: destination label {} belongs to repository {}, but " +
                "BUILD_WORKSPACE_DIRECTORY can only update files in the invoking " +
                "workspace."
            ).format(
                requested,
                label.repo_name,
            ),
        )
    return label

def _lib_tier(ctx, pubspec):
    """Declares a package's lib tier, and the deps_lib its test kernels import.

    The tier is the package's lib/ libraries, compiled once against test_deps and so
    shared by the package's tests. lib_entry.py picks the libraries and writes their
    entrypoint; frontend_server writes one dill per package, joined main first as in
    _jit_kernel_action. deps_lib is test_deps with the tier appended: the one
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

    # The debug flags and line-table handling of _jit_kernel_action, with the hub's
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
    return [FlutterPackageInfo(
        pubspec = pubspec,
        srcs = ctx.files.srcs,
        package_config = ctx.file.package_config,
        test_deps = ctx.file.test_deps,
        deps_lib = deps_lib,
        pub_srcs = ctx.files.pub_srcs,
        path_deps = ctx.files.path_deps,
        assets = assets[0] if assets else None,
    )]

_flutter_package = rule(
    implementation = _flutter_package_impl,
    doc = "Declares a Dart package's inputs to host tests. See flutter_package.",
    attrs = {
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
        "_lib_entry": attr.label(
            default = "//flutter/private:lib_entry.py",
            allow_single_file = True,
        ),
    },
    toolchains = ["//flutter/private:flutter_toolchain_type"],
)

def flutter_package(name, pub, pubspec, srcs = None, path_deps = [], assets = None, **kwargs):
    """The inputs a host test reads from a Dart package, with no app build.

    Declares no app build. `flutter_app` declares one as `:app`; a package without
    an app declares one by hand, as the conformance suite does:

        flutter_pubspec(name = "pubspec")
        flutter_package(name = "pkg", pub = "@pub", pubspec = ":pubspec")

    `pub` is the `pub.lock` hub of the package's dependencies, as for flutter_app.

    Args:
      name: the target's name.
      pub: the `pub.lock` hub repository, e.g. `"@pub"`.
      pubspec: the package's flutter_pubspec target.
      srcs: the package's lib/ Dart sources. Defaults to `glob(["lib/**/*.dart"])`.
      path_deps: sources of `path:` dependencies.
      assets: a flutter_assets target, passed to tests as --flutter-assets-dir.
      **kwargs: visibility, tags.
    """
    package_config, _, pub_lib, _ = _pub_hub_labels(pub, "flutter_package " + name)
    if srcs == None:
        srcs = native.glob(["lib/**/*.dart"])

    _flutter_package(
        name = name,
        pubspec = pubspec,
        srcs = srcs,
        package_config = package_config,
        test_deps = pub + "//:test_deps",
        pub_srcs = [pub_lib],
        path_deps = path_deps,
        assets = assets,
        **kwargs
    )

# buildifier: disable=unnamed-macro
# Target names are fixed: Android packaging derives them from the package.
def flutter_app(
        abis = None,
        path_deps = [],
        srcs = None,
        assets = None,
        entrypoint = "lib/main.dart",
        dart_plugin_registrant = _DEFAULT_DART_PLUGIN_REGISTRANT,
        pub = None,
        plugin_deps = "//:plugin_deps.MODULE.bazel",
        target_os = "android",
        dart_defines = {},
        **kwargs):
    """The Dart half of a Flutter app: one call, in the app's own package.

    Everything a standard `flutter create` layout fixes is a default here -- the
    entrypoint, the source and asset globs, the committed Dart registrant, and
    pubspec.yaml. What is left is what only the app knows:

        flutter_app(
            abis = ["arm64-v8a"],
            path_deps = ["//packages/mylib:srcs"],
            pub = "@pub",
        )

    `pub` is the hub of the app's `pubspec.lock`, declared in MODULE.bazel:

        pub = use_extension("@rules_flutter//flutter:extensions.bzl", "pub")
        pub.lock(name = "pub", lock = "//:pubspec.lock")
        use_repo(pub, "pub")

    `flutter pub get` is only how the lock is updated: no action reads
    `.dart_tool/` or `.flutter-plugins-dependencies`.

    Produces, in the calling package:

    | target | what |
    | --- | --- |
    | `:pubspec` | the package name and version, read once from pubspec.yaml |
    | `:app` | the package inputs `flutter_test(app = ...)` reads: pubspec, `lib/` sources, pub hub, `path_deps`, and `:assets` |
    | `:app_<abi>` | the AOT snapshot per ABI; release only |
    | `:app_jit_kernel` | the debug kernel, from flutter_aot_library; manual, shipped as `kernel_blob.bin` by the debug overlay |
    | `:assets` | the flutter_assets bundle, built for every ABI; no app Dart inputs, the same under every mode |
    | `:path_deps_check` | fails if a `path:` dependency is undeclared |
    | `:plugins_check` | fails if the committed Maven coordinates drifted |
    | `:plugins_update` | writes the generated Maven segment into the workspace |
    | `:dart_registrant_check` | fails if the committed registrant drifted |
    | `:dart_registrant_update` | writes the generated registrant into the workspace |
    | `:guards_test` | the guards, under `bazel test` |

    Under `--@rules_flutter//flutter:mode=debug`, `:app_<abi>` reports
    incompatibility. The debug overlay in `flutter_android_binary` ships
    `:app_jit_kernel` and the host-engine snapshots next to `:assets`; see
    docs_internal/build-modes-plan.md.

    The names are fixed rather than derived from a `name` parameter: the Android
    half computes them from the package (`flutter_android_binary(app = "//app")`),
    so a second spelling here would only be a way to break that agreement.

    `abis` has no default, here as everywhere: it is the one fact about an app
    that these rules cannot infer, and a default would mean shipping one ABI, or
    three, without ever saying which. It is an Android ABI list today; a second
    platform adds its own dimension rather than overloading this one.

    With the default, an app with no plugin graph (`plugin_deps = None`) has no
    Dart registrant; an app with one uses the conventional committed
    `lib/dart_plugin_registrant.dart`. Pass `dart_plugin_registrant = None` to
    opt out explicitly, including in a project that otherwise has a plugin
    graph. An explicitly supplied label remains the committed registrant guard.

    Args:
      abis: Android ABIs to build for. Required, always a list.
      path_deps: sources of `path:` dependencies -- the one input nothing else
        observes, which is why `:path_deps_check` exists.
      srcs: Dart sources. Defaults to `glob(["lib/**/*.dart"])`.
      assets: declared assets. Defaults to `glob(["assets/**"])`.
      entrypoint: the app's entrypoint under lib/. It drives the app's kernels
        (`:app_<abi>`, `:app_jit_kernel`) only. `:assets` compiles nothing, so
        it does not depend on the entrypoint.
      dart_plugin_registrant: the committed Dart registrant, or None.
      pub: the `pub.lock` hub repository, e.g. `"@pub"`. Required: it supplies
        the package config and every hosted package, for the compile and the
        bundle alike.
      plugin_deps: the committed Maven segment MODULE.bazel includes, which
        `:plugins_check` compares against the generated one. Repo-root by
        convention because that is where `include()` reads it from; `None` for a
        project with no plugin graph, which drops the two guards over it.
      target_os: OS the kernel is compiled for; see dart_aot_kernel.
      dart_defines: `-D` constants both kernels compile with, e.g. {"FOO": "bar"}.
        Read only through `const String.fromEnvironment(...)`; see
        dart_aot_kernel.dart_defines.
      **kwargs: visibility, tags -- passed to every target declared here.
    """
    check_abis(abis, "flutter_app")

    # `name` used to be a parameter that could not vary: the Android half derives
    # `//<pkg>:app`, `:assets` and `:pubspec` from the package, so a different
    # prefix here produced targets the APK never asked for. Refused by name
    # rather than colliding downstream in flutter_aot_library's own `name`.
    if "name" in kwargs:
        fail(
            "flutter_app: no `name` -- it declares `:app`, `:assets`, " +
            "`:pubspec` and the guards by convention, because " +
            "flutter_android_binary(app = ...) derives those names from the " +
            "package. One Flutter app per package, as one pubspec per package.",
        )

    # This is deliberately a *standard-layout* macro. flutter_tools has no
    # `--pubspec` or `--package-config-path` option for `build bundle`: it reads
    # pubspec.yaml and .dart_tool/package_config.json from the staged project
    # root, where the action stages the pub hub's project config. Name the
    # unsupported knobs rather than forwarding them through **kwargs to an
    # unrelated target and failing opaquely.
    for unsupported in ("pubspec", "package_config"):
        if unsupported in kwargs:
            fail(
                (
                    "flutter_app: no `{}` override -- {}. Use the lower-level " +
                    "rules if the Dart half alone has a nonstandard layout."
                ).format(
                    unsupported,
                    "`flutter build bundle` reads the standard-layout pubspec.yaml " +
                    "and exposes no option to relocate it" if unsupported == "pubspec" else "the package " +
                                                                                            "config is the `pub` hub's, passed as `pub = \"@hub\"`",
                ),
            )
    if not pub:
        fail(
            "flutter_app: `pub` is required, the `pub.lock` hub of this app's pubspec.lock, " +
            "e.g. pub = \"@pub\". See the flutter_app docstring for the MODULE.bazel lines.",
        )
    _, project_package_config, _, pub_all = _pub_hub_labels(pub, "flutter_app")

    if dart_plugin_registrant == _DEFAULT_DART_PLUGIN_REGISTRANT:
        dart_plugin_registrant = None if plugin_deps == None else "lib/dart_plugin_registrant.dart"

    if srcs == None:
        srcs = native.glob(["lib/**/*.dart"])
    if assets == None:
        assets = native.glob(["assets/**"])

    flutter_pubspec(src = "pubspec.yaml", **kwargs)

    flutter_aot_library(
        name = "app",
        srcs = srcs,
        abis = abis,
        pubspec = ":pubspec",
        entrypoint = entrypoint,
        pub = pub,
        path_deps = path_deps,
        dart_plugin_registrant = dart_plugin_registrant,
        target_os = target_os,
        dart_defines = dart_defines,
        **kwargs
    )

    flutter_assets(
        name = "assets",
        abis = abis,
        assets = assets,
        pubspec = ":pubspec",
        package_config = project_package_config,
        pub_srcs = [pub_all],
        path_deps = path_deps,
        **kwargs
    )

    flutter_package(
        name = "app",
        pub = pub,
        pubspec = ":pubspec",
        srcs = srcs,
        path_deps = path_deps,
        assets = ":assets",
        **kwargs
    )

    # The guards. Emitted rather than asked for: each one exists because its
    # absence was a silent failure once, and a guard a consumer has to remember
    # to instantiate is a guard that eventually is not there.
    pub_path_deps_check(
        name = "path_deps_check",
        path_deps = path_deps,
        pubspec_lock = "pubspec.lock",
        **kwargs
    )

    guards = [":path_deps_check"]

    # Both halves of the generated repo that a project commits: the Maven
    # coordinate segment MODULE.bazel includes, and the Dart registrant that
    # needs a `package:` URI and so cannot be consumed from the repo itself.
    # Both compare against @flutter_plugins, so both are skipped by a project
    # that has no such repo -- rather than making the macro uninstantiable there.
    if plugin_deps:
        plugin_deps_label = _workspace_label(plugin_deps)
        pub_plugins_check(
            name = "plugins_check",
            committed = plugin_deps_label,
            expected = "@flutter_plugins//:plugin_deps.MODULE.bazel",
            updater = ":plugins_update",
            **kwargs
        )
        guards.append(":plugins_check")

        _write_source_file(
            name = "plugins_update",
            source = "@flutter_plugins//:plugin_deps.MODULE.bazel",
            destination = plugin_deps_label,
            **_internal_kwargs(kwargs)
        )

        if dart_plugin_registrant:
            registrant_label = _workspace_label(dart_plugin_registrant)
            pub_plugins_check(
                name = "dart_registrant_check",
                committed = registrant_label,
                expected = "@flutter_plugins//:dart_plugin_registrant.dart",
                updater = ":dart_registrant_update",
                **kwargs
            )
            guards.append(":dart_registrant_check")

            _write_source_file(
                name = "dart_registrant_update",
                source = "@flutter_plugins//:dart_plugin_registrant.dart",
                destination = registrant_label,
                **_internal_kwargs(kwargs)
            )

    # The guards fail as *actions*, which is stronger than a test: anything
    # depending on one fails too, and the result is remote-cacheable. build_test
    # does not change that -- it only gives `bazel test` a reason to build them.
    build_test(
        name = "guards_test",
        targets = guards,
        **kwargs
    )

def _bundle_dir(out, abi, index):
    """Where one ABI's bundle goes.

    The first is the declared output itself, so the shared files are written
    once rather than copied in afterwards; the rest are action-local scratch
    used only for comparison and to read their manifests.
    """
    if index == 0:
        return "$EXECROOT/{}".format(out.path)
    return "$STAGE/bundles/{}".format(abi)

def _bundle_command(out, abi, index):
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
        platform = ABIS[abi].target_platform,
        dir = _bundle_dir(out, abi, index),
    )

def _flutter_assets_impl(ctx):
    # The directory must be named flutter_assets: android_binary derives the
    # in-APK path from the artifact path with assets_dir stripped, and Flutter
    # requires the bundle at assets/flutter_assets/ at runtime.
    out = ctx.actions.declare_directory(ctx.label.name + "/flutter_assets")

    toolchain = _flutter_toolchain(ctx)

    package_graph = ctx.file.package_config.dirname + "/package_graph.json"

    # Every file the bundle can read is staged and declared.
    stage_manifest_files = (
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
        "".join([f.path + "\n" for f in stage_manifest_files]),
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
    #
    # Code assets belong in APK JNI libraries, not the asset tree. Packaging
    # recipes install them under lib/<abi>/; discard flutter_tools' duplicate.
    # NativeAssetsManifest.json is retained beside the bundle for runtime lookup.
    project_dir = "/".join([
        component
        for component in [ctx.label.workspace_root, ctx.label.package]
        if component
    ])

    cmd = """set -euo pipefail
EXECROOT="$PWD"
export PATH="/usr/bin:/bin"
export ANDROID_HOME="$(python3 -c 'import os, sys; print(os.path.dirname(os.path.dirname(os.path.realpath(sys.argv[1]))))' "$EXECROOT/{android_sdk}")"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export FLUTTER_ALREADY_LOCKED="true"
# Refuse what this bundle does not model, before any flutter_tools work.
python3 "$EXECROOT/{bundle_guard}" --pubspec "$EXECROOT/{pubspec}"
STAGE="$(mktemp -d "${{TMPDIR:-/tmp}}/flutter_assets.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
# flutter_tools needs writable state; use a stage-local HOME so the host HOME
# does not affect the action key.
export HOME="$STAGE/home"
mkdir -p "$HOME"

tar -cf - -T "{manifest}" | (cd "$STAGE" && tar -xf -)
chmod -R u+w "$STAGE"
{place_config}
cd "$STAGE/{project_dir}"
# flutter_tools takes the project directory as two levels above --target, so
# the stub sits in its own directory. It is compiled only for record-use and
# imports nothing.
mkdir -p .flutter_bazel
printf 'void main() {{}}\\n' > .flutter_bazel/stub.dart
STUB=".flutter_bazel/stub.dart"
mkdir -p "$STAGE/bundles"
{flutter_tool}
{bundles}
# Keep the shell alive so its EXIT trap removes STAGE after the merger.
python3 "$EXECROOT/{merger}" {merge_args}
""".format(
        project_dir = project_dir,
        bundle_guard = ctx.file._bundle_guard.path,
        pubspec = ctx.attr.pubspec[FlutterPubspecInfo].src.path,
        flutter_tool = """FLUTTER_REAL="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$EXECROOT/{launcher}")"
export FLUTTER_ROOT="$(dirname "$(dirname "$FLUTTER_REAL")")"
flutter_tool() {{
    "$FLUTTER_ROOT/bin/cache/dart-sdk/bin/dart" --packages="$FLUTTER_ROOT/packages/flutter_tools/.dart_tool/package_config.json" "$EXECROOT/{snapshot}" "$@"
}}""".format(launcher = toolchain.flutter.path, snapshot = toolchain.tools_snapshot.path),
        android_sdk = ctx.file._android_sdk.path,
        manifest = manifest.path,
        place_config = (
            'mkdir -p "$STAGE/{d}.dart_tool" && cp "$EXECROOT/{c}" "$STAGE/{d}.dart_tool/package_config.json"\n' +
            'cp "$EXECROOT/{g}" "$STAGE/{d}.dart_tool/package_graph.json"\n'
        ).format(
            d = project_dir + "/" if project_dir else "",
            c = ctx.file.package_config.path,
            g = package_graph,
        ),
        merger = ctx.file._merger.path,
        bundles = "\n".join([_bundle_command(out, abi, i) for i, abi in enumerate(ctx.attr.abis)]),
        merge_args = " ".join([
            '--bundle "{}={}"'.format(abi, _bundle_dir(out, abi, i))
            for i, abi in enumerate(ctx.attr.abis)
        ]),
    )

    ctx.actions.run_shell(
        command = cmd,
        inputs = depset(
            direct = stage_manifest_files + [manifest, toolchain.sdk_version, ctx.file._merger, ctx.file._bundle_guard, toolchain.flutter, toolchain.tools_snapshot, ctx.file._android_sdk],
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
is not. The debug kernel and snapshots are not part of it: the debug overlay in
flutter_android_binary adds them.

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
        "abis": attr.string_list(
            mandatory = True,
            doc = """ABIs to bundle for. Required, always a list.

`flutter build bundle` runs once per ABI inside this one action, because
exactly one file it produces -- NativeAssetsManifest.json -- is keyed by
architecture. The manifests are merged and everything else is compared, so a
bundle that started varying by architecture fails here rather than shipping.""",
        ),
        "_android_sdk": attr.label(
            default = "//flutter/private:_android_sdk_marker",
            allow_single_file = True,
            cfg = "exec",
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

def _pub_path_deps_check_impl(ctx):
    marker = ctx.actions.declare_file(ctx.label.name + ".checked")

    args = ctx.actions.args()

    # run_shell reserves $0 for an empty placeholder, so the script arrives as
    # $1 and "$@" already includes it.
    args.add(ctx.file._checker)
    args.add("--lock", ctx.file.pubspec_lock)
    args.add("--package-dir", ctx.label.package)
    args.add("--out", marker)
    args.add_all("--declared", ctx.files.path_deps)

    # Bazel 9 has no native py_binary and rules_python is not worth a dependency
    # for one check script, so invoke the interpreter directly.
    ctx.actions.run_shell(
        command = 'exec python3 "$@"',
        arguments = [args],
        inputs = [ctx.file.pubspec_lock, ctx.file._checker] + ctx.files.path_deps,
        outputs = [marker],
        mnemonic = "PubPathDepsCheck",
        progress_message = "Checking path: dependencies %{label}",
    )

    return [DefaultInfo(files = depset([marker]))]

pub_path_deps_check = rule(
    implementation = _pub_path_deps_check_impl,
    doc = """Fails the build if a `path:` dependency is not declared in path_deps.

Hosted packages are pinned by sha256 in pubspec.lock, so their content shows up
in the action key. Path dependencies are not, so an undeclared one yields a
silently stale artifact -- and a shared remote cache spreads it. Depend on this
target from CI, or wire it into a test suite, before enabling a shared cache.""",
    attrs = {
        "pubspec_lock": attr.label(allow_single_file = True, mandatory = True),
        "path_deps": attr.label_list(allow_files = True),
        "_checker": attr.label(
            default = "//flutter/private:check_path_deps.py",
            allow_single_file = True,
        ),
    },
)

def _pub_plugins_check_impl(ctx):
    marker = ctx.actions.declare_file(ctx.label.name + ".checked")
    updater = ""
    if ctx.attr.updater:
        updater_label = ctx.attr.updater.label
        updater = (
            "//{}:{}".format(updater_label.package, updater_label.name) if updater_label.repo_name == ctx.label.repo_name else str(updater_label)
        )

    ctx.actions.run_shell(
        command = """
set -eu
expected="$1"; committed="$2"; marker="$3"; updater="$4"
if ! diff -u "$committed" "$expected" > /dev/null 2>&1; then
    echo "ERROR: $committed is out of date." >&2
    echo "" >&2
    echo "The Flutter plugins in pubspec.yaml declare Maven coordinates that do" >&2
    echo "not match the committed MODULE.bazel segment. Replace it with:" >&2
    echo "" >&2
    sed 's/^/    /' "$expected" >&2
    if [[ -n "$updater" ]]; then
        echo "" >&2
        echo "To regenerate it, run:" >&2
        echo "    bazel run $updater" >&2
    fi
    echo "" >&2
    diff -u "$committed" "$expected" >&2 || true
    exit 1
fi
touch "$marker"
""",
        arguments = [
            ctx.file.expected.path,
            ctx.file.committed.path,
            marker.path,
            updater,
        ],
        inputs = [ctx.file.expected, ctx.file.committed],
        outputs = [marker],
        mnemonic = "PubPluginsCheck",
        progress_message = "Checking plugin Maven coordinates %{label}",
    )

    return [DefaultInfo(files = depset([marker]))]

pub_plugins_check = rule(
    implementation = _pub_plugins_check_impl,
    doc = """Fails the build if the committed plugin_deps.MODULE.bazel has drifted.

MODULE.bazel cannot load() and one module extension cannot add tags to another,
so the Maven coordinates extracted from plugin build.gradle files cannot be fed
into maven.install() directly. They are generated, committed and include()d
instead, which means they can go stale -- most obviously when a plugin is added
or upgraded. This is the guard, and it prints the file to write.""",
    attrs = {
        "committed": attr.label(
            allow_single_file = True,
            mandatory = True,
            doc = "The checked-in MODULE.bazel segment.",
        ),
        "expected": attr.label(
            allow_single_file = True,
            mandatory = True,
            doc = "The segment generated by the plugins repository rule.",
        ),
        "updater": attr.label(
            doc = "Optional updater command to print when this guard drifts.",
        ),
    },
)

_WRITE_SOURCE_FILE_SCRIPT = """#!/usr/bin/env bash
# Bazel Bash runfiles initialization.
set -uo pipefail; set +e; f=bazel_tools/tools/bash/runfiles/runfiles.bash
# shellcheck disable=SC1090
source "${{RUNFILES_DIR:-/dev/null}}/$f" 2>/dev/null || \\
  source "$(grep -sm1 "^$f " "${{RUNFILES_MANIFEST_FILE:-/dev/null}}" | cut -f2- -d' ')" 2>/dev/null || \\
  source "$0.runfiles/$f" 2>/dev/null || \\
  source "$(grep -sm1 "^$f " "$0.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null || \\
  source "$(grep -sm1 "^$f " "$0.exe.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null || \\
  {{ echo>&2 "ERROR: cannot find $f"; exit 1; }}; f=; set -e

key={source}
source_file="$(rlocation "$key" || true)"
if [[ ! -f "$source_file" ]]; then
  echo "ERROR: cannot locate generated source file $key in runfiles." >&2
  exit 1
fi

workspace="${{BUILD_WORKSPACE_DIRECTORY:?this target must be run with bazel run}}"
destination="$workspace"/{destination}
mkdir -p "$(dirname "$destination")"
cp "$source_file" "$destination"
"""

def _write_source_file_impl(ctx):
    script = ctx.actions.declare_file(ctx.label.name)
    source = ctx.file.source

    # Convert short_path to the repository-qualified runfiles key.
    source_path = source.short_path
    if source_path.startswith("../"):
        source_path = source_path[3:]
    else:
        source_path = ctx.workspace_name + "/" + source_path

    # Only source files in this workspace can be safely overwritten.
    destination = ctx.file.destination
    if destination.short_path.startswith("../") or not destination.is_source:
        fail(
            (
                "{}: destination {} is not a source file in the invoking " +
                "workspace, and BUILD_WORKSPACE_DIRECTORY can only update files " +
                "there. Name the committed file directly."
            ).format(
                ctx.label,
                ctx.attr.destination.label,
            ),
        )

    ctx.actions.write(
        output = script,
        content = _WRITE_SOURCE_FILE_SCRIPT.format(
            source = shell.quote(source_path),
            destination = shell.quote(destination.short_path),
        ),
        is_executable = True,
    )

    return [DefaultInfo(
        executable = script,
        runfiles = ctx.runfiles(files = [source]).merge(
            ctx.attr._runfiles[DefaultInfo].default_runfiles,
        ),
    )]

_write_source_file = rule(
    implementation = _write_source_file_impl,
    executable = True,
    doc = "Writes a generated artifact into a source file in the Consumer Module.",
    attrs = {
        "source": attr.label(
            allow_single_file = True,
            mandatory = True,
            doc = "The generated artifact to write back.",
        ),
        "destination": attr.label(
            allow_single_file = True,
            mandatory = True,
            doc = "The committed file to overwrite in the invoking workspace.",
        ),
        "_runfiles": attr.label(
            default = "@bazel_tools//tools/bash/runfiles",
        ),
    },
)
