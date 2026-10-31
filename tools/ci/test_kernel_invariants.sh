#!/usr/bin/env bash
# Checks test-kernel worker invariants for the example in the working directory.
# Run before any build of the example: cached outputs would hide the worker spawns.
# Extra arguments are Bazel options passed to every command, e.g. a mode flag.
set -euo pipefail

os=$(uname -s)
extra=("$@")
work=$(mktemp -d)
probe_dir=""
probe_backup=""
hint='hint: declare test-local imports in `srcs`'
frontend=--@rules_flutter_core//flutter:test_kernel_compiler=frontend_server
# Remote and disk hits would hide the runner and the compile being compared.
build_flags=(--disk_cache= --noremote_accept_cached --lockfile_mode=error)

restore_probe() {
  if [ -n "$probe_backup" ]; then
    cp "$probe_backup" "$probe_dir/BUILD.bazel"
    rm -f "$probe_dir/test/undeclared_import_probe_test.dart" "$probe_dir/test/undeclared_import_probe_helper.dart" "$probe_dir/test/undeclared_generated_import_probe_test.dart"
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
        if not any(i.get("path", "").endswith("/driver.dill") and i.get("isTool") for i in spawn.get("inputs", [])):
            sys.exit("FAIL: driver.dill must be a tool of every test kernel spawn")
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

# (c) An undeclared import, of a source or a generated file, must fail under the worker with the test import hint.
# The probe goes in the app's package, since tests must sit under its pubspec;
# its BUILD.bazel is restored on exit.
find_build() {
  find . -name BUILD.bazel -not -path './bazel-*' -print | LC_ALL=C sort | while read -r f; do
    if grep -q "$1" "$f"; then echo "$f"; fi
  done | sed -n 1p
}
app_build=$(find_build '^flutter_app(')
app_target=":app"
if [ -z "$app_build" ]; then
  # Without an app, the host test reads the test package flutter_core declares.
  app_build=$(find_build '^flutter_core(')
  if [ -z "$app_build" ]; then
    echo "FAIL: no flutter_app or flutter_core package for the undeclared-import probe" >&2
    exit 1
  fi
  core_name=$(awk '/^flutter_core\(/ { f = 1 } f && /name = "/ { match($0, /"[^"]*"/); print substr($0, RSTART + 1, RLENGTH - 2); exit }' "$app_build")
  app_target=":${core_name}_test_package"
fi
probe_dir=$(dirname "$app_build")
app_pkg=${probe_dir#.}
app_pkg=${app_pkg#/}
probe_load='load("@rules_flutter_core//flutter:defs.bzl", "flutter_test")'
if grep -q '"flutter_test"' "$app_build"; then
  probe_load=""
fi
probe_backup="$work/BUILD.bazel"
cp "$app_build" "$probe_backup"
mkdir -p "$probe_dir/test"
{
  if [ -n "$probe_load" ]; then
    echo "$probe_load"
  fi
  cat "$probe_backup"
  printf '\nflutter_test(\n    name = "undeclared_import_probe",\n    src = "test/undeclared_import_probe_test.dart",\n    app = "%s",\n    tags = ["manual"],\n)\n' "$app_target"
  printf '\ngenrule(\n    name = "undeclared_generated_import_probe_helper",\n    outs = ["test/undeclared_generated_import_probe_helper.dart"],\n    cmd = "touch $@",\n    tags = ["manual"],\n)\n'
  printf '\nflutter_test(\n    name = "undeclared_generated_import_probe",\n    src = "test/undeclared_generated_import_probe_test.dart",\n    app = "%s",\n    tags = ["manual"],\n)\n' "$app_target"
} > "$app_build"
printf "import 'undeclared_import_probe_helper.dart';\n\nvoid main() {}\n" > "$probe_dir/test/undeclared_import_probe_test.dart"
printf 'const undeclaredImportProbe = 1;\n' > "$probe_dir/test/undeclared_import_probe_helper.dart"
printf "import 'undeclared_generated_import_probe_helper.dart';\n\nvoid main() {}\n" > "$probe_dir/test/undeclared_generated_import_probe_test.dart"

# Builds one probe kernel, which must fail with the test import hint.
expect_undeclared_import_failure() {
  if bazel build "${build_flags[@]}" ${extra[@]+"${extra[@]}"} -- "//$app_pkg:$1" > "$work/probe.log" 2>&1; then
    echo "FAIL: undeclared import compiled under the worker: $1" >&2
    exit 1
  fi
  if ! grep -F -- "$hint" "$work/probe.log" > /dev/null; then
    cat "$work/probe.log" >&2
    echo "FAIL: undeclared import failed without the test import hint: $1" >&2
    exit 1
  fi
}
expect_undeclared_import_failure undeclared_import_probe_kernel
# The generated helper is built first, so its output is in bazel-bin when the test compiles.
bazel build "${build_flags[@]}" ${extra[@]+"${extra[@]}"} -- "//$app_pkg:undeclared_generated_import_probe_helper"
expect_undeclared_import_failure undeclared_generated_import_probe_kernel
restore_probe

echo "OK: test kernel worker invariants hold for $(wc -l < "$work/labels" | tr -d ' ') kernels"
