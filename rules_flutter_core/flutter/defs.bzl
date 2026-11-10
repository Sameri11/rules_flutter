"""Supported convenience BUILD API for Flutter consumer modules."""

load("//flutter/private:core.bzl", _flutter_core = "flutter_core")
load("//flutter/private:flutter_test.bzl", _flutter_test = "flutter_test", _flutter_test_suite = "flutter_test_suite")
load("//flutter/private:integration_test.bzl", _flutter_integration_test = "flutter_integration_test")
load("//flutter/private:pubspec.bzl", _flutter_pubspec = "flutter_pubspec")
load("//flutter/private:rules.bzl", _flutter_package = "flutter_package")

flutter_core = _flutter_core
flutter_package = _flutter_package
flutter_test = _flutter_test
flutter_test_suite = _flutter_test_suite
flutter_integration_test = _flutter_integration_test
flutter_pubspec = _flutter_pubspec
