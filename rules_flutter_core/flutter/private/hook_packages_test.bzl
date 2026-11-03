"""Tests for analysis-time native-hook package matching."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":hook_packages.bzl", "staged_hook_packages")

visibility(["//flutter"])

def _staged_hook_packages_test(ctx):
    env = unittest.begin(ctx)
    packages = {
        "app": "app",
        "production_dep": "external/pub-production_dep",
    }
    staged = [
        "app/hook/build.dart",
        "external/pub-production_dep/hook/build.dart",
        "external/pub-link_only/hook/link.dart",
        "external/pub-unmapped/hook/build.dart",
    ]
    asserts.equals(env, ["app", "production_dep"], staged_hook_packages(packages, staged))
    asserts.equals(env, ["app"], staged_hook_packages({"app": ""}, ["hook/build.dart"]))
    asserts.equals(env, [], staged_hook_packages({"app": ""}, ["lib/hook/build.dart"]))
    asserts.equals(env, [], staged_hook_packages(packages, []))
    asserts.equals(env, [], staged_hook_packages({"app": ""}, ["hook/build.dartx"]))
    asserts.equals(env, [], staged_hook_packages({"dep": "external/dep"}, ["external/dep/hook/link.dart"]))
    asserts.equals(env, [], staged_hook_packages({"dep": "external/dep"}, ["external/dep/hook/build_extra.dart"]))
    return unittest.end(env)

staged_hook_packages_test = unittest.make(_staged_hook_packages_test)
