"""A debug core artifact built from another entrypoint of an app's flutter_core.

`flutter_debug_core` compiles its own `entrypoint` with its own `dart_defines`,
against the app's package inputs, and pairs that kernel with the app's
mode-free bundle. The result is a debug FlutterArtifactInfo with the same shape
as the app's, so packaging consumes it the same way. Both kernels and both
bundles come from the shared actions in rules.bzl and core.bzl.

The app is reached only through its FlutterCoreInfo provider, so it may live in
another package, behind a restrictive visibility, or be an alias.
"""

load(
    ":core.bzl",
    "FlutterArtifactInfo",
    "FlutterCoreInfo",
    "assets_bundle_action",
)
load(":modes.bzl", "debug_target_compatible_with")
load(":pubspec.bzl", "FlutterPubspecInfo")
load(":rules.bzl", "TEST_IMPORT_HINT", "jit_kernel_action")

visibility(["//flutter/..."])

_TOOLCHAIN = "//flutter/private:flutter_toolchain_type"

def _debug_bundle_platform_transition_impl(_settings, attr):
    return {"//command_line_option:platforms": [attr.target_platform]}

_debug_bundle_platform_transition = transition(
    implementation = _debug_bundle_platform_transition_impl,
    inputs = [],
    outputs = ["//command_line_option:platforms"],
)

def _flutter_debug_kernel_impl(ctx):
    dill = ctx.actions.declare_file(ctx.label.name + ".dill")
    (app,) = ctx.attr.app
    core = app[FlutterCoreInfo]

    # The app's inputs, read from its provider. The action is the one
    # dart_jit_kernel runs, so the test kernel and the app's debug kernel differ
    # only in entrypoint and defines.
    jit_kernel_action(
        ctx,
        dill = dill,
        pkg = struct(
            package_name = app[FlutterPubspecInfo].package_name,
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
            cfg = _debug_bundle_platform_transition,
            providers = [FlutterCoreInfo, FlutterPubspecInfo],
            doc = "The app's flutter_core target.",
        ),
        "target_platform": attr.string(mandatory = True),
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
    (app,) = ctx.attr.app
    core = app[FlutterCoreInfo]
    (kernel,) = ctx.files.kernel
    mode_free_assets = core.mode_free_assets
    return [DefaultInfo(files = depset([assets_bundle_action(ctx, mode_free_assets, [kernel])]))]

# A descriptor's neutral wrapper resets this action before it reads the app
# bundle, so the kernel overlay does not inherit the requesting split settings.
_flutter_debug_bundle_action = rule(
    implementation = _flutter_debug_bundle_impl,
    doc = "Overlays a debug kernel on an app's mode-free flutter_assets tree.",
    attrs = {
        # Resolve the app edge under this descriptor so the overlay uses its asset tree.
        "app": attr.label(
            mandatory = True,
            cfg = _debug_bundle_platform_transition,
            providers = [FlutterCoreInfo],
            doc = "The app's flutter_core target.",
        ),
        "target_platform": attr.string(mandatory = True),
        "kernel": attr.label_list(mandatory = True, allow_files = True, doc = "The debug kernel of this artifact's entrypoint."),
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

def flutter_debug_core(name, app, entrypoint, platforms, dart_defines = {}, srcs = [], **kwargs):
    """Declares a debug artifact of an app's core, compiled from another entrypoint.

    The artifact is debug only: a release configuration reports it incompatible,
    and it is `manual` by default, so `bazel build //...` does not build it.

    Args:
      name: the artifact's target name.
      app: the app's `flutter_core` target. It may be in another package, under
        restrictive visibility, or an alias; only its own visibility applies.
      entrypoint: the Dart file compiled as `main`. A file under the app's lib/
        compiles as `package:<app>/...`; other files compile by their execroot path.
      platforms: descriptors returned by flutter_platform; required to select the
        platform-specific neutral bundle and asset tree.
      dart_defines: `-D` constants of this artifact's kernel. The app's are not inherited.
      srcs: Dart files outside lib/ that the entrypoint imports by relative path,
        such as helpers under integration_test/. They must be declared for the
        kernel's sandbox.
      **kwargs: `tags`, default ["manual"]; `target_compatible_with`, combined
        with the debug-only constraint; `testonly` for every helper; and
        `visibility` for the artifact.
    """

    if not platforms:
        fail("flutter_debug_core: at least one platform is required.")
    testonly = kwargs.pop("testonly", False)
    tags = kwargs.pop("tags", ["manual"])

    # The debug-only constraint is always kept; a caller's constraints add to it.
    # Keep every helper manual and debug-only so wildcard builds cannot request
    # an intermediate target in a configuration where the public artifact is incompatible.
    compatible = debug_target_compatible_with() + kwargs.pop("target_compatible_with", [])
    internal = {"tags": ["manual"], "target_compatible_with": compatible, "testonly": testonly}

    bundle_select = {}

    for platform in platforms:
        kernel = name + "_kernel_" + platform.name
        _flutter_debug_kernel(
            name = kernel,
            app = app,
            target_platform = str(platform.target_platforms[0]),
            entrypoint = entrypoint,
            dart_defines = dart_defines,
            srcs = srcs,
            **internal
        )
        kernel_neutral = name + "_kernel_neutral_" + platform.name
        platform.neutral_files_rule(
            name = kernel_neutral,
            src = ":" + kernel,
            **internal
        )
        bundle_action = name + "_bundle_action_" + platform.name
        _flutter_debug_bundle_action(
            name = bundle_action,
            app = app,
            target_platform = str(platform.target_platforms[0]),
            kernel = [":" + kernel_neutral],
            **internal
        )
        bundle = name + "_bundle_" + platform.name
        platform.neutral_files_rule(
            name = bundle,
            src = ":" + bundle_action,
            **internal
        )
        bundle_select[platform.constraint] = [":" + bundle]
    bundle_select["//conditions:default"] = [":" + name + "_bundle_" + platforms[0].name]

    native.filegroup(
        name = name + "_bundle",
        srcs = select(bundle_select),
        tags = tags,
        testonly = testonly,
        target_compatible_with = compatible,
        visibility = kwargs.get("visibility"),
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
