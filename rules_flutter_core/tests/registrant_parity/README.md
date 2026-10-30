# Registrant parity goldens
Byte-for-byte `GeneratedPluginRegistrant.java` goldens from Flutter 3.47.3, to check the Starlark generator against flutter_tools.

- `expected/debug/`: dev-only plugins included. Captured with `flutter build apk --config-only --debug`, which is the regeneration `pub get` runs (it only does so when the app depends on the flutter SDK; these apps do not).
- `expected/release/`: dev-only plugins removed (`flutter build apk --config-only --release`).
- `app/pubspec.lock`: from `flutter pub get --offline`; path-only.

Recapture (uses `$FLUTTER` or `flutter` on PATH):

    python3 tests/registrant_parity/capture.py                # rewrite goldens and locks
    python3 tests/registrant_parity/capture.py --check        # exit 1 with diff on mismatch
    python3 tests/registrant_parity/capture.py --case mixed   # one case

| case | pins |
|---|---|
| `no_plugins` | empty registrant body |
| `mixed` | Java, Kotlin, Dart-only, FFI-only, V1; dev-only (debug only); dev+transitive stays regular; transitive-only |
| `federated_default` | `default_package` beats a transitive alternative |
| `federated_direct` | direct dependency on the alternative beats `default_package` |
| `federated_dev_override` | dev-only alternative: debug 2 candidates, release 1; same output |
