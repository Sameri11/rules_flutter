"""Supported convenience BUILD API for Flutter consumer modules."""

load("//flutter/private:core.bzl", _default_platform_neutral_files = "platform_neutral_files", _flutter_core = "flutter_core", _platform_neutral_files_rule = "platform_neutral_files_rule")
load("//flutter/private:flutter_test.bzl", _flutter_test = "flutter_test", _flutter_test_suite = "flutter_test_suite")
load("//flutter/private:integration_test.bzl", _flutter_integration_test = "flutter_integration_test")
load("//flutter/private:pubspec.bzl", _flutter_pubspec = "flutter_pubspec")
load("//flutter/private:rules.bzl", _flutter_default_target_slices = "flutter_target_slices", _flutter_package = "flutter_package", _flutter_target_slices_rule = "flutter_target_slices_rule")

flutter_core = _flutter_core

def flutter_platform(name, target_platforms, constraint, slices_rule = None, neutral_files_rule = None):
    """Describes target slices, slice configuration and neutral-file configuration."""
    if not target_platforms:
        fail("flutter_platform: target_platforms must not be empty.")
    return struct(
        name = name,
        target_platforms = target_platforms,
        constraint = constraint,
        slices_rule = slices_rule or _flutter_default_target_slices,
        neutral_files_rule = neutral_files_rule or _default_platform_neutral_files,
    )

flutter_target_slices_rule = _flutter_target_slices_rule
platform_neutral_files_rule = _platform_neutral_files_rule

flutter_package = _flutter_package
flutter_test = _flutter_test
flutter_test_suite = _flutter_test_suite
flutter_integration_test = _flutter_integration_test
flutter_pubspec = _flutter_pubspec
