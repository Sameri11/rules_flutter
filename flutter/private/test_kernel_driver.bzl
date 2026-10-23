"""The test-kernel driver: a Dart program over the SDK's own front_end, built as a kernel.

- `test_kernel_driver_src` fetches the driver's source closure at the pins for the Flutter
  version in use and writes driver.dill's sources into one repository. Without a pin it writes
  empty files, and `driver_dill` then builds no driver.dill.
- `driver_dill` compiles driver.dill with the toolchain's frontend_server and VM platform.
  Paths in argv are repository-relative, and the kernel uses org-dartlang-root URIs, so the
  bytes do not depend on where the checkout is. -Dsdk_hash comes from the toolchain's Dart SDK
  revision. The driver itself rejects a -Dsdk_hash that differs from the import dill's header.
"""

load("//flutter/private/test_kernel_driver:pins.bzl", "PINS")

visibility(["//flutter/...", "//tests/..."])

_ATTEMPTS = 3

def _fetch(rctx, url, sha256, strip_prefix, output):
    """Downloads and unpacks `url`, retrying a bounded number of times on transient failures."""
    for attempt in range(_ATTEMPTS):
        res = rctx.download_and_extract(
            url = [url],
            sha256 = sha256,
            strip_prefix = strip_prefix,
            output = output,
            allow_fail = True,
        )
        if res.success:
            return
        if attempt + 1 < _ATTEMPTS:
            rctx.execute(["sleep", "5"])
    fail("test_kernel_driver: fetching {} failed after {} attempts: {}".format(url, _ATTEMPTS, res.error))

_NO_DRIVER_BUILD = """package(default_visibility = ["//visibility:public"])

exports_files(["driver.dart", "package_config.json"])

filegroup(name = "srcs", srcs = [])
"""

def _test_kernel_driver_src_impl(rctx):
    version = json.decode(rctx.read(rctx.attr.version_file))["frameworkVersion"]
    pin = PINS.get(version)
    if pin == None:
        rctx.file("driver.dart", "")

        # buildifier: disable=print
        print("test_kernel_driver: Flutter {} has no driver pin; test kernels use the slower frontend_server action. Add the version to pins.bzl to use the driver.".format(version))
        rctx.file("package_config.json", "{}\n")
        rctx.file("BUILD.bazel", _NO_DRIVER_BUILD)
        return

    host = rctx.read(rctx.attr.sdk_revision).strip()
    rev = pin["dart_revision"]
    if host != rev:
        fail("test_kernel_driver: Flutter {} has Dart revision {}, but its driver pin is {}. Update the pin in flutter/private/test_kernel_driver/pins.bzl.".format(version, host, rev))

    _fetch(rctx, "https://github.com/dart-lang/sdk/archive/{}.tar.gz".format(rev), pin["sdk_sha256"], "sdk-" + rev, "sdk")
    _fetch(rctx, "https://github.com/dart-lang/native/archive/{}.tar.gz".format(pin["native_commit"]), pin["native_sha256"], "native-" + pin["native_commit"], "native")
    for name, ver, sha256 in pin["pub_archives"]:
        _fetch(rctx, "https://pub.dev/api/archives/{}-{}.tar.gz".format(name, ver), sha256, "", "pub/{}-{}".format(name, ver))

    rctx.file("driver.dart", rctx.read(rctx.attr.driver_source))
    rctx.file("package_config.json", json.encode_indent({
        "configVersion": 2,
        "packages": [{"name": name, "rootUri": root, "packageUri": package_uri} for name, root, package_uri in pin["packages"]],
    }, indent = "  ") + "\n")

    srcs = ["sdk/pkg/{}/lib/**".format(p) for p in pin["sdk_pkgs"]] + \
           ["sdk/pkg/{}/pubspec.yaml".format(p) for p in pin["sdk_pkgs"]] + \
           ["native/pkgs/record_use/lib/**", "native/pkgs/record_use/pubspec.yaml", "pub/*/lib/**", "pub/*/pubspec.yaml"]
    rctx.file("BUILD.bazel", """package(default_visibility = ["//visibility:public"])

exports_files(["driver.dart", "package_config.json"])

filegroup(
    name = "srcs",
    srcs = glob({srcs}, allow_empty = False) + [
        "driver.dart",
        "package_config.json",
    ],
)
""".format(srcs = json.encode(srcs)))

test_kernel_driver_src = repository_rule(
    implementation = _test_kernel_driver_src_impl,
    doc = "The driver's source closure for the pinned Flutter version, with its package config.",
    attrs = {
        "version_file": attr.label(allow_single_file = True, mandatory = True),
        "driver_source": attr.label(allow_single_file = True, mandatory = True),
        "sdk_revision": attr.label(allow_single_file = True, mandatory = True),
    },
)

def _driver_dill_impl(ctx):
    if not ctx.files.srcs:
        return [DefaultInfo()]

    tc = ctx.toolchains["//flutter/private:flutter_toolchain_type"].flutter
    revision = ctx.file.revision or tc.dart_sdk_revision
    out = ctx.actions.declare_file(ctx.label.name + ".dill")

    # --platform is relative to --sdk-root, which is the directory holding the platform file.
    # The package root and driver paths are repository-relative: no checkout path reaches argv.
    root = ctx.file.driver.dirname
    command = " ".join([
        "h=$(cut -c1-10 " + revision.path + ");",
        tc.dartaotruntime.path,
        tc.frontend_server.path,
        "--target=vm",
        "--no-print-incremental-dependencies",
        "--platform=" + tc.vm_platform_strong.basename,
        "--sdk-root=" + tc.vm_platform_strong.dirname + "/",
        "-Dsdk_hash=$h",
        "--filesystem-root=" + root,
        "--filesystem-scheme=org-dartlang-root",
        "--packages=org-dartlang-root:///package_config.json",
        "--output-dill=" + out.path,
        "org-dartlang-root:///driver.dart",
    ])
    ctx.actions.run_shell(
        outputs = [out],
        inputs = ctx.files.srcs + [tc.frontend_server, tc.vm_platform_strong, revision],
        tools = [tc.dartaotruntime],
        command = "set -eu\n" + command + "\n",
        mnemonic = "TestKernelDriver",
        progress_message = "Compiling the test-kernel driver %{output}",
    )
    return [DefaultInfo(files = depset([out]))]

driver_dill = rule(
    implementation = _driver_dill_impl,
    doc = "driver.dill: the test-kernel driver compiled by the toolchain's frontend_server. Builds nothing when the Flutter version has no pin.",
    attrs = {
        "driver": attr.label(allow_single_file = [".dart"], mandatory = True),
        "srcs": attr.label_list(allow_files = True, mandatory = True),
        "revision": attr.label(
            allow_single_file = True,
            doc = "Test-only override of the SDK revision file; the toolchain's is used when unset.",
        ),
    },
    toolchains = ["//flutter/private:flutter_toolchain_type"],
)
