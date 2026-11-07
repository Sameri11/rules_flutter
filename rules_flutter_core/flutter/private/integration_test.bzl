"""Platform-neutral integration-test kernels and metadata."""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load(":core.bzl", "FlutterArtifactInfo")
load(":debug_core.bzl", "flutter_debug_core")
load(":flutter_test.bzl", "DEVICE_DRIVER_SRCS", "NATIVE_REPORT_DEFINE", "flutter_test_bootstrap")
load(":test_metadata.bzl", "parse_metadata")

visibility(["//flutter/..."])

FlutterIntegrationTestInfo = provider(fields = {
    "core": "The debug core target used by the Android test APK.",
    "data": "Runtime runfiles for the host runner.",
    "env": "Environment passed to the host runner.",
})



def _integration_test_info_impl(ctx):
    core = ctx.attr.core[FlutterArtifactInfo]
    return [
        DefaultInfo(files = ctx.attr.core[DefaultInfo].files),
        FlutterArtifactInfo(
            mode = core.mode,
            abi = core.abi,
            libapp = core.libapp,
            engine_libs = core.engine_libs,
            embedding_jar = core.embedding_jar,
            assets = core.assets,
        ),
        FlutterIntegrationTestInfo(core = ctx.attr.core.label, data = ctx.files.data, env = ctx.attr.env),
    ]


_integration_test_info = rule(
    implementation = _integration_test_info_impl,
    attrs = {
        "core": attr.label(mandatory = True, providers = [FlutterArtifactInfo]),
        "data": attr.label_list(allow_files = True),
        "env": attr.string_dict(),
    },
)




def flutter_integration_test(name, app, src, srcs = [], dart_defines = {}, data = [], env = {}):
    """Declares one platform-neutral integration-test file."""
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
        data = data,
        env = env,
        tags = ["manual"],
        testonly = True,
    )
