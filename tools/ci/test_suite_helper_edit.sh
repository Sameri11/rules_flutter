#!/bin/bash
# Edits a helper read by one suite test, then a helper read by none, and counts
# the executed test kernels and runs. The read list must re-run only the importer.
set -euo pipefail
cd "$(dirname "$0")/../../rules_flutter_core"

pkg=//tests/flutter_test_conformance:scope_tests
inside=tests/flutter_test_conformance/test/scope/support/only_inside.dart
unread=tests/flutter_test_conformance/test/scope/support/unread.dart
tmp=$(mktemp -d)
cp "$inside" "$tmp/inside"
cp "$unread" "$tmp/unread"
trap 'cp "$tmp/inside" "$inside"; cp "$tmp/unread" "$unread"; rm -rf "$tmp"' EXIT

bazel test "$pkg" --lockfile_mode="${BAZEL_LOCKFILE_MODE:-error}" --remote_cache= --disk_cache= >/dev/null

# Count executed kernel and run spawns, and print their labels.
executed() {
  python3 - "$1" <<'PY'
import json, sys
text = open(sys.argv[1]).read()
dec = json.JSONDecoder()
pos, labels = 0, []
while True:
    while pos < len(text) and text[pos].isspace():
        pos += 1
    if pos >= len(text):
        break
    entry, pos = dec.raw_decode(text, pos)
    spawn = entry.get("spawn", entry)
    if spawn.get("mnemonic") in ("DartTestKernel", "TestRunner") and not spawn.get("cacheHit"):
        labels.append(spawn.get("targetLabel", ""))
print("\n".join(labels))
PY
}

echo "// edit $RANDOM$$" >> "$inside"
bazel test "$pkg" --lockfile_mode="${BAZEL_LOCKFILE_MODE:-error}" --remote_cache= --disk_cache= --execution_log_json_file="$tmp/inside.json" >/dev/null
got=$(executed "$tmp/inside.json")
echo "helper read by one test re-ran:"
echo "$got"
[ "$(echo "$got" | grep -c .)" -eq 2 ] || { echo "expected 2 executed spawns (kernel and run)"; exit 1; }
echo "$got" | grep -q 'inside_test' || { echo "expected spawns for inside_test"; exit 1; }

echo "// edit $RANDOM$$" >> "$unread"
bazel test "$pkg" --lockfile_mode="${BAZEL_LOCKFILE_MODE:-error}" --remote_cache= --disk_cache= --execution_log_json_file="$tmp/unread.json" >/dev/null
got=$(executed "$tmp/unread.json")
[ -z "$got" ] || { echo "unread helper edit re-ran spawns:"; echo "$got"; exit 1; }
echo "unread helper edit re-ran nothing"
