"""A debug core artifact built from another entrypoint of an app's flutter_core.

`flutter_debug_core` compiles its own `entrypoint` with its own `dart_defines`,
against the app's package inputs, and pairs that kernel with the app's
mode-free bundle and debug engine. The result is a debug FlutterArtifactInfo
with the same shape as the app's, so packaging consumes it the same way. Both
kernels and both bundles come from the shared actions in rules.bzl and core.bzl.
"""

load(":abis.bzl", "debug_target_compatible_with")
load(":core.bzl", "FlutterArtifactInfo", "FlutterCoreInfo", "assets_bundle", "platform_neutral_files")
load(":pubspec.bzl", "FlutterPubspecInfo")
load(":rules.bzl", "jit_kernel_action")

visibility(["//flutter/..."])

_TOOLCHAIN = "//flutter/private:flutter_toolchain_type"

# A test-local import missing from `srcs` is absent from the sandbox; say where to declare it.
_IMPORT_HINT = "hint: declare test-local imports in `srcs`"

def _flutter_debug_kernel_impl(ctx):
    dill = ctx.actions.declare_file(ctx.label.name + ".dill")
    core = ctx.attr.app[FlutterCoreInfo]

    # The app's inputs, read from its provider. The action is the one
    # dart_jit_kernel runs, so the test kernel and the app's debug kernel differ
    # only in entrypoint and defines.
    jit_kernel_action(
        ctx,
        dill = dill,
        pkg = struct(
            package_name = ctx.attr.app[FlutterPubspecInfo].package_name,
            package_config = core.package_config,
            pub_srcs = core.pub_srcs,
            path_deps = core.path_deps,
            srcs = core.srcs + ctx.files.srcs,
            registrant = core.debug_registrant,
            registrant_path = core.registrant_path,
            import_dill = None,
        ),
        entrypoint = ctx.file.entrypoint,
        dart_defines = ctx.attr.dart_defines,
        hint = _IMPORT_HINT,
        mnemonic = "DartJitKernel",
        what = "Dart JIT kernel",
    )
    return [DefaultInfo(files = depset([dill]))]

_flutter_debug_kernel = rule(
    implementation = _flutter_debug_kernel_impl,
    doc = "Compiles an app's package inputs under another entrypoint to a debug kernel.",
    attrs = {
        "app": attr.label(
            mandatory = True,
            providers = [FlutterCoreInfo, FlutterPubspecInfo],
            doc = "The app's flutter_core target.",
        ),
        "entrypoint": attr.label(
            allow_single_file = [".dart"],
            mandatory = True,
            doc = "The Dart file compiled as `main`. See dart_jit_kernel.entrypoint.",
        ),
        "srcs": attr.label_list(
            allow_files = [".dart"],
            doc = "Dart files outside lib/ that the entrypoint imports. The app's lib/ files are read from the app.",
        ),
        "dart_defines": attr.string_dict(
            doc = "Compile-time constants of this kernel only. See dart_jit_kernel.dart_defines.",
        ),
    },
    toolchains = [_TOOLCHAIN],
)

def _flutter_debug_core_impl(ctx):
    artifact = ctx.attr.app[FlutterArtifactInfo]
    (assets,) = ctx.files.bundle

    # No libapp: a debug artifact runs its kernel from the bundle. The engine and
    # embedding are the app's own, selected by the same configuration.
    return [
        DefaultInfo(files = depset(artifact.engine_libs + [artifact.embedding_jar, assets])),
        OutputGroupInfo(
            flutter_assets = depset([assets]),
            flutter_engine = depset(artifact.engine_libs),
            flutter_libapp = depset([]),
            flutter_embedding = depset([artifact.embedding_jar]),
        ),
        FlutterArtifactInfo(
            mode = "debug",
            abi = artifact.abi,
            libapp = None,
            engine_libs = artifact.engine_libs,
            embedding_jar = artifact.embedding_jar,
            assets = assets,
        ),
        ctx.attr.app[FlutterPubspecInfo],
    ]

_flutter_debug_core = rule(
    implementation = _flutter_debug_core_impl,
    doc = "Collects a debug FlutterArtifactInfo from the app's engine and the test bundle.",
    attrs = {
        "app": attr.label(
            mandatory = True,
            providers = [FlutterArtifactInfo, FlutterPubspecInfo],
            doc = "The app's flutter_core target, in the same configuration.",
        ),
        "bundle": attr.label(
            mandatory = True,
            allow_files = True,
            doc = "The debug bundle: the app's tree with this entrypoint's kernel.",
        ),
    },
)

def flutter_debug_core(name, app, entrypoint, dart_defines = {}, srcs = [], **kwargs):
    """Declares a debug artifact of an app's core, compiled from another entrypoint.

    The artifact is debug only: a release configuration reports it incompatible,
    and it is `manual` by default, so `bazel build //...` does not build it.

    Args:
      name: the artifact's target name.
      app: the app's `flutter_core` target, in this package or another.
      entrypoint: the Dart file compiled as `main`. Files under lib/ compile as
        `package:`; any other .dart file compiles by its execroot path, as
        dart_jit_kernel compiles them.
      dart_defines: `-D` constants of this artifact's kernel. The app's are not inherited.
      srcs: Dart files outside lib/ that the entrypoint imports by relative path,
        such as a helper under integration_test/. Undeclared, they are missing
        from the kernel's sandbox and the compile fails.
      **kwargs: `tags`, default `["manual"]`, and `visibility` for the artifact.
    """
    if "target_compatible_with" in kwargs:
        fail("flutter_debug_core {}: target_compatible_with is fixed to debug mode.".format(name))
    tags = kwargs.pop("tags", ["manual"])
    compatible = debug_target_compatible_with()

    # Helpers are manual and debug-only as well, so no wildcard build reaches them
    # in a configuration that the artifact itself is incompatible with.
    internal = {"tags": ["manual"], "target_compatible_with": compatible}

    # flutter_core declares its mode-free bundle under this name.
    app_label = native.package_relative_label(app)
    assets = app_label.same_package_label(app_label.name + "_assets")

    _flutter_debug_kernel(
        name = name + "_kernel",
        app = app,
        entrypoint = entrypoint,
        dart_defines = dart_defines,
        srcs = srcs,
        **internal
    )

    # Built under the host platform, as the app's kernel is, so the Android
    # split transitions run it once.
    platform_neutral_files(
        name = name + "_kernel_neutral",
        src = ":" + name + "_kernel",
        **internal
    )

    assets_bundle(
        name = name + "_bundle_action",
        src = assets,
        kernel = [":" + name + "_kernel_neutral"],
        **internal
    )

    platform_neutral_files(
        name = name + "_bundle",
        src = ":" + name + "_bundle_action",
        **internal
    )

    _flutter_debug_core(
        name = name,
        app = app,
        bundle = ":" + name + "_bundle",
        tags = tags,
        target_compatible_with = compatible,
        **kwargs
    )
