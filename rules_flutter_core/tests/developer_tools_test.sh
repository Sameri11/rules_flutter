#!/usr/bin/env bash
set -euo pipefail
flutter="$1"
dart="$2"
fixture="$3"
export HOME="$TEST_TMPDIR/home"
export PUB_CACHE="$TEST_TMPDIR/pub_cache"
mkdir -p "$HOME" "$PUB_CACHE"

sdk_marker="${RUNFILES_DIR:-$0.runfiles}/_main/flutter_dev_tools/sdk_version.json"
sdk_version="$(readlink "$sdk_marker")"
if [[ "$sdk_version" != /* ]]; then sdk_version="$(dirname "$sdk_marker")/$sdk_version"; fi
sdk_version="$(cd "$(dirname "$sdk_version")" && pwd -P)/$(basename "$sdk_version")"
sdk_root="$(dirname "$(dirname "$(dirname "$sdk_version")")")"
hash_sdk() {
  shasum -a 256 \
    "$sdk_root/bin/cache/flutter.version.json" \
    "$sdk_root/bin/internal/engine.version" \
    "$sdk_root/bin/cache/dart-sdk/bin/dart" | shasum -a 256
}
before="$(hash_sdk)"
"$dart" --version
"$flutter" --version --machine >/dev/null
work="$TEST_TMPDIR/pub_fixture"
mkdir -p "$work"
cp "$fixture" "$work/pubspec.yaml"
(cd "$work" && "$dart" pub get --offline)
for command in upgrade downgrade channel precache update-packages build; do
  output="$TEST_TMPDIR/$command.out"
  if "$flutter" "$command" >"$output" 2>&1; then
    echo "flutter $command unexpectedly succeeded" >&2
    exit 1
  fi
  grep -F "flutter.sdk(version =" "$output" >/dev/null
  grep -F "bazel build" "$output" >/dev/null
done
after="$(hash_sdk)"
if [[ "$before" != "$after" ]]; then
  echo "Flutter SDK content changed while running developer tools" >&2
  exit 1
fi
