#!/usr/bin/env bash
# Builds and runs the pub_plugins smoke integration test against whatever
# device is reachable through adb. One retry covers the known cold-emulator
# screenshot-readback flake (see IT-07 evidence); logcat is captured only on
# the final failure, before the caller tears the emulator down.
set -u
cd "$(dirname "$0")/../../examples/pub_plugins"

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
  adb logcat -d > "$GITHUB_WORKSPACE/pub_plugins_device_logcat.txt" || true
fi
exit "$status"
