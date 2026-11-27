"""Repository rules for the provisioned Flutter SDK."""

load(":pub_lock_parser.bzl", "parse_pubspec_lock")

visibility(["//flutter"])

def _flutter_sdk_stub(ctx):
    ctx.file("pubspec.lock", "packages: {}\nsdks: {}\n")
    ctx.file("pubspec.yaml", "name: flutter_tools\n")
    ctx.file("packages/flutter_tools/bin/flutter_tools.dart", "")
    message = ctx.attr.failure_message or "The root module must declare flutter.sdk(version = \"X.Y.Z\") to build Flutter targets."
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
    ]:
        build += """flutter_sdk_missing(
    name = %s,
    message = %s,
)
""" % (repr(target), repr(message))
    ctx.file("BUILD.bazel", build)

flutter_sdk = repository_rule(
    implementation = _flutter_sdk_stub,
    attrs = {"failure_message": attr.string()},
)

def _flutter_tools_lockfile_impl(ctx):
    if ctx.attr.url:
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
        "url": attr.string(),
        "sha256": attr.string(),
    },
)
