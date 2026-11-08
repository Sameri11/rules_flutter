"""Platform-neutral integration-test kernels and metadata."""

load(":core.bzl", "FlutterArtifactInfo")
load(":debug_core.bzl", "flutter_debug_core")
load(":flutter_test.bzl", "DEVICE_DRIVER_SRCS", "NATIVE_REPORT_DEFINE", "flutter_test_bootstrap")
load(":test_metadata.bzl", "parse_metadata")

visibility(["//flutter/..."])

FlutterIntegrationTestInfo = provider(
    "Metadata for a declared integration test, independent of its platform runner.",
    fields = {
        "core": "The debug core artifact for this integration test.",
    },
)

def _integration_test_info_impl(ctx):
    core = ctx.attr.core[FlutterArtifactInfo]
    return [
        DefaultInfo(files = ctx.attr.core[DefaultInfo].files),
        core,
        FlutterIntegrationTestInfo(core = ctx.attr.core.label),
    ]

_integration_test_info = rule(
    implementation = _integration_test_info_impl,
    attrs = {
        "core": attr.label(mandatory = True, providers = [FlutterArtifactInfo]),
    },
)

def flutter_integration_test(name, app, src, srcs = [], dart_defines = {}, visibility = None):
    """Declares one platform-neutral integration-test file.

    Args:
        name: Name for the generated targets.
        app: Flutter application target used to compile the test.
        src: Integration-test Dart source file.
        srcs: Additional Dart sources needed by the test.
        dart_defines: Compile-time Dart environment values.
        visibility: Visibility for this declaration.
    """
    metadata = name + "_metadata"
    parse_metadata(name = metadata, src = src, tags = ["manual"])
    all_srcs = [src] + srcs + DEVICE_DRIVER_SRCS + [":" + metadata]
    bootstrap = name + "_bootstrap"
    flutter_test_bootstrap(
        name = bootstrap,
        src = src,
        srcs = all_srcs,
        app = app,
        test_label = "//{}:{}".format(native.package_name(), name),
        goldens_declared = False,
        metadata = ":" + metadata,
        device = True,
        tags = ["manual"],
    )
    defines = dict(dart_defines)
    defines[NATIVE_REPORT_DEFINE] = "false"
    core = name + "_core"
    flutter_debug_core(
        name = core,
        app = app,
        entrypoint = ":" + bootstrap,
        srcs = all_srcs,
        dart_defines = defines,
        tags = ["manual"],
        testonly = True,
    )
    _integration_test_info(
        name = name,
        core = ":" + core,
        tags = ["manual"],
        testonly = True,
        visibility = visibility,
    )
