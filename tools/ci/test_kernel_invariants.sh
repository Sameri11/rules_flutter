#!/usr/bin/env bash
# Checks test-kernel worker invariants for the example in the working directory.
# Run before any build of the example: cached outputs would hide the worker spawns.
# Extra arguments are Bazel options passed to every command, e.g. a mode flag.
set -euo pipefail

os=$(uname -s)
extra=("$@")
work=$(mktemp -d)
probe_backup=""
hint='hint: declare test-local imports in `srcs`'
frontend=--@rules_flutter//flutter:test_kernel_compiler=frontend_server
# Remote and disk hits would hide the runner and the compile being compared.
build_flags=(--disk_cache= --noremote_accept_cached --lockfile_mode=error)

restore_probe() {
  if [ -n "$probe_backup" ]; then
    cp "$probe_backup" BUILD.bazel
    rm -f test/undeclared_import_probe_test.dart test/undeclared_import_probe_helper.dart
    probe_backup=""
  fi
}

cleanup() {
  restore_probe
  rm -rf "$work"
}
trap cleanup EXIT

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# Reads "label path" lines and prints "sha256  label" lines.
digest_all() {
  while read -r label path; do
    printf '%s  %s\n' "$(sha256_of "$path")" "$label"
  done
}

# Prints "label path" for each kernel under the config flags given as arguments.
kernel_outputs() {
  bazel cquery 'kind(dart_test_kernel, //...)' --output=starlark \
    --starlark:expr='str(target.label) + " " + " ".join([f.path for f in target.files.to_list()])' \
    ${extra[@]+"${extra[@]}"} "$@" | LC_ALL=C sort
}

bazel query 'kind(dart_test_kernel, //...)' ${extra[@]+"${extra[@]}"} | LC_ALL=C sort > "$work/labels"
if [ ! -s "$work/labels" ]; then
  echo "no dart_test_kernel targets; nothing to check"
  : > "kernel-digests-$os.txt"
  exit 0
fi

# (a) and (b): default build on the worker, then frontend_server, byte-compared.
exec_log="$work/exec.json"
bazel build "${build_flags[@]}" ${extra[@]+"${extra[@]}"} \
  --execution_log_json_file="$exec_log" -- $(cat "$work/labels")
kernel_outputs | digest_all > "$work/worker.digests"
cp "$work/worker.digests" "kernel-digests-$os.txt"

python3 - "$exec_log" <<'PY'
import json, sys

text = open(sys.argv[1]).read()
decoder = json.JSONDecoder()
counts = {}
pos = 0
while True:
    while pos < len(text) and text[pos].isspace():
        pos += 1
    if pos >= len(text):
        break
    entry, pos = decoder.raw_decode(text, pos)
    spawn = entry.get("spawn", entry)
    if spawn.get("mnemonic") == "DartTestKernel":
        runner = spawn.get("runner", "")
        counts[runner] = counts.get(runner, 0) + 1
print("DartTestKernel runners:", counts)
if not counts or set(counts) != {"worker"}:
    sys.exit("FAIL: test kernel actions must run on the singleplex worker runner")
PY

bazel build "${build_flags[@]}" ${extra[@]+"${extra[@]}"} "$frontend" -- $(cat "$work/labels")
kernel_outputs "$frontend" | digest_all > "$work/frontend.digests"
if ! diff -u "$work/worker.digests" "$work/frontend.digests"; then
  echo "FAIL: worker output differs from test_kernel_compiler=frontend_server" >&2
  exit 1
fi

# (c) An undeclared import must fail under the worker with the test import hint.
# The probe target is appended to BUILD.bazel and restored on exit.
probe_backup="$work/BUILD.bazel"
cp BUILD.bazel "$probe_backup"
probe_load='load("@rules_flutter//flutter:defs.bzl", "flutter_test")'
if grep -q 'flutter_test' BUILD.bazel; then
  probe_load=""
fi
mkdir -p test
app_label=$(bazel query 'kind(flutter_app, //...)' ${extra[@]+"${extra[@]}"} | LC_ALL=C sort | head -1)
if [ -z "$app_label" ]; then
  echo "FAIL: no flutter_app target for the undeclared-import probe" >&2
  exit 1
fi
{
  if [ -n "$probe_load" ]; then
    echo "$probe_load"
  fi
  cat "$probe_backup"
  printf '\nflutter_test(\n    name = "undeclared_import_probe",\n    src = "test/undeclared_import_probe_test.dart",\n    app = "%s",\n    tags = ["manual"],\n)\n' "$app_label"
} > BUILD.bazel
printf "import 'undeclared_import_probe_helper.dart';\n\nvoid main() {}\n" > test/undeclared_import_probe_test.dart
printf 'const undeclaredImportProbe = 1;\n' > test/undeclared_import_probe_helper.dart
if bazel build "${build_flags[@]}" ${extra[@]+"${extra[@]}"} -- //:undeclared_import_probe_kernel > "$work/probe.log" 2>&1; then
  echo "FAIL: undeclared import compiled under the worker" >&2
  exit 1
fi
if ! grep -F -- "$hint" "$work/probe.log" > /dev/null; then
  cat "$work/probe.log" >&2
  echo "FAIL: undeclared import failed without the test import hint" >&2
  exit 1
fi
restore_probe

echo "OK: test kernel worker invariants hold for $(wc -l < "$work/labels" | tr -d ' ') kernels"
