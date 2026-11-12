"""The core artifact: an app's Dart outputs and host-test inputs.

`flutter_core` declares platform-neutral inputs once; each selected platform
supplies its target slices and artifact toolchains.
"""

load("@bazel_skylib//lib:shell.bzl", "shell")
load("@bazel_skylib//rules:build_test.bzl", "build_test")
load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load(":modes.bzl", "aot_target_compatible_with")
load(":pubspec.bzl", "FlutterPubspecInfo", "flutter_pubspec")
load(":rules.bzl", "FlutterAotSnapshotInfo", "dart_aot_kernel", "dart_aot_snapshot", "dart_jit_kernel", "flutter_assets", "flutter_package", "flutter_test_assets", "lib_root", "library_path", "pub_path_deps_check_action", "pub_plugins_check")

visibility(["//flutter/...", "//tests/..."])

_TARGET_TOOLCHAIN_LABEL = "//flutter/private:flutter_target_toolchain_type"
_TARGET_TOOLCHAIN = config_common.toolchain_type(
    Label("//flutter/private:flutter_target_toolchain_type"),
    mandatory = False,
)
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
    doc = "A configured Flutter artifact set for one target slice.",
    fields = {
        "mode": "release or debug.",
        "target_slice": "Stable platform slice identifier, or None on a host build.",
        "aot": "The target platform's AOT artifact, or None under debug.",
        "aot_kind": "The platform-declared AOT artifact kind, or None under debug.",
        "assets": "Directory: the flutter_assets bundle with any debug overlay.",
    },
)

FlutterCoreInfo = provider(
    doc = "Kernel inputs, debug registrant, and per-platform mode-free assets for flutter_debug_core.",
    fields = {
        "package_config": "File: the pub hub's package_config.json.",
        "pub_srcs": "list of File: the hub's packageUri trees.",
        "srcs": "list of File: the app's Dart sources, for change detection.",
        "path_deps": "list of File: sources of path dependencies.",
        "debug_registrant": "File or None: the debug plugin registrant.",
        "registrant_path": "str: the registrant's path within its package, as a package: URI suffix.",
        "lib": "str: the app's lib/ prefix in the execroot; an entrypoint under it compiles as package:, under its own name.",
        "mode_free_assets": "File: the mode-free neutral asset tree for the selected platform configuration.",
    },
)

_PLATFORM_NEUTRAL_OUTPUTS = ["//command_line_option:platforms"]

def _platform_neutral_transition_impl(_settings, _attr):
    return {"//command_line_option:platforms": ["@platforms//host:host"]}

_platform_neutral_transition = transition(
    implementation = _platform_neutral_transition_impl,
    inputs = [],
    outputs = _PLATFORM_NEUTRAL_OUTPUTS,
)

def _platform_neutral_files_impl(ctx):
    # The transition yields one configuration, and Bazel hands a transitioned
    # label attr back as a list of them.
    (src,) = ctx.attr.src
    return [DefaultInfo(files = src[DefaultInfo].files)]

def platform_neutral_files_rule(configuration_transition):
    """Creates a file pass-through rule with a 1:1 source configuration transition."""
    return rule(
        implementation = _platform_neutral_files_impl,
        doc = "Passes a target's files through under the supplied configuration reset.",
        attrs = {
            "src": attr.label(
                mandatory = True,
                cfg = configuration_transition,
            ),
        },
    )

platform_neutral_files = platform_neutral_files_rule(_platform_neutral_transition)

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
    target_slice = ctx.toolchains[_TARGET_TOOLCHAIN_LABEL].flutter_target.slice_id if ctx.toolchains[_TARGET_TOOLCHAIN_LABEL] != None else None
    aot_files = ctx.files.aot
    assets = ctx.attr.assets[DefaultInfo].files.to_list()
    if len(assets) != 1:
        fail("{}: expected one assets directory, got {}".format(ctx.label, len(assets)))
    if len(aot_files) > 1:
        fail("{}: expected at most one AOT artifact, got {}".format(ctx.label, len(aot_files)))
    if target_slice != None and mode == "release" and len(aot_files) != 1:
        fail("{}: release target slice '{}' needs one AOT artifact".format(ctx.label, target_slice))

    mode_free_assets = ctx.files.mode_free_assets
    if len(mode_free_assets) != 1:
        fail("{}: expected one mode-free asset tree, got {}".format(ctx.label, len(mode_free_assets)))
    validation = pub_path_deps_check_action(
        ctx,
        ctx.actions.declare_file(ctx.label.name + ".path_deps.checked"),
        ctx.file.pubspec_lock,
        ctx.files.path_deps,
        ctx.file._checker,
    )
    return [
        DefaultInfo(files = depset(aot_files + [assets[0]])),
        OutputGroupInfo(
            flutter_assets = depset([assets[0]]),
            flutter_aot = depset(aot_files),
            _validation = depset([validation]),
        ),
        FlutterArtifactInfo(
            mode = mode,
            target_slice = target_slice,
            aot = aot_files[0] if aot_files else None,
            aot_kind = ctx.attr.aot[0][FlutterAotSnapshotInfo].kind if ctx.attr.aot else None,
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
            mode_free_assets = mode_free_assets[0],
        ),
        ctx.attr.pubspec[FlutterPubspecInfo],
    ]

_flutter_core = rule(
    implementation = _flutter_core_impl,
    doc = "Collects one split's view of a flutter_core into FlutterArtifactInfo.",
    attrs = {
        "aot": attr.label_list(allow_files = True, doc = "The selected platform's AOT artifact; empty under debug or on host."),
        "assets": attr.label(mandatory = True, doc = "The platform-neutral bundle."),
        "mode_free_assets": attr.label(mandatory = True, allow_files = True, doc = "The neutral mode-free assets selected for this platform configuration."),
        "pubspec": attr.label(mandatory = True, providers = [FlutterPubspecInfo]),
        "package_config": attr.label(allow_single_file = True, mandatory = True, doc = "The pub hub's package_config.json, read by a flutter_debug_core's kernel."),
        "pub_srcs": attr.label_list(allow_files = True, allow_empty = False, mandatory = True, doc = "The pub hub's :lib, read by a flutter_debug_core's kernel."),
        "srcs": attr.label_list(allow_files = [".dart"], doc = "Dart sources for change detection in a flutter_debug_core's kernel."),
        "path_deps": attr.label_list(allow_files = True, doc = "Sources of path dependencies, as the kernels take them."),
        "debug_registrant": attr.label(allow_single_file = [".dart"], doc = "The debug registrant, as dart_jit_kernel takes it."),
        "pubspec_lock": attr.label(allow_single_file = True, mandatory = True),
        "_checker": attr.label(default = "//flutter/private:check_path_deps.py", allow_single_file = True),
        "_mode": attr.label(default = Label("//flutter:mode"), providers = [BuildSettingInfo]),
    },
    toolchains = [_TARGET_TOOLCHAIN],
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
        platforms,
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
      path_deps: sources of `path:` dependencies; checked against `pubspec.lock` by build validation.
      dart_defines: values forwarded to frontend_server as `-D<name>=<value>` options.
      native_build_env: one label override for all platforms, a dict keyed by platform name, or None to use each descriptor's default.
      dart_plugin_registrant: an optional plugin registrant Dart file to compile.
      platforms: platform descriptors returned by flutter_platform.
      **kwargs: visibility and tags passed to declared targets.
    """
    if srcs == None:
        srcs = native.glob(["lib/**/*.dart"])
    if assets == None:
        assets = native.glob(["assets/**"], allow_empty = True)
    if name == "pubspec":
        fail("flutter_core: `name` may not be \"pubspec\", which the core declares.")

    target_platforms = []
    for platform in platforms:
        target_platforms.extend(platform.target_platforms)
    if not target_platforms:
        fail("flutter_core: at least one platform with target platforms is required.")
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

    platform_slices = {}
    platform_jit_kernel_neutral = {}
    for platform in platforms:
        slices_name = name + "_" + platform.name + "_slices"
        platform.slices_rule(
            name = slices_name,
            target_platforms = platform.target_platforms,
        )
        platform_slices[platform.name] = ":" + slices_name
    kernel_neutral = {}
    for platform in platforms:
        kernel = name + "_" + platform.name + "_kernel"
        dart_aot_kernel(
            name = kernel,
            srcs = srcs,
            pubspec = ":pubspec",
            entrypoint = entrypoint,
            package_config = package_config,
            pub_srcs = [pub_lib],
            path_deps = path_deps,
            dart_plugin_registrant = aot_registrant,
            dart_defines = dart_defines,
            target_slices = [platform_slices[platform.name]],
            target_compatible_with = aot_target_compatible_with(),
        )
        neutral = kernel + "_neutral"
        platform.neutral_files_rule(name = neutral, src = ":" + kernel)
        kernel_neutral[platform.name] = ":" + neutral
    release_aot = {}
    for platform in platforms:
        release_config = name + "_" + platform.name + "_release"
        native.config_setting(
            name = release_config,
            constraint_values = [platform.constraint],
            flag_values = {Label("//flutter:mode"): "release"},
        )
        artifact = name + "_" + platform.name + "_aot"
        dart_aot_snapshot(
            name = artifact,
            dill = kernel_neutral[platform.name],
            target_compatible_with = [platform.constraint] + aot_target_compatible_with(),
        )
        release_aot[":" + release_config] = [":" + artifact]
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

    for platform in platforms:
        neutral = name + "_jit_kernel_neutral_" + platform.name
        platform.neutral_files_rule(name = neutral, src = ":" + name + "_jit_kernel")
        platform_jit_kernel_neutral[platform.name] = ":" + neutral

    platform_asset_actions = {}
    for platform in platforms:
        asset_action = name + "_" + platform.name + "_assets_action"
        if type(native_build_env) == "dict":
            platform_native_build_env = native_build_env.get(platform.name, platform.native_build_env)
        else:
            platform_native_build_env = native_build_env if native_build_env != None else platform.native_build_env
        flutter_assets(
            name = asset_action,
            target_slices = [platform_slices[platform.name]],
            native_build_env = platform_native_build_env,
            assets = assets,
            pubspec = ":pubspec",
            package_config = project_package_config,
            pub_srcs = [pub_all],
            path_deps = path_deps,
        )
        platform_asset_actions[platform.name] = ":" + asset_action

    # The host test reads this bundle and package, built for flutter_tester.
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

    platform_assets = {}
    platform_bundles = {}
    assets_select = {}
    mode_free_assets_select = {}
    bundle_select = {}
    for platform in platforms:
        assets_neutral = name + "_assets_neutral_" + platform.name
        bundle_neutral = name + "_bundle_" + platform.name
        platform.neutral_files_rule(name = assets_neutral, src = platform_asset_actions[platform.name])
        platform_assets[platform.name] = ":" + assets_neutral

        bundle_action = name + "_" + platform.name + "_bundle_action"
        assets_bundle(
            name = bundle_action,
            src = platform_asset_actions[platform.name],
            kernel = select({
                Label("//flutter:mode_debug"): [platform_jit_kernel_neutral[platform.name]],
                "//conditions:default": [],
            }),
        )
        platform.neutral_files_rule(name = bundle_neutral, src = ":" + bundle_action)
        platform_bundles[platform.name] = ":" + bundle_neutral
        mode_free_assets_select[platform.constraint] = ":" + assets_neutral
        assets_select[platform.constraint] = [":" + assets_neutral]
        bundle_select[platform.constraint] = [":" + bundle_neutral]
    assets_select["//conditions:default"] = [platform_assets[platforms[0].name]]
    bundle_select["//conditions:default"] = [platform_bundles[platforms[0].name]]
    mode_free_assets_select["//conditions:default"] = platform_assets[platforms[0].name]
    native.filegroup(name = name + "_assets", srcs = select(assets_select))
    native.filegroup(name = name + "_bundle", srcs = select(bundle_select))

    guards = []
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
    if guards:
        build_test(
            name = name + "_guards_test",
            targets = guards,
            **kwargs
        )

    release_aot["//conditions:default"] = []
    _flutter_core(
        name = name,
        aot = select(release_aot),
        assets = ":" + name + "_bundle",
        mode_free_assets = select(mode_free_assets_select),
        pubspec = ":pubspec",
        package_config = package_config,
        pubspec_lock = "pubspec.lock",
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
