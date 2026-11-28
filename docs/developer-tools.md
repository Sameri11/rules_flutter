# Developer tools

The core module exposes the provisioned SDK through two `bazel run` targets:

- `bazel run @rules_flutter_core//flutter -- <args>` runs Flutter's CLI.
- `bazel run @rules_flutter_core//flutter:dart -- <args>` runs Dart.

Both resolve the SDK from the registered Flutter toolchain. Select its version
with `flutter.sdk(version = "…")` in `MODULE.bazel`. To use another registered
SDK for one command, pass `--extra_toolchains=<toolchain-label>` to Bazel. The
wrapper runs from `BUILD_WORKING_DIRECTORY` when Bazel sets it and forwards
arguments, stdin, and the tool's exit status.

The documented supported complement includes these Flutter commands:

- `flutter analyze`, `flutter test`, `flutter devices`, and `flutter gen-l10n`;
- `flutter pub get`, `flutter pub upgrade`, `flutter pub outdated`,
  `flutter pub add`, `flutter pub remove`, and `flutter pub deps`;
- `flutter daemon`;
- `flutter run --use-application-binary` for a Bazel-built debug APK, including
  device run, hot reload, and hot restart;
- `flutter attach --debug-url=<device-vm-service-url>` to an app already
  running on a device.
The Dart wrapper also supports `dart analyze`, `dart format`, `dart devtools`,
`dart pub get`, `dart pub upgrade`, `dart pub outdated`, `dart pub add`,
`dart pub remove`, `dart pub deps`, and `dart run build_runner build`.

For example, build a debug APK with Bazel, then launch it without rebuilding
through Flutter:

```sh
bazel build -c fastbuild --@rules_flutter_core//flutter:mode=debug //android/app:app
bazel run @rules_flutter_core//flutter -- run -d <id> --debug --use-application-binary=<apk>
```

Press `r` to hot reload, `R` to hot restart, and `q` to quit. To attach to an
already-running app, supply the VM-service URL announced by the device, for
example:

```sh
bazel run @rules_flutter_core//flutter -- attach -d <id> --debug-url=http://127.0.0.1:<device-port>/<isolate-id>/
```

Use the **device VM-service port** from the announced URL, not a host port
created by manually forwarding the service; Flutter performs its own forwarding.

The wrapper rejects `upgrade`, `downgrade`, `channel`, `precache`,
`update-packages`, and `build`. These commands update or replace the SDK or
conflict with Bazel's build graph. Select another version with
`flutter.sdk(version = "…")` in `MODULE.bazel`; use `bazel build` for app builds.

The wrappers do not create a workspace. Use host `flutter create` before
adopting Bazel rules in a new project. Host Flutter is otherwise needed only for
IDE setup; see [installation](install.md).
