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

Sandboxing caveat
-----------------
`package_config.json` points at absolute paths in ~/.pub-cache and the Flutter
SDK, neither of which is a declared Bazel input. These actions therefore run
unsandboxed. Making them hermetic means modelling pub packages as Bazel repos
(a pub -> MODULE.bazel resolver), which is the genuinely hard part of this
problem and is not attempted here.
"""

load("@bazel_skylib//rules:build_test.bzl", "build_test")
load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load(":abis.bzl", "ABIS", "aot_gen_snapshot", "aot_target_compatible_with", "check_abis")
load(":pubspec.bzl", "FlutterPubspecInfo", "flutter_pubspec")

# Release actions may be shared through a remote cache.
#
# no-sandbox:     package_config.json reaches into ~/.pub-cache, which is not a
#                 declared input, so a sandbox would hide it.
# no-remote-exec: those same undeclared inputs would not exist on a remote
#                 worker, so the action cannot be executed remotely.
#
# Deliberately absent: `local`. That tag forces the local strategy and disables
# remote caching outright, which is stronger than needed here.
_EXEC_RELEASE = {
    "no-sandbox": "1",
    "no-remote-exec": "1",
}

# Debug actions add `local`, which disables remote caching entirely.
#
# Debug kernels embed absolute source URIs (~800 in this demo app) and are
# shipped verbatim as kernel_blob.bin. A cache hit would hand one machine's
# artifact to another, carrying the producing machine's paths into stack traces
# and breaking hot reload. Release output goes through `gen_snapshot --strip`,
# which discards those paths, so release artifacts are safe to share.
_EXEC_DEBUG = dict(_EXEC_RELEASE, **{"local": "1"})

def _exec_requirements(mode):
    return _EXEC_DEBUG if mode == "debug" else _EXEC_RELEASE

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

def _dart_kernel_impl(ctx):
    dill = ctx.actions.declare_file(ctx.label.name + ".dill")
    mode = ctx.attr._mode[BuildSettingInfo].value
    release = mode != "debug"

    # Release compiles against the product SDK; debug keeps asserts and the
    # service protocol, so it uses the non-product one.
    platform = ctx.attr._platform_product if release else ctx.attr._platform_debug
    platform_files = ctx.files._platform_product if release else ctx.files._platform_debug

    # --sdk-root wants the directory holding platform_strong.dill, so locate
    # that file within the filegroup and take its parent.
    sdk_root = None
    for f in platform_files:
        if f.basename == "platform_strong.dill":
            sdk_root = f.dirname
            break
    if sdk_root == None:
        fail("platform_strong.dill not found for mode '{}'".format(mode))

    args = ctx.actions.args()

    args.add(ctx.executable._dartaotruntime)
    args.add(ctx.file._frontend_server)
    args.add("--sdk-root", sdk_root + "/")
    args.add("--target", "flutter")

    # frontend_server speaks its compiler-daemon protocol on every completion,
    # success included: one `+file:///...` line per source it read, absolute
    # ~/.pub-cache and execroot paths included. That is 7340 lines for this
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
        args.add("-Ddart.vm.profile=false")
        args.add("-Ddart.vm.product=false")
        args.add("--enable-asserts")
        args.add("--track-widget-creation")
        args.add("--no-link-platform")
    args.add("--packages", ctx.file.package_config)

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
    set -- "$@" \
        --source "package:$PKG/$REGISTRANT" \
        --source "package:flutter/src/dart_plugin_registrant.dart" \
        "-Dflutter.dart_plugin_registrant=package:$PKG/$REGISTRANT"
fi

exec "$@" --output-dill "$DILL" "package:$PKG/$ENTRYPOINT"
""",
        arguments = [scalars, args],
        tools = [ctx.attr._dartaotruntime[DefaultInfo].files_to_run],
        # package_config.json is passed as --packages but deliberately NOT
        # declared. Its rootUri entries are absolute paths into ~/.pub-cache, so
        # declaring it would put machine-specific bytes in the action key and
        # guarantee a miss on every other machine. Left undeclared, the key is
        # machine-independent (verified: no other input contains an absolute
        # path, and this action sets no env), so release artifacts can be shared
        # through a remote cache.
        #
        # This relies on `no-sandbox`: the file is read through the execroot
        # symlink forest. Under a sandbox it would be absent and the compile
        # would fail.
        #
        # Correctness then rests on pub_stamp, and pubspec.lock in particular:
        # its per-package sha256 is verified by pub on extraction, so for hosted
        # dependencies identical keys imply identical package contents. Path
        # dependencies carry no hash and are NOT covered -- list their sources in
        # `srcs` or a shared cache can serve the wrong artifact.
        inputs = depset(
            direct = [
                         ctx.file._frontend_server,
                         ctx.file._sdk_version,
                         # The name alone, not pubspec.yaml: a version bump or an edit
                         # to the asset list must not invalidate the kernel.
                         pubspec.package_name,
                         # Declared as well as globbed into srcs. These two are labels,
                         # so an app whose srcs miss the entrypoint still rebuilds when
                         # it changes rather than serving a stale kernel.
                         ctx.file.entrypoint,
                     ] + ([ctx.file.dart_plugin_registrant] if ctx.file.dart_plugin_registrant else []) +
                     ctx.files.pub_stamp + ctx.files.path_deps,
            transitive = [platform.files, depset(ctx.files.srcs)],
        ),
        outputs = [dill],
        mnemonic = "DartKernel",
        progress_message = "Compiling Dart kernel (%s) %%{label}" % mode,
        execution_requirements = _exec_requirements(mode),
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
            doc = """The .dart_tool/package_config.json from `flutter pub get`.

Passed as --packages but intentionally not a declared input, to keep absolute
pub-cache paths out of the action key. See the comment in _dart_kernel_impl.""",
        ),
        "path_deps": attr.label_list(
            allow_files = True,
            doc = """Sources of `path:` dependencies from pubspec.yaml.

Hosted packages are covered by pubspec.lock's per-package sha256. Path
dependencies have no hash and a version that nobody bumps, so nothing else in
the action key observes their content -- editing one produces a silently stale
artifact, and with a shared cache that artifact is served to everyone.

Point this at a filegroup in the dependency's own package, e.g.
`path_deps = ["//packages/mylib:srcs"]`. Bazel globs cannot cross package
boundaries, so the dependency needs its own BUILD file.""",
        ),
        "pub_stamp": attr.label_list(
            allow_files = True,
            doc = """Extra .dart_tool metadata declared purely for invalidation.

Declare pubspec.lock here too: it records a sha256 per *hosted* package, which
pub verifies on extraction, so for hosted dependencies version identity implies
content identity. Path dependencies carry no hash and no meaningful version,
and are invisible to this mechanism -- declare their sources in `srcs`.

These record *identity* rather than content: `version` holds the Flutter SDK
version, and `package_graph.json` holds resolved package versions (which
catches path dependencies, whose rootUri carries no version). Declaring them
means an SDK or dependency upgrade dirties this action even when no path
string in package_config.json changed. They cannot detect edits to framework
or pub-cache sources made at an unchanged version — only real file inputs
would.""",
        ),
        "_dartaotruntime": attr.label(
            default = "@flutter_sdk//:dartaotruntime",
            executable = True,
            cfg = "exec",
            allow_single_file = True,
        ),
        "_frontend_server": attr.label(
            default = "@flutter_sdk//:frontend_server.snapshot",
            allow_single_file = True,
        ),
        "_sdk_version": attr.label(
            default = "@flutter_sdk//:flutter.version.json",
            allow_single_file = True,
            doc = """Active SDK identity, content-hashed.

Carries frameworkRevision (a git commit hash), so this action dirties on any
framework commit — including framework-only commits where the engine artifacts
are byte-identical and would not otherwise move. This is the framework-source
half of the input set that is not declared file-by-file.""",
        ),
        "_platform_product": attr.label(
            default = "@flutter_sdk//:platform_product",
            allow_files = True,
        ),
        "_platform_debug": attr.label(
            default = "@flutter_sdk//:platform_debug",
            allow_files = True,
        ),
        "_mode": attr.label(
            default = "//tools/flutter:mode",
            providers = [BuildSettingInfo],
            doc = """Build mode, read from //tools/flutter:mode. Governs both
compiler flags and cache policy.

Release output is stripped of absolute paths by gen_snapshot, so it is safe to
share through a remote cache. Debug kernels embed source URIs and ship verbatim,
so debug actions are tagged `local` and never cached remotely.

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
        executable = ctx.executable.gen_snapshot,
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
        "gen_snapshot": attr.label(
            mandatory = True,
            executable = True,
            cfg = "exec",
            allow_single_file = True,
            doc = "The ABI's gen_snapshot; see //tools/flutter:abis.bzl.",
        ),
        "snapshot_flags": attr.string_list(
            doc = """Extra gen_snapshot flags for this ABI.

Table-driven rather than derived here: armv7 is the only ABI that needs any,
and omitting them yields a snapshot that installs and then executes an
unsupported instruction.""",
        ),
    },
)

def flutter_aot_library(name, srcs, abis, pubspec, entrypoint, package_config, pub_stamp = [], path_deps = [], dart_plugin_registrant = None, target_os = "android", strip = True, **kwargs):
    """Convenience wrapper: Dart sources straight through to libapp.so.

    Produces an AOT-shaped `.dill` and its `libapp.so` per ABI. `dart_kernel`'s
    `--aot`/`--tfa` branch is what gen_snapshot needs; it is selected by the
    ambient `//tools/flutter:mode`, not pinned here. Under `mode=debug` this
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
      package_config: the .dart_tool/package_config.json from `pub get`.
      pub_stamp: extra .dart_tool metadata declared for invalidation.
      path_deps: sources of `path:` dependencies.
      dart_plugin_registrant: the Dart plugin registrant under lib/, as a label.
      target_os: OS the kernel is compiled for; see dart_kernel.
      strip: drop DWARF from each ELF.
      **kwargs: shared rule attributes.
    """
    check_abis(abis, "flutter_aot_library " + name)

    # Avoid passing target_compatible_with twice.
    caller_compatible_with = kwargs.pop("target_compatible_with", [])

    dart_kernel(
        name = name + "_kernel",
        srcs = srcs,
        pubspec = pubspec,
        entrypoint = entrypoint,
        package_config = package_config,
        pub_stamp = pub_stamp,
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
            gen_snapshot = aot_gen_snapshot(abi),
            snapshot_flags = ABIS[abi].snapshot_flags,
            strip = strip,
            # AOT targets are incompatible with debug; retain caller constraints.
            target_compatible_with = caller_compatible_with + aot_target_compatible_with(),
            **kwargs
        )

# What `flutter pub get` writes, at the paths pub fixes. Declared for
# invalidation: identity stamps rather than the pub-cache contents themselves,
# which nothing here models. See the invalidation section of README.md.
_PUB_STAMP = [
    ".dart_tool/version",
    ".dart_tool/package_graph.json",
    "pubspec.lock",
]

# Distinguishes the documented default from a caller deliberately opting out.
# `None` remains an explicit no-registrant declaration.
_DEFAULT_DART_PLUGIN_REGISTRANT = struct()

# buildifier: disable=unnamed-macro
# Deliberately unnamed: every target it declares is named by convention, because
# the Android half derives those names (`//<pkg>:app`, `:assets`, `:pubspec`)
# from the package alone. A `name` parameter would be a knob that cannot vary --
# passing one produced `:myapp_arm64-v8a` while the APK still asked for
# `:app_arm64-v8a`. One Flutter app per package, which is also one pubspec per
# package.
def flutter_app(
        abis = None,
        path_deps = [],
        srcs = None,
        assets = None,
        entrypoint = "lib/main.dart",
        dart_plugin_registrant = _DEFAULT_DART_PLUGIN_REGISTRANT,
        pub_stamp = None,
        plugin_deps = "//:plugin_deps.MODULE.bazel",
        target_os = "android",
        **kwargs):
    """The Dart half of a Flutter app: one call, in the app's own package.

    Everything a standard `flutter create` + `flutter pub get` layout fixes is a
    default here -- the entrypoint, the package config, the pub stamp triple, the
    source and asset globs, the committed Dart registrant, and pubspec.yaml.
    What is left is what only the app knows:

        flutter_app(
            abis = ["arm64-v8a"],
            path_deps = ["//packages/mylib:srcs"],
        )

    Produces, in the calling package:

    | target | what |
    | --- | --- |
    | `:pubspec` | the package name and version, read once from pubspec.yaml |
    | `:app_<abi>` | the AOT snapshot per ABI |
    | `:assets` | the asset bundle, built for every ABI |
    | `:path_deps_check` | fails if a `path:` dependency is undeclared |
    | `:plugins_check` | fails if the committed Maven coordinates drifted |
    | `:dart_registrant_check` | fails if the committed registrant drifted |
    | `:guards_test` | the guards, under `bazel test` |

    `:app_<abi>` and `:assets` compile to their debug shape under
    `--@rules_flutter//tools/flutter:mode=debug`; see
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
      pub_stamp: invalidation stamps. Defaults to pub's own three files.
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
    # root. These used to look overridable here while only kernel compilation
    # honoured the alternate paths, producing two halves from different project
    # state. Name the unsupported knobs rather than forwarding them through
    # **kwargs to an unrelated target and failing opaquely.
    for unsupported in ("pubspec", "package_config"):
        if unsupported in kwargs:
            fail(
                (
                    "flutter_app: no `{}` override -- `flutter build bundle` " +
                    "reads the standard-layout {} directly and exposes no " +
                    "option to relocate it. Use the lower-level rules if the " +
                    "Dart half alone has a nonstandard layout."
                ).format(
                    unsupported,
                    "pubspec.yaml" if unsupported == "pubspec" else ".dart_tool/package_config.json",
                ),
            )

    if dart_plugin_registrant == _DEFAULT_DART_PLUGIN_REGISTRANT:
        dart_plugin_registrant = None if plugin_deps == None else "lib/dart_plugin_registrant.dart"

    if srcs == None:
        srcs = native.glob(["lib/**/*.dart"])
    if assets == None:
        assets = native.glob(["assets/**"])
    if pub_stamp == None:
        pub_stamp = _PUB_STAMP

    flutter_pubspec(src = "pubspec.yaml", **kwargs)

    flutter_aot_library(
        name = "app",
        srcs = srcs,
        abis = abis,
        pubspec = ":pubspec",
        entrypoint = entrypoint,
        package_config = ".dart_tool/package_config.json",
        pub_stamp = pub_stamp,
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
        package_config = ".dart_tool/package_config.json",
        pub_stamp = pub_stamp,
        path_deps = path_deps,
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
        pub_plugins_check(
            name = "plugins_check",
            committed = plugin_deps,
            expected = "@flutter_plugins//:plugin_deps.MODULE.bazel",
            **kwargs
        )
        guards.append(":plugins_check")

        if dart_plugin_registrant:
            pub_plugins_check(
                name = "dart_registrant_check",
                committed = dart_plugin_registrant,
                expected = "@flutter_plugins//:dart_plugin_registrant.dart",
                **kwargs
            )
            guards.append(":dart_registrant_check")

    # The guards fail as *actions*, which is stronger than a test: anything
    # depending on one fails too, and the result is remote-cacheable. build_test
    # does not change that -- it only gives `bazel test` a reason to build them.
    build_test(
        name = "guards_test",
        targets = guards,
        **kwargs
    )

def _bundle_dir(ctx, out, abi, index):
    """Where one ABI's bundle goes.

    The first is the declared output itself, so the shared files are written
    once rather than copied in afterwards; the rest go beside it and exist only
    to be compared and to have their manifests read.
    """
    if index == 0:
        return out.path
    return "{}/{}.abi_{}".format(out.dirname, ctx.label.name, abi)

def _bundle_command(ctx, out, abi, index):
    return """"$EXECROOT/{flutter}" build bundle \
    --{mode} \
    --no-pub \
    --target="$ENTRYPOINT" \
    --target-platform={platform} \
    --asset-dir="$EXECROOT/{dir}" \
    --suppress-analytics >/dev/null
rm -f "$EXECROOT/{dir}/.last_build_id"
rm -rf "$EXECROOT/{dir}/native_assets"
""".format(
        flutter = ctx.file._flutter.path,
        mode = ctx.attr._mode[BuildSettingInfo].value,
        platform = ABIS[abi].target_platform,
        dir = _bundle_dir(ctx, out, abi, index),
    )

def _flutter_assets_impl(ctx):
    # The directory must be named flutter_assets: android_binary derives the
    # in-APK path from the artifact path with assets_dir stripped, and Flutter
    # requires the bundle at assets/flutter_assets/ at runtime.
    out = ctx.actions.declare_directory(ctx.label.name + "/flutter_assets")

    entrypoint = _project_path(ctx, ctx.file.entrypoint, "entrypoint")
    args = ctx.actions.args()
    args.add(entrypoint)

    stage_manifest_files = (
        [
            ctx.file.entrypoint,
            ctx.file.package_config,
            ctx.attr.pubspec[FlutterPubspecInfo].src,
        ] +
        ctx.files.assets + ctx.files.srcs + ctx.files.pub_stamp +
        ctx.files.path_deps
    )

    # Keep package_config staged but undeclared: its pub-cache and SDK rootUris
    # are machine-specific. Invalidation rests on pub_stamp, as in dart_kernel;
    # reading it requires this rule's existing no-sandbox execution.
    declared_project_files = [
        f
        for f in stage_manifest_files
        if f != ctx.file.package_config
    ]

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

cd "$STAGE/{project_dir}"
{bundles}
exec python3 "$EXECROOT/{merger}" {merge_args}
""".format(
        project_dir = project_dir,
        android_sdk = ctx.file._android_sdk.path,
        manifest = manifest.path,
        merger = ctx.file._merger.path,
        bundles = "\n".join([_bundle_command(ctx, out, abi, i) for i, abi in enumerate(ctx.attr.abis)]),
        merge_args = " ".join([
            '--bundle "{}=$EXECROOT/{}"'.format(abi, _bundle_dir(ctx, out, abi, i))
            for i, abi in enumerate(ctx.attr.abis)
        ]),
    )

    mode = ctx.attr._mode[BuildSettingInfo].value
    ctx.actions.run_shell(
        command = cmd,
        arguments = [args],
        inputs = depset(
            direct = declared_project_files + [manifest, ctx.file._sdk_version, ctx.file._merger, ctx.file._flutter, ctx.file._android_sdk],
        ),
        outputs = [out],
        mnemonic = "FlutterAssets",
        progress_message = "Bundling Flutter assets (%s) %%{label}" % mode,
        execution_requirements = _exec_requirements(mode),
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
        "package_config": attr.label(allow_single_file = True, mandatory = True),
        "pub_stamp": attr.label_list(allow_files = True),
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
            default = "//tools/flutter:_android_sdk_marker",
            allow_single_file = True,
            cfg = "exec",
        ),
        "_flutter": attr.label(
            default = "@flutter_sdk//:flutter",
            allow_single_file = True,
        ),
        "_merger": attr.label(
            default = "//tools/flutter:merge_native_assets.py",
            allow_single_file = True,
        ),
        "_mode": attr.label(
            default = "//tools/flutter:mode",
            providers = [BuildSettingInfo],
            doc = "See dart_kernel._mode. Debug bundles ship kernel_blob.bin.",
        ),
        "_sdk_version": attr.label(
            default = "@flutter_sdk//:flutter.version.json",
            allow_single_file = True,
        ),
    },
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
            default = "//tools/flutter:check_path_deps.py",
            allow_single_file = True,
        ),
    },
)

def _pub_plugins_check_impl(ctx):
    marker = ctx.actions.declare_file(ctx.label.name + ".checked")

    ctx.actions.run_shell(
        command = """
set -eu
expected="$1"; committed="$2"; marker="$3"
if ! diff -u "$committed" "$expected" > /dev/null 2>&1; then
    echo "ERROR: $committed is out of date." >&2
    echo "" >&2
    echo "The Flutter plugins in pubspec.yaml declare Maven coordinates that do" >&2
    echo "not match the committed MODULE.bazel segment. Replace it with:" >&2
    echo "" >&2
    sed 's/^/    /' "$expected" >&2
    echo "" >&2
    diff -u "$committed" "$expected" >&2 || true
    exit 1
fi
touch "$marker"
""",
        arguments = [ctx.file.expected.path, ctx.file.committed.path, marker.path],
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
    },
)
