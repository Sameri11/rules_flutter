"""The core artifact: an app's Dart outputs and engine libraries, with no APK packaging.

`flutter_core` declares the platform-neutral inputs once. The kernel and the
asset bundle are built under a host platform transition, so an android_binary
with N splits runs each action once rather than once per split. The per-ABI
snapshot and engine libraries are chosen by `select()` on the split's
config_settings, so each split names only its own ABI.

The android_binary side takes the artifact through `FlutterArtifactInfo`. See
`flutter_android_inputs` for the packaging half.
"""

load("@bazel_skylib//rules:build_test.bzl", "build_test")
load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load(":abis.bzl", "ABIS", "ABI_PLATFORM_ATTRS", "MODES", "abi_from_platform", "aot_target_compatible_with", "embedding_jar_label", "engine_libs_label")
load(":pubspec.bzl", "FlutterPubspecInfo", "flutter_pubspec")
load(":rules.bzl", "dart_aot_elf", "dart_aot_kernel", "dart_jit_kernel", "flutter_assets", "flutter_package", "flutter_test_assets", "pub_path_deps_check", "pub_plugins_check")

visibility(["//flutter/...", "//tests/..."])

_TOOLCHAIN = "//flutter/private:flutter_toolchain_type"

FlutterArtifactInfo = provider(
    doc = "What flutter_core hands to the android_binary split that built it.",
    fields = {
        "mode": "`release` or `debug`.",
        "abi": "The Android ABI of this split, or None on a host build.",
        "libapp": "File: the libapp.so of this ABI, or None under debug.",
        "engine_libs": "list of File: this ABI's engine .so files, unstripped.",
        "embedding_jar": "File: the Java embedding jar for this mode.",
        "assets": "Directory: the flutter_assets bundle, with the debug overlay under debug.",
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

_platform_neutral_files = rule(
    implementation = _platform_neutral_files_impl,
    doc = "Passes a target's files through, built under the host platform.",
    attrs = {
        "src": attr.label(
            mandatory = True,
            cfg = _platform_neutral_transition,
        ),
    },
)

def _assets_bundle_impl(ctx):
    toolchain = ctx.toolchains[_TOOLCHAIN].flutter
    mode = ctx.attr._mode[BuildSettingInfo].value
    out = ctx.actions.declare_directory(ctx.label.name + "/flutter_assets")

    (src,) = ctx.files.src
    inputs = [src]
    command = 'mkdir -p "{out}" && cp -RL "{src}"/. "{out}"/'.format(out = out.path, src = src.path)

    if mode == "debug":
        # The debug overlay: the JIT kernel and the host engine's snapshots,
        # under the names the engine looks for. Release ships no overlay.
        (kernel,) = ctx.files.kernel
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
    return [DefaultInfo(files = depset([out]))]

_assets_bundle = rule(
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
    embedding_jar = ctx.file.embedding
    assets = ctx.attr.assets[DefaultInfo].files.to_list()
    if len(assets) != 1:
        fail("{}: expected one assets directory, got {}".format(ctx.label, len(assets)))
    if len(libapp) > 1:
        fail("{}: expected at most one libapp.so, got {}".format(ctx.label, len(libapp)))

    return [
        DefaultInfo(files = depset(libapp + engine_libs + [embedding_jar, assets[0]])),
        FlutterArtifactInfo(
            mode = mode,
            abi = abi,
            libapp = libapp[0] if libapp else None,
            engine_libs = engine_libs,
            embedding_jar = embedding_jar,
            assets = assets[0],
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
            "embedding": attr.label(allow_single_file = True, mandatory = True),
            "assets": attr.label(mandatory = True, doc = "The platform-neutral bundle."),
            "pubspec": attr.label(mandatory = True, providers = [FlutterPubspecInfo]),
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
        assets = [],
        entrypoint = "lib/main.dart",
        srcs = [],
        path_deps = [],
        dart_defines = {},
        native_build_env = None,
        dart_plugin_registrant = None,
        plugin_deps = None,
        plugins = "@flutter_plugins",
        target_os = "android",
        **kwargs):
    """Declares an app's platform-neutral artifact as the target `<name>`.

    Declares `:pubspec` and the targets the artifact is built from, and the
    guards `<name>_guards_test` runs. Internal targets keep the package's
    default visibility. `visibility` also reaches `:pubspec`, which a consumer in
    another package reads through its flutter_android_inputs. `<name>_test_package`
    and its `<name>_test_assets` are the package host tests read, as flutter_app's
    `:app` is; both are `manual`.

    Args:
      name: the artifact's target name. `pubspec` is reserved.
      pub: the `pub.lock` hub repository, e.g. `"@pub"`.
      assets: asset files the bundle packages, as labels.
      entrypoint: the app's entrypoint under lib/, as a label.
      srcs: Dart sources, for change detection.
      path_deps: sources of `path:` dependencies.
      dart_defines: `-D` constants the kernel compiles with.
      dart_plugin_registrant: the Dart plugin registrant under lib/, as a label.
      plugin_deps: the committed Maven plugin file, checked against the hub.
      plugins: the plugin hub the guards check against, e.g. "@flutter_plugins"; required with plugin_deps.
      target_os: OS the kernel is compiled for; must be "android".
      native_build_env: the native build environment for the asset bundle's flutter build action, or None. Android builds pass rules_flutter_android's `native_build_env` rule.
      **kwargs: visibility, which also applies to `:pubspec`, and tags of `<name>`.
    """
    if name == "pubspec":
        fail("flutter_core: `name` may not be \"pubspec\", which the core declares.")
    if target_os != "android":
        fail("flutter_core {}: target_os must be \"android\", got {}.".format(name, repr(target_os)))
    if plugin_deps and plugins == None:
        fail("flutter_core {}: plugin_deps needs plugins = \"<hub>\", the plugin repository such as \"@flutter_plugins\"; plugins is None.".format(name))

    package_config, project_package_config, pub_lib, pub_all = _pub_labels(pub, "flutter_core " + name)

    flutter_pubspec(name = "pubspec", src = "pubspec.yaml", visibility = kwargs.get("visibility"))

    dart_aot_kernel(
        name = name + "_kernel",
        srcs = srcs,
        pubspec = ":pubspec",
        entrypoint = entrypoint,
        package_config = package_config,
        pub_srcs = [pub_lib],
        path_deps = path_deps,
        dart_plugin_registrant = dart_plugin_registrant,
        target_os = target_os,
        dart_defines = dart_defines,
        target_compatible_with = aot_target_compatible_with(),
    )

    # The elf takes the kernel through the host transition, so the kernel is one
    # action whichever split builds the elf.
    _platform_neutral_files(
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
        dart_plugin_registrant = dart_plugin_registrant,
        dart_defines = dart_defines,
    )

    _platform_neutral_files(
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

    # The host test reads this bundle and package, built for flutter_tester. It
    # takes no ABI and no Android build environment, as flutter_app's do.
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

    _assets_bundle(
        name = name + "_bundle_action",
        src = ":" + name + "_assets",
        kernel = select({
            Label("//flutter:mode_debug"): [":" + name + "_jit_kernel_neutral"],
            "//conditions:default": [],
        }),
    )

    _platform_neutral_files(
        name = name + "_bundle",
        src = ":" + name + "_bundle_action",
    )

    for abi in ABIS:
        dart_aot_elf(
            name = "{}_libapp_{}".format(name, abi),
            dill = ":" + name + "_kernel_neutral",
            abi = abi,
            snapshot_flags = ABIS[abi].snapshot_flags,
            strip = True,
            target_compatible_with = aot_target_compatible_with(),
        )

    guards = [":path_deps_check"]
    pub_path_deps_check(
        name = "path_deps_check",
        path_deps = path_deps,
        pubspec_lock = "pubspec.lock",
    )
    if plugin_deps:
        pub_plugins_check(
            name = "plugins_check",
            committed = plugin_deps,
            expected = plugins + "//:plugin_deps.MODULE.bazel",
        )
        guards.append(":plugins_check")

    if dart_plugin_registrant and plugin_deps:
        pub_plugins_check(
            name = "dart_registrant_check",
            committed = dart_plugin_registrant,
            expected = plugins + "//:dart_plugin_registrant.dart",
        )
        guards.append(":dart_registrant_check")

    build_test(
        name = name + "_guards_test",
        targets = guards,
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
        embedding = select({
            Label("//flutter:mode_release"): embedding_jar_label("release"),
            Label("//flutter:mode_debug"): embedding_jar_label("debug"),
        }),
        assets = ":" + name + "_bundle",
        pubspec = ":pubspec",
        **kwargs
    )
