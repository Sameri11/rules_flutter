# Android integration tests

Integration tests run against an Android device or emulator and are distinct from [debug test APKs packaged as the app](android-builds.md#package-a-debug-test-apk-as-the-app), which do not use an integration-test runner.

Place each `integration_test` source in the package root and declare it with `flutter_integration_test`. Pass its label to `flutter_android_app`:

```python
load("@rules_flutter_core//flutter:defs.bzl", "flutter_integration_test")
load("@rules_flutter_android//flutter:defs.bzl", "FLUTTER_ANDROID", "flutter_android_app")

flutter_integration_test(
    name = "login",
    app = ":core",
    src = "integration_test/login_test.dart",
    platforms = [FLUTTER_ANDROID],
)

flutter_android_app(
    name = "app",
    integration_tests = {"//:login": {}},
)
```

The integration-test label is `//:login`; `flutter_android_app` itself is in `//android/app` in this example, so pass the test label explicitly rather than a package-relative `:login`. The app macro generates `//android/app:app_login` (test APK) and `//android/app:app_login_test` (runner). Run `bazel test --@rules_flutter_core//flutter:mode=debug //android/app:app_login_test`; consider putting the mode flag in `.bazelrc`.


The host provides the emulator/device and adb server. The server's adb version must match the adb from the declared Android SDK; start the emulator or start the server with that SDK's adb. An exported `ANDROID_SERIAL` is inherited by the test; alternatively pass `--test_env=ANDROID_SERIAL=<serial>`.

The test APK has the same `applicationId` as the development app, replaces it while running, and is uninstalled afterward. In the Dart test, create `${Directory.systemTemp.path}/rules_flutter_test/outputs/` and write files there (for example with `Directory.create(recursive: true)` and `File.writeAsString`). The runner copies those files into Bazel's `test.outputs` directory. It always adds `manual`, `external`, and `exclusive` tags. The rule has no `data` or `env` attributes; use `dart_defines` for device-visible configuration. `--test_filter` selects cases. Sharding is not supported yet.
