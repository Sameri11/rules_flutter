# Host tests

`flutter_test` declares a host test target and `flutter_test_suite` groups host tests. These use host-platform assets and do not require Android packaging or a device. A `flutter_core` exposes `<name>_test_package`, a public generated target for host tests to pass to `package`. Set `visibility` on `flutter_core` if you declare host tests in another Bazel package. Declare imports through the generated pub hub.

See the checked [`examples/no_plugins/BUILD.bazel`](../examples/no_plugins/BUILD.bazel) for the host test suite shape and [`examples/local_plugin`](../examples/local_plugin/) for package-scoped layouts.

For a suite that discovers all tests under `test/`, use the package test output:

```python
load("@rules_flutter_core//flutter:defs.bzl", "flutter_test_suite")

flutter_test_suite(
    name = "tests",
    srcs = glob(["test/**/*_test.dart"]),
    package = ":core_test_package",
)
```

Run it with `bazel test //:tests`. Use individual `flutter_test` targets when tests need explicit `data`, materialization, or `dart_defines`; add those targets to the suite's `tests` attribute as shown in [`examples/demo_app/BUILD.bazel`](../examples/demo_app/BUILD.bazel). Host tests compile against host-platform assets and need no Android device. The pub hub builds a shared debug kernel for packages imported by the tests. If an imported package cannot compile in that shared kernel but should be compiled by a particular test instead, the `pub.lock` tag's `test_deps_exclude` can exclude that package from the shared kernel; the test still compiles its own direct dependency.

The wildcard command `bazel test //...` retains Bazel's normal target universe: it can also analyze non-test app artifacts, which require an Android app configuration. Use `bazel test --build_tests_only //...` to select the tests and their dependencies without unrelated non-test roots, or name a host suite explicitly when running only host tests. Consumer-declared platform-specific targets must declare their own `target_compatible_with`.
