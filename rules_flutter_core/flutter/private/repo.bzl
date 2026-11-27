"""Repository rules for the provisioned Flutter SDK."""

load(":pub_lock_parser.bzl", "parse_pubspec_lock")

visibility(["//flutter"])

def _flutter_sdk_stub(ctx):
    ctx.file("pubspec.lock", "packages: {}\nsdks: {}\n")
    ctx.file("pubspec.yaml", "name: flutter_tools\n")
    ctx.file("packages/flutter_tools/bin/flutter_tools.dart", "")
    build = """load(%s, "flutter_sdk_missing")

package(default_visibility = ["//visibility:public"])

exports_files(["pubspec.lock", "pubspec.yaml", "packages/flutter_tools/bin/flutter_tools.dart"])
""" % repr(str(Label("//flutter/private:sdk_failure.bzl")))
    for target in [
        "dart",
        "dart_sdk_revision",
        "dartaotruntime",
        "vm_platform_strong.dill",
        "flutter",
        "frontend_server.snapshot",
        "flutter.version.json",
        "engine_stamp.json",
        "vm_isolate_snapshot.bin",
        "isolate_snapshot.bin",
        "flutter_tester",
        "icudtl.dat",
        "impellerc",
        "dart_sdk_files",
        "platform_product",
        "platform_debug",
        "sdk_packages",
        "framework_tools_lib",
        "flutter_tools_cache_state",
        "framework_source_root",
        "dart_sdk_root",
        "patched_sdk_root",
        "patched_sdk_product_root",
        "sky_engine_root",
        "flutter_gpu_root",
        "host_artifacts_root",
        "font_subset_root",
        "material_fonts_root",
        "gradle_wrapper_root",
        "ios_usb_libimobiledevice_root",
        "ios_usb_libusbmuxd_root",
        "ios_usb_libplist_root",
        "ios_usb_openssl_root",
        "ios_usb_libimobiledeviceglue_root",
        "ios_usb_ios_deploy_root",
    ]:
        build += """flutter_sdk_missing(
    name = %s,
    message = "The root module must declare flutter.sdk(version = \\"X.Y.Z\\") to build Flutter targets.",
)
""" % repr(target)
    ctx.file("BUILD.bazel", build)

flutter_sdk = repository_rule(
    implementation = _flutter_sdk_stub,
    attrs = {
        "version": attr.string(mandatory = True),
    },
)

def _flutter_tools_lockfile_impl(ctx):
    if ctx.attr.source:
        ctx.file("pubspec.lock", ctx.read(ctx.attr.source))
        ctx.file("pubspec.yaml", ctx.read(ctx.attr.pubspec_source))
    elif ctx.attr.url:
        if not ctx.attr.sha256:
            fail("A Flutter tools lockfile URL requires a sha256.")
        ctx.download(
            url = ctx.attr.url,
            output = "pubspec.lock",
            sha256 = ctx.attr.sha256,
        )
        lock = parse_pubspec_lock(ctx.read("pubspec.lock"))
        dart_constraint = lock["sdks"].get("dart")
        if not dart_constraint:
            fail("The Flutter tools lockfile has no Dart SDK constraint.")
        ctx.file(
            "pubspec.yaml",
            "name: _flutter_packages\nenvironment:\n  sdk: \"{}\"\n".format(dart_constraint),
        )
    else:
        ctx.file("pubspec.lock", "packages: {}\nsdks: {}\n")
        ctx.file("pubspec.yaml", "name: flutter_tools\n")
    ctx.file("BUILD.bazel", "exports_files([\"pubspec.lock\", \"pubspec.yaml\"])\n")

flutter_sdk_lockfile = repository_rule(
    implementation = _flutter_tools_lockfile_impl,
    attrs = {
        "source": attr.label(allow_single_file = True),
        "pubspec_source": attr.label(allow_single_file = True),
        "url": attr.string(),
        "sha256": attr.string(),
    },
)
