"""A debug core artifact built from another entrypoint of an app's flutter_core.

`flutter_debug_core` compiles its own `entrypoint` with its own `dart_defines`,
against the app's package inputs, and pairs that kernel with the app's
mode-free bundle. The result is a debug FlutterArtifactInfo with the same shape
as the app's, so packaging consumes it the same way. Both kernels and both
bundles come from the shared actions in rules.bzl and core.bzl.

The app is reached only through its FlutterCoreInfo provider, so it may live in
another package, behind a restrictive visibility, or be an alias.
"""

load(":abis.bzl", "debug_target_compatible_with")
load(":core.bzl", "FlutterArtifactInfo", "FlutterCoreInfo", "assets_bundle_action", "platform_neutral_files")
load(":pubspec.bzl", "FlutterPubspecInfo")
load(":rules.bzl", "TEST_IMPORT_HINT", "jit_kernel_action")

visibility(["//flutter/..."])

_TOOLCHAIN = "//flutter/private:flutter_toolchain_type"

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
            lib = core.lib,
            import_dill = None,
        ),
        entrypoint = ctx.file.entrypoint,
        dart_defines = ctx.attr.dart_defines,
        hint = TEST_IMPORT_HINT,
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

def _flutter_debug_bundle_impl(ctx):
    core = ctx.attr.app[FlutterCoreInfo]
    (kernel,) = ctx.files.kernel
    return [DefaultInfo(files = depset([assets_bundle_action(ctx, core.mode_free_assets, [kernel])]))]

# Wrapped in platform_neutral_files, so the app is read in the platform-neutral
# configuration, as its own bundle is, and the bundle is built once.
_flutter_debug_bundle_action = rule(
    implementation = _flutter_debug_bundle_impl,
    doc = "Overlays a debug kernel on an app's mode-free flutter_assets tree.",
    attrs = {
        "app": attr.label(
            mandatory = True,
            providers = [FlutterCoreInfo],
            doc = "The app's flutter_core target.",
        ),
        "kernel": attr.label_list(
            mandatory = True,
            allow_files = True,
            doc = "The debug kernel of this artifact's entrypoint.",
        ),
    },
    toolchains = [_TOOLCHAIN],
)

def _flutter_debug_core_impl(ctx):
    artifact = ctx.attr.app[FlutterArtifactInfo]
    (assets,) = ctx.files.bundle

    # No libapp: a debug artifact runs its kernel from the bundle.
    return [
        DefaultInfo(files = depset([assets])),
        OutputGroupInfo(
            flutter_assets = depset([assets]),
            flutter_aot = depset([]),
        ),
        FlutterArtifactInfo(
            mode = "debug",
            target_slice = artifact.target_slice,
            aot = None,
            aot_kind = None,
            assets = assets,
        ),
        ctx.attr.app[FlutterPubspecInfo],
    ]

_flutter_debug_core = rule(
    implementation = _flutter_debug_core_impl,
    doc = "Collects a debug FlutterArtifactInfo from the app and the test bundle.",
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
      app: the app's `flutter_core` target. It may be in another package, under a
        restrictive visibility, or an alias; only its own visibility applies.
      entrypoint: the Dart file compiled as `main`. A file under the app's lib/
        compiles as `package:<app>/...`, the same library the app itself loads;
        any other .dart file compiles by its execroot path, as dart_jit_kernel
        compiles them.
      dart_defines: `-D` constants of this artifact's kernel. The app's are not inherited.
      srcs: Dart files outside lib/ that the entrypoint imports by relative path,
        such as a helper under integration_test/. Undeclared, they are missing
        from the kernel's sandbox and the compile fails.
      **kwargs: `tags`, default `["manual"]`; `target_compatible_with`, combined
        with the debug-only constraint; `testonly`, applied to every helper target;
        and `visibility` for the artifact.
    """
    testonly = kwargs.pop("testonly", False)
    tags = kwargs.pop("tags", ["manual"])

    # The debug-only constraint is always kept; a caller's constraints add to it.
    compatible = debug_target_compatible_with() + kwargs.pop("target_compatible_with", [])

    # Helpers are manual and debug-only as well, so no wildcard build reaches them
    # in a configuration that the artifact itself is incompatible with.
    internal = {"tags": ["manual"], "target_compatible_with": compatible, "testonly": testonly}

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

    _flutter_debug_bundle_action(
        name = name + "_bundle_action",
        app = app,
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
        testonly = testonly,
        **kwargs
    )
