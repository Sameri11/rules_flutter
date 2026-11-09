"""The core artifact: an app's Dart outputs and engine libraries, with no APK packaging.

`flutter_core` declares the platform-neutral inputs once. The kernel and the
asset bundle are built under a host platform transition, so an android_binary
with N splits runs each action once rather than once per split. The per-ABI
snapshot and engine libraries are chosen by `select()` on the split's
config_settings, so each split names only its own ABI.

The android_binary side takes the artifact through `FlutterArtifactInfo`. See
`flutter_android_inputs` for the packaging half.
"""

load("@bazel_skylib//lib:shell.bzl", "shell")
load("@bazel_skylib//rules:build_test.bzl", "build_test")
load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load(":abis.bzl", "ABIS", "ABI_PLATFORM_ATTRS", "MODES", "abi_from_platform", "aot_target_compatible_with", "engine_libs_label")
load(":pubspec.bzl", "FlutterPubspecInfo", "flutter_pubspec")
load(":rules.bzl", "dart_aot_elf", "dart_aot_kernel", "dart_jit_kernel", "flutter_assets", "flutter_package", "flutter_test_assets", "lib_root", "library_path", "pub_path_deps_check", "pub_plugins_check")

visibility(["//flutter/...", "//tests/..."])

_TOOLCHAIN = "//flutter/private:flutter_toolchain_type"

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
                "flutter_core: destination label {} belongs to repository {}, but " +
                "BUILD_WORKSPACE_DIRECTORY can only update files in the invoking " +
                "workspace."
            ).format(requested, label.repo_name),
        )
    return label

FlutterArtifactInfo = provider(
    doc = "What flutter_core hands to the android_binary split that built it.",
    fields = {
        "mode": "`release` or `debug`.",
        "abi": "The Android ABI of this split, or None on a host build.",
        "libapp": "File: the libapp.so of this ABI, or None under debug.",
        "engine_libs": "list of File: this ABI's engine .so files, unstripped.",
        "assets": "Directory: the flutter_assets bundle, with the debug overlay under debug.",
    },
)

FlutterCoreInfo = provider(
    doc = "What a flutter_debug_core needs from its app: the kernel inputs and the debug registrant.",
    fields = {
        "package_config": "File: the pub hub's package_config.json.",
        "pub_srcs": "list of File: the hub's packageUri trees.",
        "srcs": "list of File: the app's Dart sources, for change detection.",
        "path_deps": "list of File: sources of path dependencies.",
        "debug_registrant": "File or None: the debug plugin registrant.",
        "registrant_path": "str: the registrant's path within its package, as a package: URI suffix.",
        "lib": "str: the app's lib/ prefix in the execroot; an entrypoint under it compiles as package:, under its own name.",
        "mode_free_assets": "File: the app's flutter_assets tree before any debug overlay, platform neutral.",
    },
)

def _split_label(abi, mode):
    # A Label, not a string: select() keys in a macro resolve in the caller's
    # repo mapping, and these config_settings belong to this ruleset.
    return Label("//flutter/private:split_{}_{}".format(abi.replace("-", "_"), mode))

_ANDROID_SPLIT_OUTPUTS = [
    # The options the Android split transition writes. The kernel and the bundle
    # must not inherit any of them from whichever split asked. rules_android's
    # bytecode_transformer flag is not in this list: core cannot name a
    # rules_android label (D9). A consumer that sets it gets a second kernel and
    # bundle configuration beside the split's, rather than one shared with the host.
    "//command_line_option:Android configuration distinguisher",
    "//command_line_option:android_compiler",
    "//command_line_option:android_platforms",
    "//command_line_option:compiler",
    "//command_line_option:dynamic_mode",
    "//command_line_option:platforms",
]

def _platform_neutral_transition_impl(_settings, _attr):
    # One configuration for the kernel and the bundle, whichever split asks.
    # Each value is the one a non-Android host configuration has. Setting only
    # the platform left the distinguisher and dynamic_mode from the split, so
    # the bundle was built twice.
    return {
        "//command_line_option:Android configuration distinguisher": "main",
        "//command_line_option:android_compiler": None,
        "//command_line_option:android_platforms": [],
        "//command_line_option:compiler": None,
        "//command_line_option:dynamic_mode": "default",
        "//command_line_option:platforms": ["@platforms//host:host"],
    }

_platform_neutral_transition = transition(
    implementation = _platform_neutral_transition_impl,
    inputs = [],
    outputs = _ANDROID_SPLIT_OUTPUTS,
)

def _platform_neutral_files_impl(ctx):
    # The transition yields one configuration, and Bazel hands a transitioned
    # label attr back as a list of them.
    (src,) = ctx.attr.src
    return [DefaultInfo(files = src[DefaultInfo].files)]

platform_neutral_files = rule(
    implementation = _platform_neutral_files_impl,
    doc = "Passes a target's files through, built under the host platform.",
    attrs = {
        "src": attr.label(
            mandatory = True,
            cfg = _platform_neutral_transition,
        ),
    },
)

def assets_bundle_action(ctx, src, kernel_files):
    """Declares the flutter_assets tree of `src`, with the debug overlay of the kernel when given.

    Shared by assets_bundle and flutter_debug_core, so the app's bundle and a
    test bundle run the same copy and overlay.

    Args:
      ctx: the rule context; its toolchain supplies the engine snapshots.
      src: File: the mode-free flutter_assets tree to copy.
      kernel_files: list of File: the JIT kernel under debug, or None under release.

    Returns:
      The declared flutter_assets directory File.
    """
    toolchain = ctx.toolchains[_TOOLCHAIN].flutter
    out = ctx.actions.declare_directory(ctx.label.name + "/flutter_assets")

    inputs = [src]
    command = 'mkdir -p "{out}" && cp -RL "{src}"/. "{out}"/'.format(out = out.path, src = src.path)

    if kernel_files != None:
        # The debug overlay: the JIT kernel and the host engine's snapshots,
        # under the names the engine looks for. Release ships no overlay.
        (kernel,) = kernel_files
        inputs += [kernel, toolchain.vm_isolate_snapshot, toolchain.isolate_snapshot]
        command += ' && cp "{k}" "{out}/kernel_blob.bin" && cp "{vm}" "{out}/vm_snapshot_data" && cp "{iso}" "{out}/isolate_snapshot_data"'.format(
            k = kernel.path,
            out = out.path,
            vm = toolchain.vm_isolate_snapshot.path,
            iso = toolchain.isolate_snapshot.path,
        )

    ctx.actions.run_shell(
        outputs = [out],
        inputs = inputs,
        command = command,
        mnemonic = "FlutterAssetBundle",
        progress_message = "Bundling Flutter assets %{label}",
    )
    return out

def _assets_bundle_impl(ctx):
    mode = ctx.attr._mode[BuildSettingInfo].value
    (src,) = ctx.files.src
    kernel = ctx.files.kernel if mode == "debug" else None
    return [DefaultInfo(files = depset([assets_bundle_action(ctx, src, kernel)]))]

assets_bundle = rule(
    implementation = _assets_bundle_impl,
    doc = "The flutter_assets tree the APK packages, with the debug overlay under debug.",
    attrs = {
        "src": attr.label(mandatory = True, allow_files = True),
        "kernel": attr.label_list(allow_files = True, doc = "The JIT kernel, under debug only."),
        "_mode": attr.label(default = Label("//flutter:mode"), providers = [BuildSettingInfo]),
    },
    toolchains = [_TOOLCHAIN],
)

def _flutter_core_impl(ctx):
    mode = ctx.attr._mode[BuildSettingInfo].value
    abi = abi_from_platform(ctx)
    libapp = ctx.files.libapp
    engine_libs = ctx.files.engine_libs
    assets = ctx.attr.assets[DefaultInfo].files.to_list()
    (mode_free_assets,) = ctx.files.mode_free_assets
    if len(assets) != 1:
        fail("{}: expected one assets directory, got {}".format(ctx.label, len(assets)))
    if len(libapp) > 1:
        fail("{}: expected at most one libapp.so, got {}".format(ctx.label, len(libapp)))
    if abi != None:
        if not engine_libs:
            fail("{}: ABI '{}' has no engine libraries".format(ctx.label, abi))
        if mode == "release" and len(libapp) != 1:
            fail("{}: release ABI '{}' needs one libapp.so".format(ctx.label, abi))

    return [
        DefaultInfo(files = depset(libapp + engine_libs + [assets[0]])),
        OutputGroupInfo(
            flutter_assets = depset([assets[0]]),
            flutter_engine = depset(engine_libs),
            flutter_libapp = depset(libapp),
        ),
        FlutterArtifactInfo(
            mode = mode,
            abi = abi,
            libapp = libapp[0] if libapp else None,
            engine_libs = engine_libs,
            assets = assets[0],
        ),
        FlutterCoreInfo(
            package_config = ctx.file.package_config,
            pub_srcs = ctx.files.pub_srcs,
            srcs = ctx.files.srcs,
            path_deps = ctx.files.path_deps,
            debug_registrant = ctx.file.debug_registrant,
            registrant_path = library_path(ctx, ctx.file.debug_registrant, "dart_plugin_registrant") if ctx.file.debug_registrant else "",
            lib = lib_root(ctx.label),
            mode_free_assets = mode_free_assets,
        ),
        ctx.attr.pubspec[FlutterPubspecInfo],
    ]

_flutter_core = rule(
    implementation = _flutter_core_impl,
    doc = "Collects one split's view of a flutter_core into FlutterArtifactInfo.",
    attrs = dict(
        {
            "libapp": attr.label_list(allow_files = True, doc = "The dart_aot_elf of this split's ABI; empty under debug and on a host build."),
            "engine_libs": attr.label_list(allow_files = True, doc = "This split's engine .so files; empty on a host build."),
            "assets": attr.label(mandatory = True, doc = "The platform-neutral bundle."),
            "mode_free_assets": attr.label(allow_files = True, mandatory = True, cfg = _platform_neutral_transition, doc = "The flutter_assets tree before any debug overlay, built under the host platform. A flutter_debug_core overlays its own kernel on it, so the app's assets label is never named outside this package."),
            "pubspec": attr.label(mandatory = True, providers = [FlutterPubspecInfo]),
            "package_config": attr.label(allow_single_file = True, mandatory = True, doc = "The pub hub's package_config.json, read by a flutter_debug_core's kernel."),
            "pub_srcs": attr.label_list(allow_files = True, allow_empty = False, mandatory = True, doc = "The pub hub's :lib, read by a flutter_debug_core's kernel."),
            "srcs": attr.label_list(allow_files = [".dart"], doc = "Dart sources for change detection in a flutter_debug_core's kernel."),
            "path_deps": attr.label_list(allow_files = True, doc = "Sources of path dependencies, as the kernels take them."),
            "debug_registrant": attr.label(allow_single_file = [".dart"], doc = "The debug registrant, as dart_jit_kernel takes it."),
            "_mode": attr.label(default = Label("//flutter:mode"), providers = [BuildSettingInfo]),
        },
        **ABI_PLATFORM_ATTRS
    ),
)

def _pub_labels(pub, who):
    if not pub or not pub.startswith("@") or "//" in pub or ":" in pub:
        fail((
            "{}: `pub` must be the repository of a `pub.lock` hub, e.g. \"@pub\" " +
            "(from `pub = use_extension(\"@rules_flutter_core//flutter:extensions.bzl\", \"pub\")`), got {}."
        ).format(who, repr(pub)))
    return (pub + "//:package_config.json", pub + "//:project_package_config.json", pub + "//:lib", pub + "//:all")

def flutter_core(
        name,
        pub,
        assets = None,
        entrypoint = "lib/main.dart",
        srcs = None,
        path_deps = [],
        dart_defines = {},
        native_build_env = None,
        dart_plugin_registrant = None,
        **kwargs):
    """Declares an app's Flutter artifacts and host-test inputs.

    Standard-layout packages derive Dart sources from `lib/` and assets from
    `assets/`. The fixed `pubspec.yaml`, package/test targets, and guards are
    declared with the artifacts so the package has one core. App AOT selects
    its kernel from the configured Target OS; host tests and asset views need
    no app Target OS.

    Args:
      name: the artifact's target name. `pubspec` is reserved.
      pub: the `pub.lock` hub repository, e.g. `"@pub"`.
      assets: asset files the bundle packages; defaults to an optional `assets/**` glob.
      entrypoint: the app's entrypoint under lib/.
      srcs: Dart sources for change detection; defaults to `glob(["lib/**/*.dart"])`.
      path_deps: sources of `path:` dependencies.
      dart_defines: `-D` constants the kernels compile with.
      native_build_env: the native build environment for asset bundle hooks, or None.
      dart_plugin_registrant: the Dart plugin registrant under lib/, or None.
      **kwargs: visibility and tags passed to declared targets.
    """
    if srcs == None:
        srcs = native.glob(["lib/**/*.dart"])
    if assets == None:
        assets = native.glob(["assets/**"], allow_empty = True)
    if name == "pubspec":
        fail("flutter_core: `name` may not be \"pubspec\", which the core declares.")

    package_config, project_package_config, pub_lib, pub_all = _pub_labels(pub, "flutter_core " + name)

    aot_registrant = None
    debug_registrant = None
    if dart_plugin_registrant:
        debug_registrant = _workspace_label(dart_plugin_registrant)
        aot_registrant = select({
            Label("//flutter:mode_release"): pub + "//:dart_plugin_registrant_release.dart",
            "//conditions:default": debug_registrant,
        })

    flutter_pubspec(name = "pubspec", src = "pubspec.yaml", visibility = kwargs.get("visibility"))

    dart_aot_kernel(
        name = name + "_kernel",
        srcs = srcs,
        pubspec = ":pubspec",
        entrypoint = entrypoint,
        package_config = package_config,
        pub_srcs = [pub_lib],
        path_deps = path_deps,
        dart_plugin_registrant = aot_registrant,
        dart_defines = dart_defines,
        target_os = "android",
        target_compatible_with = aot_target_compatible_with(),
    )

    # Keep the OS-specific kernel shared across ABI splits through the existing
    # host transition.
    platform_neutral_files(
        name = name + "_kernel_neutral",
        src = ":" + name + "_kernel",
    )

    dart_jit_kernel(
        name = name + "_jit_kernel",
        srcs = srcs,
        pubspec = ":pubspec",
        entrypoint = entrypoint,
        package_config = package_config,
        pub_srcs = [pub_lib],
        path_deps = path_deps,
        dart_plugin_registrant = debug_registrant,
        dart_defines = dart_defines,
    )

    platform_neutral_files(
        name = name + "_jit_kernel_neutral",
        src = ":" + name + "_jit_kernel",
    )

    flutter_assets(
        name = name + "_assets",
        abis = list(ABIS),
        native_build_env = native_build_env,
        assets = assets,
        pubspec = ":pubspec",
        package_config = project_package_config,
        pub_srcs = [pub_all],
        path_deps = path_deps,
    )

    # The host test reads this bundle and package, built for flutter_tester.
    # It takes no ABI and no Android build environment.
    flutter_test_assets(
        name = name + "_test_assets",
        assets = assets,
        pubspec = ":pubspec",
        package_config = project_package_config,
        pub_srcs = [pub_all],
        path_deps = path_deps,
        tags = ["manual"],
    )

    flutter_package(
        name = name + "_test_package",
        pub = pub,
        pubspec = ":pubspec",
        srcs = srcs,
        path_deps = path_deps,
        assets = ":" + name + "_test_assets",
        tags = ["manual"],
    )

    assets_bundle(
        name = name + "_bundle_action",
        src = ":" + name + "_assets",
        kernel = select({
            Label("//flutter:mode_debug"): [":" + name + "_jit_kernel_neutral"],
            "//conditions:default": [],
        }),
    )

    platform_neutral_files(
        name = name + "_bundle",
        src = ":" + name + "_bundle_action",
    )

    for abi in ABIS:
        dart_aot_elf(
            name = "{}_libapp_{}".format(name, abi),
            dill = select({
                Label("//flutter/private:target_os_android"): ":" + name + "_kernel_neutral",
                "//conditions:default": None,
            }),
            abi = abi,
            snapshot_flags = ABIS[abi].snapshot_flags,
            strip = True,
            # Only the matching Android ABI has a libapp implementation.
            target_compatible_with = [Label("@platforms//os:android"), ABIS[abi].cpu_constraint] + aot_target_compatible_with(),
        )

    guards = [":path_deps_check"]
    pub_path_deps_check(
        name = "path_deps_check",
        path_deps = path_deps,
        pubspec_lock = "pubspec.lock",
        **kwargs
    )
    if dart_plugin_registrant:
        registrant_label = _workspace_label(dart_plugin_registrant)
        pub_plugins_check(
            name = "dart_registrant_check",
            committed = registrant_label,
            expected = pub + "//:dart_plugin_registrant.dart",
            updater = ":dart_registrant_update",
            **kwargs
        )
        _write_source_file(
            name = "dart_registrant_update",
            source = pub + "//:dart_plugin_registrant.dart",
            destination = registrant_label,
            **_internal_kwargs(kwargs)
        )
        guards.append(":dart_registrant_check")
    build_test(
        name = name + "_guards_test",
        targets = guards,
        **kwargs
    )

    # Each split names only its own ABI's libapp and engine libraries. The
    # host build and any unmatched split get none, and fail downstream.
    _flutter_core(
        name = name,
        libapp = select(dict(
            [(_split_label(abi, "release"), [":{}_libapp_{}".format(name, abi)]) for abi in ABIS] +
            [("//conditions:default", [])],
        )),
        engine_libs = select(dict(
            [(_split_label(abi, mode), [engine_libs_label(abi, mode)]) for abi in ABIS for mode in MODES] +
            [("//conditions:default", [])],
        )),
        assets = ":" + name + "_bundle",
        mode_free_assets = ":" + name + "_assets",
        pubspec = ":pubspec",
        package_config = package_config,
        pub_srcs = [pub_lib],
        srcs = srcs,
        path_deps = path_deps,
        debug_registrant = debug_registrant,
        **kwargs
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

    source_path = source.short_path
    if source_path.startswith("../"):
        source_path = source_path[3:]
    else:
        source_path = ctx.workspace_name + "/" + source_path

    destination = ctx.file.destination
    if destination.short_path.startswith("../") or not destination.is_source:
        fail(
            (
                "{}: destination {} is not a source file in the invoking " +
                "workspace, and BUILD_WORKSPACE_DIRECTORY can only update files " +
                "there. Name the committed file directly."
            ).format(ctx.label, ctx.attr.destination.label),
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
