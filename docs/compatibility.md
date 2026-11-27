# Compatibility with `flutter_tools`

This project is a community-maintained Android-only development preview, not affiliated with, endorsed by, or supported by Google or the Flutter project. CI tests the Flutter version pinned in `.github/workflows/ci.yml` and the Bazel version configured there, on macOS 15 arm64 and Ubuntu Linux x64. Other versions may work but are unverified.

| Feature | Stock Flutter | rules_flutter | Notes |
| --- | --- | --- | --- |
| Android release builds | `flutter build apk --release` | Implemented | Build with `-c opt`. |
| Android debug builds | `flutter build apk --debug` | Implemented | Build with `-c fastbuild` and `--@rules_flutter_core//flutter:mode=debug`. |
| Android profile builds | `flutter build apk --profile` | Not implemented | Debug and release only. |
| Split APKs by architecture | `--split-per-abi` | Implemented | Select ABI set through `--android_platforms`; one APK label per app/mode variant. See [Android builds](android-builds.md#abi-configuration-and-switching). |
| Android App Bundles (AAB) | `flutter build appbundle` | Not implemented | APKs only. |
| Dart defines | `--dart-define`, `--dart-define-from-file` | Partial | `flutter_core(dart_defines = {...})`, `flutter_debug_core(dart_defines = {...})` and `flutter_test(dart_defines = {...})`; no `--dart-define-from-file`. |
| Android plugins and native packages | Standard Flutter/Gradle workflow | Partial | Common Java/Kotlin and CMake plugins work; custom build logic and native assets need recipes. See [Plugins](plugins.md). |
| Release signing | Gradle signing configuration | Not implemented | Sign the unsigned output outside the build. |
| Product flavors | `--flavor` | Not implemented | Declare separate Bazel targets instead. |
| iOS, web, desktop | Platform-specific builds | Not implemented | Android only. |
| Unit and widget tests | `flutter test` | Partial | `flutter_test` and `flutter_test_suite` run host tests; see [Host tests](host-tests.md). |
| Integration tests | `flutter test integration_test` | Partial | `flutter_integration_test` with `flutter_android_app(integration_tests = ...)` runs on an Android device or emulator; no sharding. See [Android integration tests](android-integration-tests.md). |

## Supported behavior and constraints

- Supported Android ABIs are `arm64-v8a`, `x86_64`, and `armeabi-v7a`; 32-bit `x86`, `riscv64`, and other values are unsupported.
- Supported plugin shapes include pub plugins with Java/Kotlin Android halves, CMake native halves, local path plugins, consumer-written Package Recipes, and Dart build-hook packages surfaced through recipes. Automatic generation does not support `ndk-build` or plugins whose Android half ships prebuilt JNI libraries. Coordinates that cannot be read statically require `plugins.package(artifacts = ...)`.
- CI builds and hash-checks examples per host; this does not establish cross-machine reproducibility.
- CI uses Flutter 3.50.1 (Dart 3.14.0). The host test-kernel driver is pinned for Flutter 3.47.3 and 3.50.1; other versions compile through `frontend_server`. Separately, only 3.50.1 has a metadata parser pin. Other versions use that parser with a warning.
- Generated Android registrants initialize plugin dependencies before their dependents, with alphabetical tie-breaking. This can change registration order on older Flutter SDKs too.
- The `flutter.sdk` extension provisions a pinned Flutter SDK through Bazel; Android SDK and Android NDK 28+ remain local, non-hermetic prerequisites. Dart compilation is not incremental. Debug APKs are debug-key-signed; release produces an unsigned APK and release signing occurs outside Bazel. See [Android builds](android-builds.md).
- Android is the only implemented app backend; host test and asset views do not require an app Target OS. The same `flutter_core` declaration serves host unit/widget tests and Android app configurations. Host tests do not need an app Target OS; Android app builds select the AOT kernel from their configured Target OS. No per-OS core declarations are needed.
