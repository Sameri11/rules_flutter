"""The test-kernel driver: the resident compiler that the test-kernel worker runs.

The `test_kernel_driver` repository fetches the closure of the driver (pins in
test_kernel_driver/pins.bzl), builds driver.dill from it with the flutter_sdk's own
frontend_server, and exposes it as `@test_kernel_driver//:driver.dill`.

- Source: the SDK at SDK_COMMIT (sparse checkout), with record_use from the native repository at
  NATIVE_COMMIT (the SDK's DEPS revision). The other packages are pub archives, each pinned by sha256.
- The host SDK must be the pinned commit (flutter_sdk's dart-sdk/revision). Any other revision fails
  the fetch.
- The build uses -Dsdk_hash=<SDK_COMMIT[:10]>. The output header (offset 8, 10 bytes) must equal
  that hash. A missing define writes zeros and is rejected here; the worker also rejects an output
  whose header differs from its import dill.
- Paths: the package config and the driver source use repository-relative roots, and the kernel
  uses org-dartlang-root URIs, so the bytes do not depend on where the repository is fetched.
"""

load(
    "//flutter/private/test_kernel_driver:pins.bzl",
    "NATIVE_COMMIT",
    "PACKAGE_ROOTS",
    "PUB_ARCHIVES",
    "SDK_COMMIT",
    "SDK_SPARSE_PATHS",
)

visibility(["//"])

_SDK_GIT = "https://dart.googlesource.com/sdk.git"
_NATIVE_GIT = "https://dart.googlesource.com/native.git"
_NATIVE_SPARSE_PATHS = ["pkgs/record_use"]

def _run(rctx, args, what):
    res = rctx.execute(args)
    if res.return_code != 0:
        fail("test_kernel_driver: {} failed (exit {}):\n{}\n{}".format(
            what,
            res.return_code,
            res.stdout[-4000:],
            res.stderr[-4000:],
        ))
    return res

def _run_with_retry(rctx, args, what):
    """`_run` for network steps: up to three attempts with backoff between them."""
    res = None
    for attempt in range(3):
        if attempt > 0:
            rctx.execute(["sleep", str(10 * attempt)])
        res = rctx.execute(args)
        if res.return_code == 0:
            return res
    fail("test_kernel_driver: {} failed after 3 attempts (last exit {}):\n{}\n{}".format(
        what,
        res.return_code,
        res.stdout[-4000:],
        res.stderr[-4000:],
    ))

def _sparse_checkout(rctx, git_url, commit, paths, dest):
    """A depth-1, blobless, sparse checkout of `commit` at `dest` (under the repository root)."""
    _run(rctx, ["git", "init", "-q", dest], "git init " + dest)
    _run(rctx, ["git", "-C", dest, "remote", "add", "origin", git_url], "git remote " + git_url)
    # The upstream host intermittently answers 503 mid-fetch; retry a bounded number of times.
    _run_with_retry(
        rctx,
        ["git", "-C", dest, "fetch", "-q", "--depth=1", "--filter=blob:none", "origin", commit],
        "git fetch " + git_url + "@" + commit,
    )
    _run(rctx, ["git", "-C", dest, "sparse-checkout", "set"] + paths, "git sparse-checkout " + dest)
    # A blobless checkout fetches its blobs over the network; the same intermittent upstream failure applies.
    _run_with_retry(rctx, ["git", "-C", dest, "checkout", "-q", "FETCH_HEAD"], "git checkout " + dest)

def _test_kernel_driver_impl(rctx):
    host_revision = rctx.read(rctx.attr.sdk_revision).strip()
    if host_revision != SDK_COMMIT:
        fail("test_kernel_driver: the host Dart SDK is {} but the driver is pinned to {}. Update the Flutter SDK or the pins in test_kernel_driver/pins.bzl.".format(host_revision, SDK_COMMIT))

    _sparse_checkout(rctx, _SDK_GIT, SDK_COMMIT, SDK_SPARSE_PATHS, "sdk")
    _sparse_checkout(rctx, _NATIVE_GIT, NATIVE_COMMIT, _NATIVE_SPARSE_PATHS, "native")
    # Same unpack as pub_lock.bzl's _pub_archive: download stays sha256-pinned, and
    # `gzip -dc | tar -x` tolerates trailing gzip padding that Bazel's extractor rejects.
    for name, version, sha256, url in PUB_ARCHIVES:
        dest = "pub/{}-{}".format(name, version)
        rctx.download(url = [url], output = dest + "/_pub_archive.tar.gz", sha256 = sha256)
        result = rctx.execute(["sh", "-c", 'gzip -dc "$1" | tar -xf -', "sh", "_pub_archive.tar.gz"], working_directory = dest)
        if result.return_code:
            fail("pub archive {}-{}: unpacking failed: {}".format(name, version, result.stderr))
        rctx.delete(dest + "/_pub_archive.tar.gz")

    rctx.file("package_config.json", json.encode_indent({
        "configVersion": 2,
        "packages": [
            {"name": name, "rootUri": root, "packageUri": package_uri}
            for name, root, package_uri in PACKAGE_ROOTS
        ],
    }, indent = "  ") + "\n")
    rctx.file("driver.dart", rctx.read(rctx.attr.driver_source))
    # frontend_server requires an --sdk-root directory. The platform is given explicitly with
    # --platform, so the directory is an empty placeholder and nothing under it is read.
    rctx.file("sdk-root/placeholder.txt", "The platform is passed with --platform; this directory only satisfies --sdk-root.\n")

    sdk_hash = SDK_COMMIT[:10]
    _run(rctx, [
        str(rctx.path(rctx.attr.dartaotruntime)),
        str(rctx.path(rctx.attr.frontend_server)),
        "--target=vm",
        "--no-print-incremental-dependencies",
        "--platform=" + str(rctx.path(rctx.attr.platform)),
        "--sdk-root=sdk-root/",
        "-Dsdk_hash=" + sdk_hash,
        "--filesystem-root=.",
        "--filesystem-scheme=org-dartlang-root",
        "--packages=org-dartlang-root:///package_config.json",
        "--output-dill=driver.dill",
        "org-dartlang-root:///driver.dart",
    ], "driver compile")

    header = _run(rctx, ["dd", "if=driver.dill", "bs=1", "skip=8", "count=10"], "read driver header").stdout
    if header != sdk_hash:
        fail("test_kernel_driver: driver header is '{}', expected '{}' (is -Dsdk_hash set?)".format(header, sdk_hash))

    rctx.file("BUILD.bazel", """package(default_visibility = ["//visibility:public"])

exports_files(["driver.dill"])
""")

_test_kernel_driver_repo = repository_rule(
    implementation = _test_kernel_driver_impl,
    doc = "The test-kernel driver, built from the pinned SDK source. See the file comment.",
    attrs = {
        "driver_source": attr.label(allow_single_file = True, mandatory = True),
        "sdk_revision": attr.label(allow_single_file = True, mandatory = True),
        "dartaotruntime": attr.label(allow_single_file = True, mandatory = True),
        "frontend_server": attr.label(allow_single_file = True, mandatory = True),
        "platform": attr.label(allow_single_file = True, mandatory = True),
    },
)

def _test_kernel_driver_ext_impl(mctx):
    _test_kernel_driver_repo(
        name = "test_kernel_driver",
        driver_source = Label("//flutter/private/test_kernel_driver:driver.dart"),
        sdk_revision = Label("@flutter_sdk//:dart_sdk_revision"),
        dartaotruntime = Label("@flutter_sdk//:dartaotruntime"),
        frontend_server = Label("@flutter_sdk//:frontend_server.snapshot"),
        platform = Label("@flutter_sdk//:vm_platform_strong.dill"),
    )

test_kernel_driver = module_extension(
    implementation = _test_kernel_driver_ext_impl,
    doc = "Declares @test_kernel_driver, the test-kernel driver built from pinned SDK sources.",
)
