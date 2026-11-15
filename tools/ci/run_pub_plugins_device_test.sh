#!/usr/bin/env bash
# Builds and runs the pub_plugins smoke integration test against whatever
# device is reachable through adb. One retry covers a known cold-emulator
# screenshot-readback flake; logcat is captured only on the final failure,
# before the caller tears the emulator down.
set -u
repo_root="$(cd "$(dirname "$0")/../.." && pwd)" || exit 1
cd "$repo_root/examples/pub_plugins" || exit 1

status=1
for attempt in 1 2; do
  if bazel test -c fastbuild --@rules_flutter_core//flutter:mode=debug \
      --lockfile_mode="${BAZEL_LOCKFILE_MODE:-error}" --test_output=all \
      //android/app:pub_plugins_smoke_integration_test; then
    status=0
    break
  fi
  echo "attempt $attempt failed" >&2
done

if [ "$status" -ne 0 ]; then
  adb logcat -d > "${GITHUB_WORKSPACE:-$repo_root}/pub_plugins_device_logcat.txt" || true
fi
exit "$status"
