# Registrant parity goldens
Byte-for-byte `GeneratedPluginRegistrant.java` goldens from Flutter 3.50.1, to check the Starlark generator against flutter_tools.

- `expected/debug/`: dev-only plugins included. Captured with `flutter build apk --config-only --debug`, which is the regeneration `pub get` runs (it only does so when the app depends on the flutter SDK; these apps do not).
- `expected/release/`: dev-only plugins removed (`flutter build apk --config-only --release`).
- `app/pubspec.lock`: from `flutter pub get --offline`; path-only.

Generated Android app registrants use dependency-first ordering: alphabetically select among available plugins, and break cycles by smallest remaining in-degree then name. Flutter's graph is ordered before filtering and platform resolution, then the selected Android implementations are ordered again. Hand-written `flutter_plugin_registrant` calls retain alphabetical order unless they supply `order` (and optionally `release_order`).

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
