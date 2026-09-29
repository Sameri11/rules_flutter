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
# worker would not have it. The action is otherwise sandboxed and cacheable,
# debug included: the debug kernel it ships is compiled with package: and
# org-dartlang-root: URIs only (see _debug_kernel_command), so its bytes do not
# carry the producing machine's paths. Deliberately absent: `local`, which would
# disable remote caching outright.
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

def _project_path(ctx, file, attribute):
    """A file's path relative to the calling package/project root.

    Unlike `_library_path`, this keeps the leading `lib/`: flutter_tools'
    `--target` accepts a project-relative filesystem path, not a `package:` URI
    suffix.
    """
    path = _repository_path(ctx, file, attribute)
    prefix = ctx.label.package + "/" if ctx.label.package else ""
    if not path.startswith(prefix):
        fail("{}: {} must be inside package {}, got {}.".format(
            ctx.label,
            attribute,
            ctx.label.package,
            path,
        ))
    return path[len(prefix):]

def _sdk_root_for(platform_files, mode):
    """Directory holding platform_strong.dill, for a patched-SDK filegroup.

    `--sdk-root` wants the directory, not the file.
    """
    for f in platform_files:
        if f.basename == "platform_strong.dill":
            return f.dirname
    fail("platform_strong.dill not found for mode '{}'".format(mode))

# frontend_server flags for a debug (JIT) kernel. Shared, verbatim, by
# dart_kernel (via args.add_all) and _debug_kernel_command (joined into a
# shell template), so an SDK-driven flag change is made once.
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
# verbatim, by dart_kernel (formatted with shell variable names, resolved at
# run time) and _debug_kernel_command (formatted with an analysis-time path).
_REGISTRANT_SOURCE_ARGS = '--source "package:{pkg}/{registrant}" --source "package:flutter/src/dart_plugin_registrant.dart" "-Dflutter.dart_plugin_registrant=package:{pkg}/{registrant}"'

def _flutter_toolchain(ctx):
    return ctx.toolchains["//flutter/private:flutter_toolchain_type"].flutter

def _dart_kernel_impl(ctx):
    dill = ctx.actions.declare_file(ctx.label.name + ".dill")
    mode = ctx.attr._mode[BuildSettingInfo].value
    release = mode != "debug"

    # Release compiles against the product SDK; debug keeps asserts and the
    # service protocol, so it uses the non-product one.
    toolchain = _flutter_toolchain(ctx)
    platform_files = toolchain.platform_product if release else toolchain.platform_debug

    # --sdk-root wants the directory holding platform_strong.dill.
    sdk_root = _sdk_root_for(platform_files, mode)

    args = ctx.actions.args()

    args.add(toolchain.dartaotruntime)
    args.add(toolchain.frontend_server)
    args.add("--sdk-root", sdk_root + "/")
    args.add("--target", "flutter")

    # frontend_server speaks its compiler-daemon protocol on every completion,
    # success included: one `+file:///...` line per source it read, absolute
    # host and execroot paths included. That is 7340 lines for this
    # repo's two apps, and it drowns anything real. The flag defaults to on;
    # turning it off leaves only the three-line `result <uuid>` handshake,
    # which is the protocol itself and has no flag.
    #
    # Deliberately not done by capturing stdout in the wrapper instead: the
    # kernel is byte-identical either way, but a wrapper has to re-raise the
    # exit code by hand (frontend_server exits 254 on a compile error) and it
    # discards whatever the CFE prints on a *successful* compile, where
    # --verbosity defaults to `all`.
    args.add("--no-print-incremental-dependencies")
    if release:
        args.add("--aot")
        args.add("--tfa")
        args.add("-Ddart.vm.product=true")

        if ctx.attr.target_os:
            args.add("--target-os", ctx.attr.target_os)
    else:
        args.add_all(_DEBUG_KERNEL_FLAGS)

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
        # Every package the compile can read is declared: the hub's package
        # config (relative roots only, so the key carries no host path), its
        # hosted package files, and the SDK's packages through the toolchain.
        # Hosted content is pinned by the lock's sha256 at fetch time. Path
        # dependencies carry no hash and are covered only by what the caller
        # lists in `srcs` or `path_deps`; see `path_deps`.
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
        mnemonic = "DartKernel",
        progress_message = "Compiling Dart kernel (%s) %%{label}" % mode,
    )

    return [DefaultInfo(files = depset([dill]))]

dart_kernel = rule(
    implementation = _dart_kernel_impl,
    doc = "Compiles Dart sources to a kernel (.dill) via frontend_server.",
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
        "_mode": attr.label(
            default = "//flutter:mode",
            providers = [BuildSettingInfo],
            doc = """Build mode, read from //flutter:mode. Governs the compiler flags.

Both modes are cacheable: release output is stripped of absolute paths by
gen_snapshot, and the debug kernel's source URIs are `package:` and
`org-dartlang-root:` only.

Implicit rather than a public attribute: mode is one build-wide selection, not
a per-target knob -- see docs_internal/build-modes-plan.md.""",
        ),
        "target_os": attr.string(
            default = "android",
            values = ["android", "ios", "macos", "linux", "windows", "fuchsia", ""],
            doc = """Target OS for `--target-os`, or "" to omit the flag.

Release-only: flutter_tools passes it under `--aot` alone.

""",
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

def flutter_aot_library(name, srcs, abis, pubspec, entrypoint, pub, path_deps = [], dart_plugin_registrant = None, target_os = "android", strip = True, **kwargs):
    """Convenience wrapper: Dart sources straight through to libapp.so.

    Produces an AOT-shaped `.dill` and its `libapp.so` per ABI. `dart_kernel`'s
    `--aot`/`--tfa` branch is what gen_snapshot needs; it is selected by the
    ambient `//flutter:mode`, not pinned here. Under `mode=debug` this
    target's kernel compiles without them, so each `dart_aot_elf` here is
    `target_compatible_with` only the modes `AOT_MODES` lists -- an explicit
    debug build, or a `//...` sweep under debug, reports incompatibility
    rather than reaching gen_snapshot with a kernel it rejects (see
    docs_internal/build-modes-plan.md).

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
      target_os: OS the kernel is compiled for; see dart_kernel.
      strip: drop DWARF from each ELF.
      **kwargs: shared rule attributes.
    """
    check_abis(abis, "flutter_aot_library " + name)
    package_config, _, pub_lib, _ = _pub_hub_labels(pub, "flutter_aot_library " + name)

    # Avoid passing target_compatible_with twice.
    caller_compatible_with = kwargs.pop("target_compatible_with", [])

    dart_kernel(
        name = name + "_kernel",
        srcs = srcs,
        pubspec = pubspec,
        entrypoint = entrypoint,
        package_config = package_config,
        pub_srcs = [pub_lib],
        path_deps = path_deps,
        dart_plugin_registrant = dart_plugin_registrant,
        target_os = target_os,
        target_compatible_with = caller_compatible_with,
        **kwargs
    )

    # One kernel feeds every ABI: the kernel is architecture-independent, and
    # only the platform axis fans it out (see dart_kernel's target_os).
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
    | `:app_<abi>` | the AOT snapshot per ABI |
    | `:assets` | the asset bundle, built for every ABI |
    | `:path_deps_check` | fails if a `path:` dependency is undeclared |
    | `:plugins_check` | fails if the committed Maven coordinates drifted |
    | `:plugins_update` | writes the generated Maven segment into the workspace |
    | `:dart_registrant_check` | fails if the committed registrant drifted |
    | `:dart_registrant_update` | writes the generated registrant into the workspace |
    | `:guards_test` | the guards, under `bazel test` |

    `:app_<abi>` and `:assets` compile to their debug shape under
    `--@rules_flutter//flutter:mode=debug`; see
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
      entrypoint: the app's entrypoint under lib/. It drives both kernel
        compilation and `flutter build bundle --target`, so the snapshot and
        asset/code bundle cannot select different programs.
      dart_plugin_registrant: the committed Dart registrant, or None.
      pub: the `pub.lock` hub repository, e.g. `"@pub"`. Required: it supplies
        the package config and every hosted package, for the compile and the
        bundle alike.
      plugin_deps: the committed Maven segment MODULE.bazel includes, which
        `:plugins_check` compares against the generated one. Repo-root by
        convention because that is where `include()` reads it from; `None` for a
        project with no plugin graph, which drops the two guards over it.
      target_os: OS the kernel is compiled for; see dart_kernel.
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
        **kwargs
    )

    flutter_assets(
        name = "assets",
        srcs = srcs,
        abis = abis,
        assets = assets,
        pubspec = ":pubspec",
        entrypoint = entrypoint,
        package_config = project_package_config,
        pub_srcs = [pub_all],
        path_deps = path_deps,
        dart_plugin_registrant = dart_plugin_registrant,
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

def _bundle_command(ctx, out, abi, index):
    # `flutter_tool` is a shell function defined in the action preamble that runs
    # the tool's snapshot directly. bin/flutter rewrites bin/cache/engine.stamp
    # and engine.realm in the SDK on every invocation
    # (bin/internal/update_engine_version.sh), which a sandbox forbids.
    return """flutter_tool build bundle \
    --{mode} \
    --no-pub \
    --target="$ENTRYPOINT" \
    --target-platform={platform} \
    --asset-dir="{dir}" \
    --suppress-analytics >/dev/null
rm -f "{dir}/.last_build_id"
rm -rf "{dir}/native_assets"
""".format(
        mode = ctx.attr._mode[BuildSettingInfo].value,
        platform = ABIS[abi].target_platform,
        dir = _bundle_dir(out, abi, index),
    )

def _debug_kernel_command(ctx, out, project_dir, debug, toolchain):
    """Shell recompiling the debug kernel with scheme-relative source URIs.

    Overwrites every ABI bundle's kernel_blob.bin with the result.

    `flutter build bundle --debug` (via _bundle_command above) already
    produced a kernel_blob.bin per ABI bundle, but flutter_tools has no flag
    that stops its frontend_server invocation from recording absolute
    `file://` URIs under the mktemp $STAGE. Two fresh debug builds with
    unchanged inputs would therefore never produce the same kernel_blob.bin.

    This recompiles once, calling frontend_server directly, mirroring
    _dart_kernel_impl's debug branch (mode flags, package: URIs for the
    entrypoint and plugin registrant) with two additions that make $STAGE's
    own path invisible to the kernel: --filesystem-root/--filesystem-scheme
    turn it into a virtual root, and --packages is a URI under that scheme
    instead of a real path. The staged package config is the pub hub's
    project-relative one, so every rootUri -- the project, its path
    dependencies, hosted packages and the SDK's packages, all staged as
    declared inputs -- resolves under the same scheme. The kernel's source
    URIs are `package:` and `org-dartlang-root:` only, which is what lets the
    action be cached and shared like a release one.

    `debug` is the caller's single mode check, passed in rather than
    re-derived, so the command and its declared inputs never disagree on
    whether this build is a debug build.
    """
    if not debug:
        return ""

    sdk_root = _sdk_root_for(toolchain.platform_debug, "debug")
    prefix = project_dir + "/" if project_dir else ""
    entrypoint_library = _library_path(ctx, ctx.file.entrypoint, "entrypoint")

    registrant = ""
    if ctx.file.dart_plugin_registrant:
        registrant_library = _library_path(ctx, ctx.file.dart_plugin_registrant, "dart_plugin_registrant")
        registrant = _REGISTRANT_SOURCE_ARGS.format(pkg = "$PKG", registrant = registrant_library) + " "

    overwrites = "\n".join([
        'cp "$STAGE/kernel_blob.dill" "{dir}/kernel_blob.bin"'.format(dir = _bundle_dir(out, abi, i))
        for i, abi in enumerate(ctx.attr.abis)
    ])

    return """PKG="$(cat "$EXECROOT/{package_name}")"
"$EXECROOT/{dartaotruntime}" "$EXECROOT/{frontend_server}" \
    --sdk-root "$EXECROOT/{sdk_root}/" \
    --target=flutter --no-print-incremental-dependencies \
    {debug_flags} \
    --filesystem-root "$STAGE" --filesystem-scheme org-dartlang-root \
    --packages "org-dartlang-root:///{prefix}.dart_tool/package_config.json" \
    --output-dill "$STAGE/kernel_blob.dill" \
    {registrant}--verbosity=error "package:$PKG/{entrypoint}"
{overwrites}
""".format(
        package_name = ctx.attr.pubspec[FlutterPubspecInfo].package_name.path,
        dartaotruntime = toolchain.dartaotruntime.path,
        frontend_server = toolchain.frontend_server.path,
        sdk_root = sdk_root,
        debug_flags = " ".join(_DEBUG_KERNEL_FLAGS),
        prefix = prefix,
        registrant = registrant,
        entrypoint = entrypoint_library,
        overwrites = overwrites,
    )

def _flutter_assets_impl(ctx):
    # The directory must be named flutter_assets: android_binary derives the
    # in-APK path from the artifact path with assets_dir stripped, and Flutter
    # requires the bundle at assets/flutter_assets/ at runtime.
    out = ctx.actions.declare_directory(ctx.label.name + "/flutter_assets")

    mode = ctx.attr._mode[BuildSettingInfo].value
    debug = mode == "debug"
    toolchain = _flutter_toolchain(ctx)
    entrypoint = _project_path(ctx, ctx.file.entrypoint, "entrypoint")
    args = ctx.actions.args()
    args.add(entrypoint)

    # Every file the bundle can read is staged and declared: the hub's
    # project-relative package config and package graph, every hosted package,
    # and the SDK's packages.
    package_graph = ctx.file.package_config.dirname + "/package_graph.json"
    stage_manifest_files = (
        [
            ctx.file.entrypoint,
            ctx.file.package_config,
            ctx.attr.pubspec[FlutterPubspecInfo].src,
        ] +
        ([ctx.file.dart_plugin_registrant] if ctx.file.dart_plugin_registrant else []) +
        ctx.files.assets + ctx.files.srcs +
        ctx.files.path_deps +
        ctx.files.pub_srcs +
        toolchain.sdk_packages.to_list()
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

    cmd = """ENTRYPOINT="$1"; shift
set -euo pipefail
EXECROOT="$PWD"
export PATH="/usr/bin:/bin"
export ANDROID_HOME="$(python3 -c 'import os, sys; print(os.path.dirname(os.path.dirname(os.path.realpath(sys.argv[1]))))' "$EXECROOT/{android_sdk}")"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export FLUTTER_ALREADY_LOCKED="true"
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
mkdir -p "$STAGE/bundles"
{flutter_tool}
{bundles}
{debug_kernel}
# Keep the shell alive so its EXIT trap removes STAGE after the merger.
python3 "$EXECROOT/{merger}" {merge_args}
""".format(
        project_dir = project_dir,
        flutter_tool = """FLUTTER_REAL="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$EXECROOT/%s")"
export FLUTTER_ROOT="$(dirname "$(dirname "$FLUTTER_REAL")")"
flutter_tool() {
    "$FLUTTER_ROOT/bin/cache/dart-sdk/bin/dart" --packages="$FLUTTER_ROOT/packages/flutter_tools/.dart_tool/package_config.json" "$FLUTTER_ROOT/bin/cache/flutter_tools.snapshot" "$@"
}""" % toolchain.flutter.path,
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
        bundles = "\n".join([_bundle_command(ctx, out, abi, i) for i, abi in enumerate(ctx.attr.abis)]),
        debug_kernel = _debug_kernel_command(ctx, out, project_dir, debug, toolchain),
        merge_args = " ".join([
            '--bundle "{}={}"'.format(abi, _bundle_dir(out, abi, i))
            for i, abi in enumerate(ctx.attr.abis)
        ]),
    )

    # Declared and passed as a tool only for a debug build: release never
    # calls _debug_kernel_command. `debug`, not a second `_mode` read, is the
    # gate -- see _debug_kernel_command's docstring.
    debug_kernel_inputs = (
        [
            toolchain.frontend_server,
            ctx.attr.pubspec[FlutterPubspecInfo].package_name,
        ] + toolchain.platform_debug
    ) if debug else []

    ctx.actions.run_shell(
        command = cmd,
        arguments = [args],
        tools = [toolchain.dartaotruntime] if debug else [],
        inputs = depset(
            direct = stage_manifest_files + [manifest, toolchain.sdk_version, ctx.file._merger, toolchain.flutter, ctx.file._android_sdk] + debug_kernel_inputs,
        ),
        outputs = [out],
        mnemonic = "FlutterAssets",
        progress_message = "Bundling Flutter assets (%s) %%{label}" % mode,
        execution_requirements = _ASSETS_EXEC,
    )

    return [DefaultInfo(files = depset([out]))]

flutter_assets = rule(
    implementation = _flutter_assets_impl,
    doc = """Produces a flutter_assets/ tree (AssetManifest.bin, FontManifest.json,
NOTICES.Z, fonts, shaders, declared assets) for packaging into an APK.

Unlike the Dart half, this shells out to `flutter build bundle`. There is no
standalone asset-bundler binary: asset resolution, font manifests and license
aggregation all live inside flutter_tools. `--asset-dir` and `--target` are the
documented entry points for driving it from another build system.""",
    attrs = {
        "srcs": attr.label_list(allow_files = [".dart"]),
        "entrypoint": attr.label(
            allow_single_file = [".dart"],
            mandatory = True,
            doc = """The Dart entrypoint `flutter build bundle --target` uses.

Must be the same file dart_kernel compiles. Flutter defaults the command to
lib/main.dart when omitted, which silently combines a snapshot for one program
with an asset/code bundle for another when an app overrides its entrypoint.""",
        ),
        "dart_plugin_registrant": attr.label(
            allow_single_file = [".dart"],
            doc = """The generated Dart plugin registrant, e.g.
`lib/dart_plugin_registrant.dart`. See dart_kernel.dart_plugin_registrant.

Used to recompile the debug kernel with scheme-relative source URIs; see
_debug_kernel_command. Omit for an app with no federated plugins.""",
        ),
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
            doc = "See dart_kernel.path_deps.",
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
        "_mode": attr.label(
            default = "//flutter:mode",
            providers = [BuildSettingInfo],
            doc = "See dart_kernel._mode. Debug bundles ship kernel_blob.bin.",
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
