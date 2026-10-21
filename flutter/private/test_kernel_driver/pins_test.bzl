"""Checks on the driver's pin table: every pinned version has complete, well-formed entries."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":pins.bzl", "PINS")

def _pins_are_complete_test(ctx):
    env = unittest.begin(ctx)
    for version, pin in PINS.items():
        asserts.equals(env, 40, len(pin["dart_revision"]), version + " dart_revision")
        asserts.equals(env, 40, len(pin["native_commit"]), version + " native_commit")
        asserts.equals(env, 64, len(pin["sdk_sha256"]), version + " sdk_sha256")
        asserts.equals(env, 64, len(pin["native_sha256"]), version + " native_sha256")
        archives = {"{}-{}".format(name, ver): sha for name, ver, sha in pin["pub_archives"]}
        for _, root, _ in pin["packages"]:
            if root.startswith("pub/"):
                dir_name = root[len("pub/"):].rstrip("/")
                asserts.true(env, dir_name in archives, version + " has no archive for " + dir_name)
        for name, ver, sha in pin["pub_archives"]:
            asserts.equals(env, 64, len(sha), "sha256 of {}-{}".format(name, ver))
    return unittest.end(env)

pins_are_complete_test = unittest.make(_pins_are_complete_test)

def pins_test_suite(name):
    """Instantiates the pin table tests and a suite named `name` holding them.

    The unpinned path is checked by unpinned_driver_test in tests/test_kernel_driver.
    """
    unittest.suite(
        name,
        pins_are_complete_test,
    )
