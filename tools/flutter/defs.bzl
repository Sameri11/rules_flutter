"""Rules for the Dart half of a Flutter build.

The Flutter build decomposes into two independent halves:

  1. Dart:     .dart sources -> app.dill (kernel) -> libapp.so (AOT ELF)
  2. Platform: libapp.so + libflutter.so + flutter_assets -> APK/IPA

These rules cover half 1 only, producing a plain `cc`-consumable .so that
rules_android / rules_apple can package in half 2. Nothing here shells out to
`flutter build`; the underlying frontend_server and gen_snapshot are driven
directly.

Sandboxing caveat
-----------------
`package_config.json` points at absolute paths in ~/.pub-cache and the Flutter
SDK, neither of which is a declared Bazel input. These actions therefore run
unsandboxed. Making them hermetic means modelling pub packages as Bazel repos
(a pub -> MODULE.bazel resolver), which is the genuinely hard part of this
problem and is not attempted here.
"""

load("@flutter_sdk//:sdk.bzl", "FLUTTER_BIN", "FLUTTER_ENV")
load("@rules_cc//cc:find_cc_toolchain.bzl", "find_cpp_toolchain", "use_cc_toolchain")

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

def _dart_kernel_impl(ctx):
    dill = ctx.actions.declare_file(ctx.label.name + ".dill")
    release = ctx.attr.mode != "debug"

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
        fail("platform_strong.dill not found for mode '{}'".format(ctx.attr.mode))

    args = ctx.actions.args()
    args.add(ctx.file._frontend_server)
    args.add("--sdk-root", sdk_root + "/")
    args.add("--target", "flutter")
    if release:
        # AOT + tree-shaking + product mode. Debug keeps a full kernel, which is
        # shipped as kernel_blob.bin rather than snapshotted.
        args.add("--aot")
        args.add("--tfa")
        args.add("-Ddart.vm.product=true")
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
    # addressed through the package config instead, exactly like entrypoint_uri.
    if ctx.attr.dart_plugin_registrant_uri:
        args.add("--source", ctx.attr.dart_plugin_registrant_uri)
        args.add("--source", "package:flutter/src/dart_plugin_registrant.dart")
        args.add("-Dflutter.dart_plugin_registrant={}".format(
            ctx.attr.dart_plugin_registrant_uri,
        ))

    args.add("--output-dill", dill)
    args.add(ctx.attr.entrypoint_uri)

    ctx.actions.run(
        executable = ctx.executable._dartaotruntime,
        arguments = [args],
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
            ] + ctx.files.pub_stamp + ctx.files.path_deps,
            transitive = [platform.files, depset(ctx.files.srcs)],
        ),
        outputs = [dill],
        mnemonic = "DartKernel",
        progress_message = "Compiling Dart kernel (%s) %%{label}" % ctx.attr.mode,
        execution_requirements = _exec_requirements(ctx.attr.mode),
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
        "entrypoint_uri": attr.string(
            mandatory = True,
            doc = "Entrypoint as a package URI, e.g. package:demo_app/main.dart.",
        ),
        "dart_plugin_registrant_uri": attr.string(
            doc = """Package URI of the generated Dart plugin registrant.

e.g. package:demo_app/dart_plugin_registrant.dart. Registers the Dart half of
federated plugins. Like entrypoint_uri this is a URI, not a label -- the file
itself arrives through srcs. Must be a package: URI so the value the engine
looks up is machine-independent. Omit for an app with no federated plugins.""",
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
        "mode": attr.string(
            default = "release",
            values = ["release", "debug"],
            doc = """Build mode. Governs both compiler flags and cache policy.

Release output is stripped of absolute paths by gen_snapshot, so it is safe to
share through a remote cache. Debug kernels embed source URIs and ship verbatim,
so debug actions are tagged `local` and never cached remotely.""",
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
        executable = ctx.executable._gen_snapshot,
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
        "_gen_snapshot": attr.label(
            default = "@flutter_sdk//:gen_snapshot_android_arm64",
            executable = True,
            cfg = "exec",
            allow_single_file = True,
        ),
    },
)

def flutter_aot_library(name, srcs, entrypoint_uri, package_config, pub_stamp = [], path_deps = [], dart_plugin_registrant_uri = "", strip = True, **kwargs):
    """Convenience wrapper: Dart sources straight through to libapp.so.

    Release-only: debug builds ship kernel_blob.bin and never run gen_snapshot,
    so there is no AOT ELF to produce.

    Every rule-specific attribute is a named parameter here, and **kwargs
    carries only what both targets should share -- visibility, tags. Forwarding
    kwargs to both instead means an attribute that exists on only one of them
    cannot be passed at all, which stops being a footnote as soon as either rule
    grows a per-platform or per-ABI attribute.
    """
    dart_kernel(
        name = name + "_kernel",
        srcs = srcs,
        entrypoint_uri = entrypoint_uri,
        package_config = package_config,
        pub_stamp = pub_stamp,
        path_deps = path_deps,
        dart_plugin_registrant_uri = dart_plugin_registrant_uri,
        mode = "release",
        **kwargs
    )
    dart_aot_elf(
        name = name,
        dill = ":" + name + "_kernel",
        strip = strip,
        **kwargs
    )

def _flutter_assets_impl(ctx):
    # The directory must be named flutter_assets: android_binary derives the
    # in-APK path from the artifact path with assets_dir stripped, and Flutter
    # requires the bundle at assets/flutter_assets/ at runtime.
    out = ctx.actions.declare_directory(ctx.label.name + "/flutter_assets")

    project_files = (
        [ctx.file.package_config, ctx.file.pubspec] +
        ctx.files.assets + ctx.files.srcs + ctx.files.pub_stamp +
        ctx.files.path_deps
    )

    # The set of files to stage, one execroot-relative path per line. Written to
    # a file rather than passed as arguments so the command cannot overflow the
    # argument limit on a large app.
    manifest = ctx.actions.declare_file(ctx.label.name + ".stage_manifest")
    ctx.actions.write(
        manifest,
        "".join([f.path + "\n" for f in project_files]),
    )

    # Staging, rather than running in the package directory.
    #
    # The execroot entry for a package is a symlink to the source tree, so `cd
    # {pkg}` would put flutter_tools inside the user's sources, where it writes
    # .dart_tool/flutter_build/<hash>/ -- an undeclared output that survives
    # `bazel clean` and races between concurrent asset targets.
    #
    # Each input is copied to its *execroot-relative* path inside the stage,
    # which preserves the workspace layout. That matters: package_config.json
    # resolves path dependencies relatively (mylib is ../../packages/mylib), so
    # staging only the app directory would break them. Hosted packages are
    # unaffected, their rootUris being absolute into ~/.pub-cache.
    #
    # One tar reads the manifest, another extracts, and the archive crosses a
    # memory pipe without touching disk. This replaced a per-file `mkdir -p` +
    # `cp` loop that spawned two processes per input: 1546 files took ~9s, and
    # the tar pipe takes ~0.95s. `-T` is supported by both bsdtar and GNU tar,
    # which is why this rather than `pax` (marginally faster, but not installed
    # everywhere) or `rsync` (slower, and macOS 15 swapped it for openrsync).
    #
    # Deliberately uncompressed. The archive only ever crosses a pipe, so a
    # filter can shrink the one part of the transfer that was already free while
    # charging CPU on both ends -- measured, gzip costs +0.7s and xz +6.6s. Two
    # filters are worse than slow: bsdtar pads its output to the 10240-byte
    # block size when writing to a pipe, and zstd and lz4 are external programs
    # here rather than linked-in, so their decompressor hits that padding, fails
    # with ERROR_frameType_unknown, and drops the tail of the archive. The
    # `pipefail` above is what turns that into a failed build rather than a
    # stage silently missing files. See docs_internal/staging-experiments.md.
    #
    # Sources may be read-only, hence chmod.
    #
    # --no-pub matters: `flutter build` runs pub get by default, which would put
    # implicit dependency resolution -- and a possible network call -- inside a
    # Bazel action. Resolution is the caller's job.
    #
    # .last_build_id is flutter_tools bookkeeping and is the only file in the
    # bundle that varies between otherwise identical runs. Removing it makes the
    # tree artifact reproducible.
    #
    # native_assets/ is dropped for a different reason: it does not belong in a
    # bundle at all. When a package produces a code asset through a Dart build
    # hook, `flutter build bundle` runs the hook and writes the resulting library
    # to native_assets/jniLibs/lib/<abi>/, *inside* the asset tree -- where the
    # dynamic loader cannot reach it, because APK assets are read through
    # AssetManager rather than mapped. `flutter assemble` puts that same tree
    # *beside* the bundle, for Gradle to package as a JNI library.
    #
    # Here the library reaches lib/<abi>/ through a package recipe instead (see
    # docs/package-recipes.md), so leaving this copy would ship the same bytes
    # twice -- 1.8 MB for sqlite3 alone -- and would also keep the bundle one
    # file larger than the reference `flutter assemble` produces.
    #
    # NativeAssetsManifest.json is a *sibling* of this directory and is
    # deliberately kept: it is the id -> filename mapping the engine reads at
    # runtime, and it is correct as written. Only the misplaced library goes.
    cmd = """set -euo pipefail
EXECROOT="$PWD"
STAGE="$(mktemp -d "${{TMPDIR:-/tmp}}/flutter_assets.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

tar -cf - -T "{manifest}" | (cd "$STAGE" && tar -xf -)
chmod -R u+w "$STAGE"

cd "$STAGE/{pkg}"
"{flutter}" build bundle \
    --{mode} \
    --no-pub \
    --target-platform={platform} \
    --asset-dir="$EXECROOT/{out}" \
    --suppress-analytics >/dev/null
rm -f "$EXECROOT/{out}/.last_build_id"
rm -rf "$EXECROOT/{out}/native_assets"
""".format(
        pkg = ctx.label.package,
        manifest = manifest.path,
        mode = ctx.attr.mode,
        flutter = FLUTTER_BIN,
        platform = ctx.attr.target_platform,
        out = out.path,
    )

    ctx.actions.run_shell(
        command = cmd,
        inputs = depset(
            direct = project_files + [manifest, ctx.file._sdk_version],
        ),
        outputs = [out],
        env = FLUTTER_ENV,
        mnemonic = "FlutterAssets",
        progress_message = "Bundling Flutter assets (%s) %%{label}" % ctx.attr.mode,
        execution_requirements = _exec_requirements(ctx.attr.mode),
    )

    return [DefaultInfo(files = depset([out]))]

flutter_assets = rule(
    implementation = _flutter_assets_impl,
    doc = """Produces a flutter_assets/ tree (AssetManifest.bin, FontManifest.json,
NOTICES.Z, fonts, shaders, declared assets) for packaging into an APK.

Unlike the Dart half, this shells out to `flutter build bundle`. There is no
standalone asset-bundler binary: asset resolution, font manifests and license
aggregation all live inside flutter_tools. `--asset-dir` is the documented
entry point for driving it from another build system.""",
    attrs = {
        "srcs": attr.label_list(allow_files = [".dart"]),
        "assets": attr.label_list(
            allow_files = True,
            doc = "Files declared under `assets:` in pubspec.yaml.",
        ),
        "pubspec": attr.label(allow_single_file = True, mandatory = True),
        "package_config": attr.label(allow_single_file = True, mandatory = True),
        "pub_stamp": attr.label_list(allow_files = True),
        "path_deps": attr.label_list(
            allow_files = True,
            doc = "See dart_kernel.path_deps.",
        ),
        "target_platform": attr.string(default = "android-arm64"),
        "mode": attr.string(
            default = "release",
            values = ["release", "debug"],
            doc = "See dart_kernel.mode. Debug bundles ship kernel_blob.bin.",
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
        env = FLUTTER_ENV,
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

def _native_assets_check_impl(ctx):
    marker = ctx.actions.declare_file(ctx.label.name + ".checked")

    # The manifest lives inside the asset tree artifact, so its path is derived
    # rather than declared. flutter_tools writes it at the bundle root --
    # `additionalContent: {'NativeAssetsManifest.json': ...}` in
    # build_system/targets/common.dart.
    manifest = ctx.file.assets.path + "/NativeAssetsManifest.json"

    args = ctx.actions.args()
    args.add(ctx.file._checker)
    args.add("--manifest", manifest)
    args.add("--jar", ctx.file.native_libs)
    args.add("--out", marker)

    ctx.actions.run_shell(
        command = 'exec python3 "$@"',
        arguments = [args],
        inputs = [ctx.file.assets, ctx.file.native_libs, ctx.file._checker],
        outputs = [marker],
        env = FLUTTER_ENV,
        mnemonic = "NativeAssetsCheck",
        progress_message = "Checking Dart code assets %{label}",
    )

    return [DefaultInfo(files = depset([marker]))]

native_assets_check = rule(
    implementation = _native_assets_check_impl,
    doc = """Fails the build if a Dart code asset has no library behind it.

A package with a build hook declares an asset id; the Dart VM resolves it to a
filename through the bundle's NativeAssetsManifest.json and dlopens that name
from lib/<abi>/. Nothing else connects the two halves -- the manifest comes from
flutter_tools, the library only from a package recipe -- so a package with no
recipe builds green and dies on its first FFI call.

Cheap enough to depend on from the app; see //app:native_assets_check.""",
    attrs = {
        "assets": attr.label(
            allow_single_file = True,
            mandatory = True,
            doc = "A flutter_assets tree artifact.",
        ),
        "native_libs": attr.label(
            allow_single_file = True,
            mandatory = True,
            doc = "The jar of recipe-contributed libraries, @flutter_plugins//:native_libs_jar.",
        ),
        "_checker": attr.label(
            default = "//tools/flutter:check_native_assets.py",
            allow_single_file = True,
        ),
    },
)

def _jni_lib_jar_impl(ctx):
    jar = ctx.actions.declare_file(ctx.label.name + ".jar")

    # android_binary sources native libraries from cc_library deps, but it also
    # extracts lib/<abi>/*.so from jars on the classpath -- which is how the
    # prebuilt engine artifact (arm64_v8a_release.jar) ships libflutter.so.
    # Packaging libapp.so the same way avoids standing up an Android CC
    # toolchain just to carry one prebuilt shared object.
    ctx.actions.run_shell(
        command = """set -euo pipefail
STAGE="$(mktemp -d "${{TMPDIR:-/tmp}}/jnilib.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/lib/{abi}"
cp "{so}" "$STAGE/lib/{abi}/{soname}"
# -X drops extra attributes; entries are added in a fixed order so the jar is
# reproducible.
( cd "$STAGE" && zip -q -X -r "$OLDPWD/{jar}" lib )
""".format(
            abi = ctx.attr.abi,
            so = ctx.file.src.path,
            soname = ctx.attr.soname or ctx.file.src.basename,
            jar = jar.path,
        ),
        inputs = [ctx.file.src],
        outputs = [jar],
        mnemonic = "JniLibJar",
        progress_message = "Packaging %{label} for Android",
    )

    return [DefaultInfo(files = depset([jar]))]

jni_lib_jar = rule(
    implementation = _jni_lib_jar_impl,
    doc = "Wraps a prebuilt .so as lib/<abi>/<name>.so inside a jar, for android_binary.",
    attrs = {
        "src": attr.label(allow_single_file = True, mandatory = True),
        "abi": attr.string(default = "arm64-v8a"),
        "soname": attr.string(doc = "Override the packaged filename."),
    },
)

def _android_platform_transition_impl(_settings, attr):
    return {"//command_line_option:platforms": [attr.platform]}

# The .so has to be built for Android whatever configuration it is reached
# from. Without this, the cmake() target is analysed in the enclosing
# configuration -- the host, when it hangs off a java_import on an
# android_library -- and rules_foreign_cc resolves the *macOS* cc_toolchain,
# feeding host linker flags to an NDK cross-compile.
#
# Transitioning here rather than relying on android_binary's own native-dep
# transition keeps this self-contained: the jar is correct by construction, so
# nothing downstream has to be configured a particular way to make it so.
_android_platform_transition = transition(
    implementation = _android_platform_transition_impl,
    inputs = [],
    outputs = ["//command_line_option:platforms"],
)

def _android_native_lib_jar_impl(ctx):
    jar = ctx.actions.declare_file(ctx.label.name + ".jar")

    # cmake() reports its whole install tree (headers included); only the
    # shared objects belong in the jar.
    sos = [
        f
        for target in ctx.attr.src
        for f in target[DefaultInfo].files.to_list()
        if f.basename.endswith(".so")
    ]
    if not sos:
        fail("{} produced no .so -- check out_shared_libs on {}".format(
            ctx.label,
            ctx.attr.src[0].label,
        ))

    cc_toolchain = find_cpp_toolchain(ctx)

    # Same mechanism as jni_lib_jar: android_binary extracts lib/<abi>/*.so from
    # jars on the classpath, so a plugin's native library rides exactly the path
    # libapp.so and libflutter.so already ride.
    #
    # Stripped on the way in. A CMake plugin's .so keeps its symbol table under
    # the NDK's release flags -- rive_common's is 4.3 MB stripping to 3.5 MB --
    # so this is not an engine-only concern.
    ctx.actions.run_shell(
        command = """set -euo pipefail
STAGE="$(mktemp -d "${{TMPDIR:-/tmp}}/jnilib.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/lib/{abi}"
for so in {sos}; do
    cp "$so" "$STAGE/lib/{abi}/"
    "{strip}" --strip-unneeded "$STAGE/lib/{abi}/$(basename "$so")"
done
( cd "$STAGE" && zip -q -X -r "$OLDPWD/{jar}" lib )
""".format(
            abi = ctx.attr.abi,
            sos = " ".join(['"{}"'.format(f.path) for f in sos]),
            jar = jar.path,
            strip = cc_toolchain.strip_executable,
        ),
        inputs = depset(sos, transitive = [cc_toolchain.all_files]),
        outputs = [jar],
        mnemonic = "AndroidNativeLibJar",
        progress_message = "Packaging native libraries %{label} for Android",
    )

    return [DefaultInfo(files = depset([jar]))]

android_native_lib_jar = rule(
    implementation = _android_native_lib_jar_impl,
    doc = """Builds a native library for Android and wraps it as lib/<abi>/*.so in a jar.

`src` is built under `platform` regardless of the configuration this target is
reached from -- see _android_platform_transition.""",
    cfg = _android_platform_transition,
    attrs = {
        "src": attr.label_list(
            mandatory = True,
            doc = "Target producing .so files, typically a rules_foreign_cc cmake().",
        ),
        "abi": attr.string(default = "arm64-v8a"),
        "platform": attr.string(
            default = "@rules_android//:arm64-v8a",
            doc = "Platform the native library is built for.",
        ),
    },
    toolchains = use_cc_toolchain(),
)

def _strip_native_libs_impl(ctx):
    stripped = ctx.actions.declare_file(ctx.label.name + ".jar")

    # The NDK's llvm-strip, resolved through the Android cc_toolchain rather
    # than hardcoded: the rule transitions to the Android platform (below), so
    # this is the cross-strip that matches the .so being stripped.
    #
    # The transition is load-bearing and its absence is not obviously wrong.
    # Analysed without it, this resolves /opt/homebrew/opt/binutils/bin/strip --
    # a host tool that happens to handle ELF, so it would produce a plausible
    # artifact on a machine that has it and fall back to the macOS strip
    # (which cannot) on one that does not.
    cc_toolchain = find_cpp_toolchain(ctx)

    # AGP does this automatically for release builds (`stripDebugSymbolsRelease`);
    # android_binary has no equivalent, which is why the engine's 156 MB of DWARF
    # was reaching the APK.
    ctx.actions.run_shell(
        command = """set -euo pipefail
STAGE="$(mktemp -d "${{TMPDIR:-/tmp}}/strip.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
unzip -q -o "{jar}" -d "$STAGE"

found=0
for so in $(find "$STAGE" -type f -name '*.so' | sort); do
    found=1
    "{strip}" --strip-unneeded "$so"
done

if [ "$found" -eq 0 ]; then
    echo "strip_native_libs: no .so found in {jar}" >&2
    echo "The jar this rule was pointed at carries no native libraries;" >&2
    echo "stripping it silently would produce a correct-looking no-op." >&2
    exit 1
fi

( cd "$STAGE" && zip -q -X -r "$OLDPWD/{out}" . )
""".format(
            jar = ctx.file.jar.path,
            out = stripped.path,
            strip = cc_toolchain.strip_executable,
        ),
        inputs = depset([ctx.file.jar], transitive = [cc_toolchain.all_files]),
        outputs = [stripped],
        mnemonic = "StripNativeLibs",
        progress_message = "Stripping native libraries %{label}",
    )

    return [DefaultInfo(files = depset([stripped]))]

strip_native_libs = rule(
    implementation = _strip_native_libs_impl,
    doc = """Strips every .so inside a jar.

The stripped jar is the default output, so it drops straight into an
android_binary's classpath where the original jar was.""",
    cfg = _android_platform_transition,
    attrs = {
        "jar": attr.label(
            allow_single_file = [".jar"],
            mandatory = True,
            doc = "Jar carrying lib/<abi>/*.so -- e.g. the Flutter engine artifact.",
        ),
        "platform": attr.string(
            default = "@rules_android//:arm64-v8a",
            doc = "Platform whose cc_toolchain supplies strip.",
        ),
    },
    toolchains = use_cc_toolchain(),
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
