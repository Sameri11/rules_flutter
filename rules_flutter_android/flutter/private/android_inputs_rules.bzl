"""The Android inputs of a flutter_core artifact, one split per Android ABI.

`flutter_android_inputs` declares the android_library a consumer lists in its
android_binary deps. Each configured split reads its ABI from the Bazel platform
it is built for, takes that ABI's engine and AOT libraries from the core, and
takes the plugin repository's libraries for that ABI. The libraries reach the
APK through CcInfo, not through a jar the app wraps.

A split built without an Android platform still analyses. It links a placeholder
library whose action fails, so the failure comes when an APK asks for the split,
not when the build graph is loaded.
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("@rules_android//rules:rules.bzl", "android_library")
load("@rules_cc//cc:find_cc_toolchain.bzl", "find_cpp_toolchain", "use_cc_toolchain")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_flutter_core//flutter:abis.bzl", "ABIS", "ABI_PLATFORM_ATTRS", "abi_from_platform")
load("@rules_flutter_core//flutter:defs.bzl", "FlutterArtifactInfo", "FlutterPubspecInfo")
load("@rules_java//java:defs.bzl", "java_import")
load(":embedding.bzl", "ANNOTATION_JVM", "flutter_embedding_deps")
load(":native_files.bzl", "FlutterNativeFilesByAbiInfo")

visibility(["//flutter/...", "//tests/..."])

# The registrant of an app without plugins: an empty GeneratedPluginRegistrant.
_EMPTY_REGISTRANT = Label("//flutter/private:registrant/GeneratedPluginRegistrant.java")

_NO_ABI_MESSAGE = "ERROR: {} has no Android ABI, so it packages no native libraries. Set --android_platforms to the Android platforms to build."

FlutterSplitNativeInfo = provider(
    doc = "One split's native libraries, as its _split_native target packages them.",
    fields = {
        "abi": "str: the split's ABI, or None where the configuration is not an Android split.",
        "mode": "str: the core's mode, release or debug; None without an ABI.",
        "libraries": "list[File]: each library the split packages, under its basename.",
    },
)

def _core_file_impl(ctx):
    info = ctx.attr.core[FlutterArtifactInfo]
    return [DefaultInfo(files = depset([getattr(info, ctx.attr.field)]))]

# Passes one File of the core's provider through unchanged, so a java_import or
# a consumer can name it. The embedding jar is the core's own output, so nothing here
# runs an action.
_core_file = rule(
    implementation = _core_file_impl,
    doc = "One File of a flutter_core split's FlutterArtifactInfo.",
    attrs = {
        "core": attr.label(mandatory = True, providers = [FlutterArtifactInfo]),
        "field": attr.string(mandatory = True, values = ["embedding_jar"]),
    },
)

def _pubspec_impl(ctx):
    return [ctx.attr.core[FlutterPubspecInfo]]

# Forwards the core's pubspec, so a binary that reuses this inputs target reads
# its version from the same pubspec the inputs were built from.
_pubspec = rule(
    implementation = _pubspec_impl,
    doc = "The core's FlutterPubspecInfo.",
    attrs = {
        "core": attr.label(mandatory = True, providers = [FlutterPubspecInfo]),
    },
)

def _inputs_bundle_impl(ctx):
    src = ctx.attr.core[FlutterArtifactInfo].assets
    out = ctx.actions.declare_directory(ctx.label.name + "/flutter_assets")
    ctx.actions.run_shell(
        outputs = [out],
        inputs = [src],
        command = 'mkdir -p "{out}" && cp -RL "{src}"/. "{out}"/'.format(out = out.path, src = src.path),
        mnemonic = "FlutterAssetCopy",
        progress_message = "Copying the Flutter assets of %{label}",
    )
    return [DefaultInfo(files = depset([out]))]

# The copy puts the tree at <name>/flutter_assets, so flutter_assets_dir of this target
# gives its prefix, whatever the core is named.
_inputs_bundle = rule(
    implementation = _inputs_bundle_impl,
    doc = "The core's flutter_assets tree, copied under this target's name.",
    attrs = {
        "core": attr.label(mandatory = True, providers = [FlutterArtifactInfo]),
    },
)

def _split_providers(ctx, cc_toolchain, libraries, split):
    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features,
    )
    linker_input = cc_common.create_linker_input(
        owner = ctx.label,
        libraries = depset([
            cc_common.create_library_to_link(
                actions = ctx.actions,
                cc_toolchain = cc_toolchain,
                feature_configuration = feature_configuration,
                dynamic_library = f,
            )
            for f in libraries
        ]),
    )
    return [
        DefaultInfo(files = depset(libraries)),
        CcInfo(linking_context = cc_common.create_linking_context(
            linker_inputs = depset([linker_input]),
        )),
        split,
    ]

def _split_native_impl(ctx):
    cc_toolchain = find_cpp_toolchain(ctx)
    abi = abi_from_platform(ctx)

    if abi == None:
        # Analysed without an Android platform. Nothing is packaged: the
        # placeholder's action fails, so an APK build stops here with the
        # message and the graph still loads for `--nobuild` and `cquery`.
        placeholder = ctx.actions.declare_file(ctx.label.name + "/libunconfigured.so")
        ctx.actions.run_shell(
            outputs = [placeholder],
            command = "echo '{}' >&2; exit 1".format(_NO_ABI_MESSAGE.format(ctx.label)),
            mnemonic = "FlutterSplitNoAbi",
            progress_message = "Failing %{label}: no Android ABI",
        )
        return _split_providers(
            ctx,
            cc_toolchain,
            [placeholder],
            FlutterSplitNativeInfo(abi = None, mode = None, libraries = []),
        )

    # The platform names a CPU that Flutter does not build for, such as x86.
    if abi not in ABIS:
        fail("{}: the Android platform is {}, which Flutter has no ABI for. Supported ABIs: {}.".format(
            ctx.label,
            abi,
            sorted(ABIS),
        ))

    mode = ctx.attr._mode[BuildSettingInfo].value
    compilation_mode = ctx.var["COMPILATION_MODE"]
    if mode == "release" and compilation_mode != "opt":
        fail("{}: mode=release needs -c opt, but this build is -c {}. Build with -c opt, or build debug with --@rules_flutter_core//flutter:mode=debug.".format(
            ctx.label,
            compilation_mode,
        ))

    info = ctx.attr.core[FlutterArtifactInfo]

    libraries = []
    if info.libapp != None:
        libraries.append(info.libapp)

    # The engine is stripped here, as the engine jar was, so the APK carries
    # the same bytes the jar carried.
    for f in info.engine_libs:
        stripped = ctx.actions.declare_file("{}/{}".format(ctx.label.name, f.basename))
        ctx.actions.run(
            executable = cc_toolchain.strip_executable,
            arguments = ["--strip-unneeded", "-o", stripped.path, f.path],
            inputs = [f],
            tools = cc_toolchain.all_files,
            outputs = [stripped],
            mnemonic = "FlutterEngineStrip",
            progress_message = "Stripping " + f.basename + " for %{label}",
        )
        libraries.append(stripped)

    if ctx.attr.native_files != None:
        project = ctx.attr.native_files[FlutterNativeFilesByAbiInfo]
        if abi not in project.files:
            fail("{}: this split builds {}, but the plugin repository declares {}. Add {} to plugins.project(abis).".format(
                ctx.label,
                abi,
                sorted(project.files),
                abi,
            ))
        libraries.extend(project.files[abi].to_list())

    seen = {}
    for f in libraries:
        if f.basename in seen:
            fail("{}: two libraries are named {} in the {} split; the APK would carry one of them.".format(
                ctx.label,
                f.basename,
                abi,
            ))
        seen[f.basename] = f

    return _split_providers(
        ctx,
        cc_toolchain,
        libraries,
        FlutterSplitNativeInfo(abi = abi, mode = mode, libraries = libraries),
    )

_split_native = rule(
    implementation = _split_native_impl,
    doc = """One Android split's native libraries, packaged through CcInfo.

Listed in an android_binary's deps, so each split analyses under its own
platform. The ABI comes from that platform.""",
    attrs = dict(
        {
            "core": attr.label(
                mandatory = True,
                providers = [FlutterArtifactInfo],
                doc = "The flutter_core target, configured for this split.",
            ),
            "native_files": attr.label(
                providers = [FlutterNativeFilesByAbiInfo],
                doc = "The plugin repository's flutter_native_files_by_abi. None for an app without plugins.",
            ),
            "_mode": attr.label(
                default = Label("@rules_flutter_core//flutter:mode"),
                providers = [BuildSettingInfo],
            ),
        },
        **ABI_PLATFORM_ATTRS
    ),
    fragments = ["cpp"],
    toolchains = use_cc_toolchain(),
)

def flutter_android_inputs(name, core, plugins, maven_repo = "@flutter_maven", tags = []):
    """Declares a flutter_core artifact's Android inputs as the target `<name>`.

    The consumer lists `<name>` in its android_binary deps. It exports the
    registrant, the embedding and the split's native libraries, so those reach
    the APK with no second dep. Nothing here names an ABI: each split reads its
    ABI from the platform it is built for.

    Args:
      name: the target a consumer lists. Also the prefix of `<name>_registrant`,
        `<name>_embedding`, `<name>_native` and `<name>_bundle`.
      core: the flutter_core target. Its split is selected by the platform.
      plugins: the plugin repository, e.g. `"@flutter_plugins"`, or None for an
        app without plugins.
      maven_repo: the repository holding the embedding's Maven dependencies.
      tags: tags for `<name>` only. The other targets are plumbing and always
        carry `manual`.
    """
    if plugins != None and not plugins.startswith("@"):
        fail("flutter_android_inputs {}: plugins must be a repository label such as \"@flutter_plugins\", or None; got {}.".format(
            name,
            repr(plugins),
        ))

    _core_file(
        name = name + "_core_embedding",
        core = core,
        field = "embedding_jar",
        tags = ["manual"],
    )
    java_import(
        name = name + "_embedding",
        jars = [":" + name + "_core_embedding"],
        deps = flutter_embedding_deps(maven_repo),
        tags = ["manual"],
    )
    _pubspec(
        name = name + "_pubspec",
        core = core,
        tags = ["manual"],
    )

    if plugins:
        android_library(
            name = name + "_registrant",
            exports = [plugins + "//:generated_plugin_registrant"],
            tags = ["manual"],
        )
    else:
        android_library(
            name = name + "_registrant",
            srcs = [_EMPTY_REGISTRANT],
            deps = [
                ":" + name + "_embedding",
                maven_repo + ANNOTATION_JVM,
            ],
            tags = ["manual"],
        )

    _split_native(
        name = name + "_native",
        core = core,
        native_files = plugins + "//:flutter_native_files_by_abi" if plugins else None,
        tags = ["manual"],
    )

    _inputs_bundle(
        name = name + "_bundle",
        core = core,
        tags = ["manual"],
    )

    # The engine's keep rules. They apply only to a binary that shrinks, so a
    # binary that sets no proguard_specs is unaffected.
    android_library(
        name = name,
        exports = [
            ":" + name + "_registrant",
            ":" + name + "_embedding",
            ":" + name + "_native",
        ] + flutter_embedding_deps(maven_repo),
        proguard_specs = [Label("//flutter/private:engine_keep.pro")],
        tags = tags,
    )
